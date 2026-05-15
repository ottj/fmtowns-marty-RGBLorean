// SPDX-License-Identifier: MIT
//
// ipl_smoke_tb.sv — preload card.hex into the PCMCIA target's BRAM and verify
// the Marty ROM would see a valid IPL4 boot signature.
//
// This is an "integration" smoke test: it crosses the FPGA-firmware /
// x86-firmware boundary by loading the artefact built by
//   firmware/x86/ipl/Makefile
// into the pcmcia_target's BRAM via $readmemh, then issues Marty-style
// bus reads to check the bytes the ROM is interested in.
//
// Run with:
//     cd firmware/x86/ipl && make            # builds card.hex
//     cd firmware/fpga/sim && make ipl       # runs this TB

`default_nettype none
`timescale 1ns/100ps

module ipl_smoke_tb;

    // Clock + reset
    reg clk = 0;
    always #5 clk = ~clk;             // 100 MHz
    reg rst_n = 0;

    // Bus signals
    reg  [25:0] fp_a     = 26'h0;
    reg         fp_ce1_n = 1'b1;
    reg         fp_ce2_n = 1'b1;
    reg         fp_oe_n  = 1'b1;
    reg         fp_we_n  = 1'b1;
    reg         fp_reset = 1'b0;
    wire [15:0] fp_d;                 // pure read TB: never drives fp_d

    wire dbg_sel, dbg_rd, dbg_wr;
    wire [3:0] dbg_mbx_state_w;
    wire sd_spi_clk_w, sd_spi_cs_n_w, sd_spi_mosi_w;

    // 4 KB BRAM (12 addr bits) so the mailbox layout (word 0x400 = byte 0x800)
    // doesn't alias onto the boot sector.
    // This TB only checks the boot-region preload; sd_reader stays idle.
    pcmcia_target #(
        .ADDR_BITS (12),
        .INIT_FILE ("../../x86/ipl/card.hex")
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .fp_a         (fp_a),
        .fp_d         (fp_d),
        .fp_ce1_n     (fp_ce1_n),
        .fp_ce2_n     (fp_ce2_n),
        .fp_oe_n      (fp_oe_n),
        .fp_we_n      (fp_we_n),
        .fp_reset     (fp_reset),
        .sd_spi_clk   (sd_spi_clk_w),
        .sd_spi_cs_n  (sd_spi_cs_n_w),
        .sd_spi_mosi  (sd_spi_mosi_w),
        .sd_spi_miso  (1'b1),
        .dbg_bus_sel  (dbg_sel),
        .dbg_bus_rd   (dbg_rd),
        .dbg_bus_wr   (dbg_wr),
        .dbg_mbx_state(dbg_mbx_state_w)
    );

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

    task bus_read16(input [25:0] addr, output [15:0] data);
        begin
            fp_a     = addr;
            fp_ce1_n = 1'b0;
            fp_ce2_n = 1'b0;
            #20;
            fp_oe_n  = 1'b0;
            #80;
            data     = fp_d;
            fp_oe_n  = 1'b1;
            #10;
            fp_ce1_n = 1'b1;
            fp_ce2_n = 1'b1;
            #20;
        end
    endtask

    reg [15:0] w;
    initial begin
        $dumpfile("ipl_smoke_tb.vcd");
        $dumpvars(0, ipl_smoke_tb);

        $display("=== ipl_smoke_tb start ===");
        #20;
        rst_n = 1'b1;
        #20;

        // -----------------------------------------------------------
        // IPL4 magic at offset 0
        // Boot sector bytes 0..3 = 'I' 'P' 'L' '4' = 0x49 0x50 0x4C 0x34
        // 16-bit little-endian: word0 = 0x5049 ('I'+'P'<<8)
        //                       word1 = 0x344C ('L'+'4'<<8)
        // -----------------------------------------------------------
        bus_read16(26'h000000, w);
        expect_eq(w, 16'h5049, "IPL4 magic word 0 ('IP')");

        bus_read16(26'h000002, w);
        expect_eq(w, 16'h344C, "IPL4 magic word 1 ('L4')");

        // -----------------------------------------------------------
        // IO.SYS LBA32 at offset 0x20 — expect = 1
        // -----------------------------------------------------------
        bus_read16(26'h000020, w);
        expect_eq(w, 16'h0001, "IO.SYS LBA low half");
        bus_read16(26'h000022, w);
        expect_eq(w, 16'h0000, "IO.SYS LBA high half");

        // -----------------------------------------------------------
        // IO.SYS sector count at offset 0x24 — expect = 1
        // -----------------------------------------------------------
        bus_read16(26'h000024, w);
        expect_eq(w, 16'h0001, "IO.SYS sector count low half");
        bus_read16(26'h000026, w);
        expect_eq(w, 16'h0000, "IO.SYS sector count high half");

        // -----------------------------------------------------------
        // Stub at sector 1 (byte offset 0x400) — Marty uses 1024-byte
        // sectors and jumps directly to the start of the loaded
        // sector (= RAM 0x400), so our stub entry sits at file
        // offset 0x400 with no leading filler.
        //
        // First instructions:
        //   FA       CLI
        //   31 C0    XOR AX,AX
        // Word at offset 0x400 (little-endian) = 0x31FA.
        //
        // Byte 0x3FE (last word of boot sector) should be 0x0000
        // padding; the boot sector itself runs to 0x400.
        // -----------------------------------------------------------
        bus_read16(26'h000400, w);
        expect_eq(w, 16'h31FA, "stub entry @ byte 0x400 (CLI; XOR AX,AX)");

        if (errors == 0) $display("=== ALL IPL SMOKE TESTS PASSED ===");
        else             $display("=== %0d FAILURE(S) ===", errors);
        $finish;
    end

    initial begin
        #50000;
        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule

`default_nettype wire
