// SPDX-License-Identifier: MIT
//
// pcmcia_target_tb.sv — self-checking testbench for pcmcia_target.sv
//
// Models a Marty-style bus master and exercises the slave with a series of
// read/write cycles. Reports PASS/FAIL on completion and dumps a VCD for
// post-mortem in GTKWave.
//
// Run with:
//     make           # builds and runs
//     make wave      # opens the resulting VCD in GTKWave (if installed)

`default_nettype none
`timescale 1ns/100ps

module pcmcia_target_tb;

    // ------------------------------------------------------------------
    // Clock & reset
    // ------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;          // 100 MHz system clock

    reg rst_n = 0;

    // ------------------------------------------------------------------
    // Marty-side bus signals (testbench drives these)
    // ------------------------------------------------------------------
    reg  [25:0] fp_a     = 26'h0;
    reg  [15:0] fp_d_drv = 16'h0;
    reg         fp_d_oe  = 1'b0;
    reg         fp_ce1_n = 1'b1;
    reg         fp_ce2_n = 1'b1;
    reg         fp_oe_n  = 1'b1;
    reg         fp_we_n  = 1'b1;
    reg         fp_reset = 1'b0;

    wire [15:0] fp_d = fp_d_oe ? fp_d_drv : 16'bz;

    wire dbg_sel, dbg_rd, dbg_wr;
    wire [3:0] dbg_mbx_state_w;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    // SPI tie-offs — this TB never triggers READ_SECTOR, so the SD
    // controller stays idle and MISO can rest at the bus-pulled-high
    // level (= 1).
    wire sd_spi_clk_w, sd_spi_cs_n_w, sd_spi_mosi_w;

    pcmcia_target #(.ADDR_BITS(12)) dut (   // 4 KB BRAM — large enough for mailbox layout
        .clk         (clk),
        .rst_n       (rst_n),
        .fp_a        (fp_a),
        .fp_d        (fp_d),
        .fp_ce1_n    (fp_ce1_n),
        .fp_ce2_n    (fp_ce2_n),
        .fp_oe_n     (fp_oe_n),
        .fp_we_n     (fp_we_n),
        .fp_reset    (fp_reset),
        .sd_spi_clk  (sd_spi_clk_w),
        .sd_spi_cs_n (sd_spi_cs_n_w),
        .sd_spi_mosi (sd_spi_mosi_w),
        .sd_spi_miso (1'b1),
        .dbg_bus_sel  (dbg_sel),
        .dbg_bus_rd   (dbg_rd),
        .dbg_bus_wr   (dbg_wr),
        .dbg_mbx_state(dbg_mbx_state_w)
    );

    // ------------------------------------------------------------------
    // Test scoreboard
    // ------------------------------------------------------------------
    integer errors = 0;
    task expect_eq(input [15:0] got, input [15:0] want, input [255:0] msg);
        begin
            if (got !== want) begin
                $display("[%0t] FAIL: %s — got %h, expected %h", $time, msg, got, want);
                errors = errors + 1;
            end else begin
                $display("[%0t] PASS: %s — %h", $time, msg, got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Marty bus tasks (timings ~ 16 MHz 386SX: ~125 ns cycles)
    // ------------------------------------------------------------------
    task bus_write16(input [25:0] addr, input [15:0] data);
        begin
            // 1) Address setup
            fp_a     = addr;
            fp_d_drv = data;
            fp_d_oe  = 1'b1;
            fp_ce1_n = 1'b0;        // word write: assert both byte enables
            fp_ce2_n = 1'b0;
            fp_oe_n  = 1'b1;
            #20;                     // address setup ~20 ns
            // 2) WE pulse low
            fp_we_n  = 1'b0;
            #80;                     // hold low ~80 ns
            // 3) Deassert WE then CE
            fp_we_n  = 1'b1;
            #10;
            fp_ce1_n = 1'b1;
            fp_ce2_n = 1'b1;
            fp_d_oe  = 1'b0;
            #20;
        end
    endtask

    task bus_read16(input [25:0] addr, output [15:0] data);
        begin
            fp_a     = addr;
            fp_ce1_n = 1'b0;
            fp_ce2_n = 1'b0;
            fp_we_n  = 1'b1;
            fp_d_oe  = 1'b0;
            #20;
            fp_oe_n  = 1'b0;
            #80;                     // hold OE low while we sample
            data     = fp_d;
            fp_oe_n  = 1'b1;
            #10;
            fp_ce1_n = 1'b1;
            fp_ce2_n = 1'b1;
            #20;
        end
    endtask

    task bus_write_byte_lo(input [25:0] addr, input [7:0] data);
        begin
            fp_a     = addr;
            fp_d_drv = {8'h00, data};
            fp_d_oe  = 1'b1;
            fp_ce1_n = 1'b0;        // low byte only
            fp_ce2_n = 1'b1;
            #20;
            fp_we_n  = 1'b0;
            #80;
            fp_we_n  = 1'b1;
            #10;
            fp_ce1_n = 1'b1;
            fp_d_oe  = 1'b0;
            #20;
        end
    endtask

    task bus_write_byte_hi(input [25:0] addr, input [7:0] data);
        begin
            fp_a     = addr;
            fp_d_drv = {data, 8'h00};
            fp_d_oe  = 1'b1;
            fp_ce1_n = 1'b1;
            fp_ce2_n = 1'b0;        // high byte only
            #20;
            fp_we_n  = 1'b0;
            #80;
            fp_we_n  = 1'b1;
            #10;
            fp_ce2_n = 1'b1;
            fp_d_oe  = 1'b0;
            #20;
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    reg [15:0] rd;
    initial begin
        $dumpfile("pcmcia_target_tb.vcd");
        $dumpvars(0, pcmcia_target_tb);

        $display("=== pcmcia_target_tb start ===");

        // Reset for a few clocks
        #20;
        rst_n = 1'b1;
        #20;

        // T1 — Word write then read-back
        bus_write16(26'h000000, 16'hCAFE);
        bus_read16 (26'h000000, rd);
        expect_eq(rd, 16'hCAFE, "T1 word @ 0x000000");

        bus_write16(26'h000010, 16'hBEEF);
        bus_read16 (26'h000010, rd);
        expect_eq(rd, 16'hBEEF, "T1 word @ 0x000010");

        bus_write16(26'h001FFE, 16'h1234);
        bus_read16 (26'h001FFE, rd);
        expect_eq(rd, 16'h1234, "T1 word @ 0x001FFE (end of 4 KB BRAM)");

        // T2 — Address wrap-around (BRAM is 4096 words; bit 13 should wrap)
        bus_write16(26'h002000, 16'hDEAD);   // wraps to word 0
        bus_read16 (26'h000000, rd);
        expect_eq(rd, 16'hDEAD, "T2 wrap: 0x2000 -> word 0");

        // T3 — Byte writes
        bus_write16     (26'h000020, 16'hAA55);
        bus_write_byte_lo(26'h000020, 8'h99);   // low byte only
        bus_read16      (26'h000020, rd);
        expect_eq(rd, 16'hAA99, "T3 low-byte write preserves high byte");

        bus_write_byte_hi(26'h000020, 8'h77);   // high byte only
        bus_read16      (26'h000020, rd);
        expect_eq(rd, 16'h7799, "T3 high-byte write preserves low byte");

        // T4 — Card reset clears read latch but keeps memory contents
        fp_reset = 1'b1;
        #30;
        fp_reset = 1'b0;
        #20;
        bus_read16(26'h000010, rd);
        expect_eq(rd, 16'hBEEF, "T4 memory survives card RESET");

        // T5 — Verify D bus tri-states when not selected
        #10;
        if (fp_d !== 16'bz) begin
            $display("[%0t] FAIL: fp_d not high-Z when idle (got %h)", $time, fp_d);
            errors = errors + 1;
        end else begin
            $display("[%0t] PASS: fp_d high-Z when idle", $time);
        end

        // ------------------------------------------------------------------
        if (errors == 0) begin
            $display("=== ALL TESTS PASSED ===");
        end else begin
            $display("=== %0d FAILURE(S) ===", errors);
        end
        $finish;
    end

    // Safety timeout
    initial begin
        #100000;
        $display("=== TIMEOUT after 100 us ===");
        $finish;
    end

endmodule

`default_nettype wire
