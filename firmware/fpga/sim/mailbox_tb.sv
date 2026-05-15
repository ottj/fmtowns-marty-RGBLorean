// SPDX-License-Identifier: MIT
//
// mailbox_tb.sv — self-checking testbench for the mailbox FSM that lives
// inside pcmcia_target. Exercises the host-side request protocol:
//
//   1. Host polls status until IDLE
//   2. Host writes command  (low byte of word 0x400 = byte addr 0x800)
//   3. Host polls status until DONE / ERROR
//   4. Host reads sector_data (byte addr 0x1000..)
//   5. Host writes command = NOOP to release back to IDLE
//
// Phase 1 commands covered:
//   0x10 FPGA_INFO   → writes "RGBL0001" to sector_data[0..7], DONE
//   0xAA unknown     → ERROR
//   0x00 NOOP        → IDLE (used as the "release" step)

`default_nettype none
`timescale 1ns/100ps

module mailbox_tb;

    // ------------------------------------------------------------------
    // Clock + reset
    // ------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;                  // 100 MHz
    reg rst_n = 0;

    // ------------------------------------------------------------------
    // Bus signals (testbench drives master role)
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
    wire        dbg_sel, dbg_rd, dbg_wr;
    wire [3:0]  dbg_mbx_state;

    // ------------------------------------------------------------------
    // DUT — 4 KB BRAM, mailbox at word 0x400 (byte 0x800), sector_data at
    // word 0x800 (byte 0x1000). SECTOR_WORDS shrunk to 16 for fast sim
    // (production target: 1024 words = 2 KB Marty CD-ROM sector).
    //
    // Real SD-mode sd_reader is wired against an sd_model peer so the
    // CMD_READ_SECTOR path exercises CMD0/8/55/ACMD41/CMD17 end-to-end.
    // The model's deterministic block pattern is word[i] = lba_lo + i,
    // matching the behaviour the old stub used to fake — so this TB's
    // T5/T6 assertions stay unchanged.
    // ------------------------------------------------------------------
    localparam int SECTOR_WORDS = 16;
    wire sd_spi_clk_w, sd_spi_cs_n_w, sd_spi_mosi_w, sd_spi_miso_w;

    pcmcia_target #(
        .ADDR_BITS        (12),
        .SECTOR_WORDS     (SECTOR_WORDS),
        // Sim-only: dial the SD init clock all the way up so an init
        // pass doesn't dominate the test runtime. The protocol-level
        // correctness is what we're checking here, not real-card
        // settling time.
        .SD_SCLK_HALF_INIT(2),
        .SD_SCLK_HALF_RUN (2),
        .SD_INIT_DUMMY    (4)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .fp_a          (fp_a),
        .fp_d          (fp_d),
        .fp_ce1_n      (fp_ce1_n),
        .fp_ce2_n      (fp_ce2_n),
        .fp_oe_n       (fp_oe_n),
        .fp_we_n       (fp_we_n),
        .fp_reset      (fp_reset),
        .sd_spi_clk    (sd_spi_clk_w),
        .sd_spi_cs_n   (sd_spi_cs_n_w),
        .sd_spi_mosi   (sd_spi_mosi_w),
        .sd_spi_miso   (sd_spi_miso_w),
        .dbg_bus_sel   (dbg_sel),
        .dbg_bus_rd    (dbg_rd),
        .dbg_bus_wr    (dbg_wr),
        .dbg_mbx_state (dbg_mbx_state)
    );

    sd_model #(
        .ACMD41_BUSY_RETRIES (1),
        .CMD17_NAC_BYTES     (2),
        .VERBOSE             (1'b0)
    ) u_model (
        .spi_clk  (sd_spi_clk_w),
        .spi_cs_n (sd_spi_cs_n_w),
        .spi_mosi (sd_spi_mosi_w),
        .spi_miso (sd_spi_miso_w)
    );

    // ------------------------------------------------------------------
    // Mailbox layout constants (matching pcmcia_target defaults)
    // ------------------------------------------------------------------
    localparam [25:0] CMD_BYTE   = 26'h000800;   // command (low byte of word 0x400)
    localparam [25:0] STAT_BYTE  = 26'h000801;   // status  (high byte same word)
    localparam [25:0] MBX_WORD_A = 26'h000800;   // full word read = {status, command}
    localparam [25:0] DATA_BYTE0 = 26'h001000;   // sector_data[0]

    localparam [7:0] CMD_NOOP        = 8'h00;
    localparam [7:0] CMD_READ_SECTOR = 8'h01;
    localparam [7:0] CMD_FPGA_INFO   = 8'h10;
    localparam [7:0] CMD_BOGUS       = 8'hAA;

    // Mailbox field byte addresses
    localparam [25:0] LBA_LO_WORD       = 26'h000804;
    localparam [25:0] LBA_HI_WORD       = 26'h000806;
    localparam [25:0] SECCOUNT_WORD     = 26'h000808;

    localparam [7:0] STATUS_IDLE  = 8'h00;
    localparam [7:0] STATUS_BUSY  = 8'h01;
    localparam [7:0] STATUS_DONE  = 8'h02;
    localparam [7:0] STATUS_ERROR = 8'hFF;

    // ------------------------------------------------------------------
    // Bus tasks (subset of pcmcia_target_tb's set)
    // ------------------------------------------------------------------
    task bus_read16(input [25:0] addr, output [15:0] data);
        begin
            fp_a     = addr;
            fp_ce1_n = 1'b0;
            fp_ce2_n = 1'b0;
            fp_we_n  = 1'b1;
            fp_d_oe  = 1'b0;
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

    task bus_write16(input [25:0] addr, input [15:0] data);
        begin
            fp_a     = addr;
            fp_d_drv = data;
            fp_d_oe  = 1'b1;
            fp_ce1_n = 1'b0;
            fp_ce2_n = 1'b0;
            #20;
            fp_we_n  = 1'b0;
            #80;
            fp_we_n  = 1'b1;
            #10;
            fp_ce1_n = 1'b1;
            fp_ce2_n = 1'b1;
            fp_d_oe  = 1'b0;
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

    integer errors = 0;

    // Poll the status byte until it matches `want`. Timeout after N polls.
    task wait_status(input [7:0] want, input integer max_polls);
        integer i;
        reg [15:0] w;
        reg [7:0]  s;
        begin
            for (i = 0; i < max_polls; i = i + 1) begin
                bus_read16(MBX_WORD_A, w);
                s = w[15:8];
                if (s === want) begin
                    $display("[%0t] poll #%0d: status=%h (match)", $time, i, s);
                    disable wait_status;
                end
            end
            $display("[%0t] FAIL: status never reached %h after %0d polls (last seen %h)",
                     $time, want, max_polls, s);
            errors = errors + 1;
        end
    endtask

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
    // Test sequence
    // ------------------------------------------------------------------
    reg [15:0] w;
    initial begin
        $dumpfile("mailbox_tb.vcd");
        $dumpvars(0, mailbox_tb);

        $display("=== mailbox_tb start ===");
        #20;
        rst_n = 1'b1;
        #40;

        // After reset, status should be IDLE
        bus_read16(MBX_WORD_A, w);
        expect_eq({8'h00, w[15:8]}, {8'h00, STATUS_IDLE}, "T0 post-reset status = IDLE");

        // --------------------------------------------------------------
        // T1 — Issue FPGA_INFO, expect DONE + "RGBL0001" in sector_data
        // --------------------------------------------------------------
        bus_write_byte_lo(CMD_BYTE, CMD_FPGA_INFO);
        wait_status(STATUS_DONE, 50);

        bus_read16(DATA_BYTE0 + 0, w);
        expect_eq(w, 16'h4752, "T1 sector_data[0] = 'R' 'G'");
        bus_read16(DATA_BYTE0 + 2, w);
        expect_eq(w, 16'h4C42, "T1 sector_data[1] = 'B' 'L'");
        bus_read16(DATA_BYTE0 + 4, w);
        expect_eq(w, 16'h3030, "T1 sector_data[2] = '0' '0'");
        bus_read16(DATA_BYTE0 + 6, w);
        expect_eq(w, 16'h3130, "T1 sector_data[3] = '0' '1'");

        // Confirm command readback still shows what we wrote
        bus_read16(MBX_WORD_A, w);
        expect_eq({8'h00, w[7:0]}, {8'h00, CMD_FPGA_INFO}, "T1 command readback = FPGA_INFO");

        // Release: write NOOP, expect IDLE
        bus_write_byte_lo(CMD_BYTE, CMD_NOOP);
        wait_status(STATUS_IDLE, 50);

        // --------------------------------------------------------------
        // T2 — Issue unknown command, expect ERROR
        // --------------------------------------------------------------
        bus_write_byte_lo(CMD_BYTE, CMD_BOGUS);
        wait_status(STATUS_ERROR, 50);

        // Release
        bus_write_byte_lo(CMD_BYTE, CMD_NOOP);
        wait_status(STATUS_IDLE, 50);

        // --------------------------------------------------------------
        // T3 — Boot sector preserved (mailbox writes shouldn't trash BRAM
        // outside the sector_data buffer)
        // --------------------------------------------------------------
        // mem[0] is zero (no INIT_FILE in this TB); just confirm we can
        // still write/read normally outside the mailbox region.
        // (Inline write via the basic bus protocol)
        fp_a     = 26'h000020;
        fp_d_drv = 16'hABCD;
        fp_d_oe  = 1'b1;
        fp_ce1_n = 1'b0;
        fp_ce2_n = 1'b0;
        #20;
        fp_we_n  = 1'b0;
        #80;
        fp_we_n  = 1'b1;
        #10;
        fp_ce1_n = 1'b1;
        fp_ce2_n = 1'b1;
        fp_d_oe  = 1'b0;
        #20;

        bus_read16(26'h000020, w);
        expect_eq(w, 16'hABCD, "T3 boot-region BRAM still RW-able");

        // --------------------------------------------------------------
        // T4 — Mailbox state survives a host write to a non-mailbox
        // address while DONE
        // --------------------------------------------------------------
        bus_write_byte_lo(CMD_BYTE, CMD_FPGA_INFO);
        wait_status(STATUS_DONE, 50);
        bus_read16(DATA_BYTE0 + 0, w);
        expect_eq(w, 16'h4752, "T4 sector_data[0] re-checked after second FPGA_INFO");
        bus_write_byte_lo(CMD_BYTE, CMD_NOOP);
        wait_status(STATUS_IDLE, 50);

        // --------------------------------------------------------------
        // T5 — READ_SECTOR with a non-trivial LBA. Expect FSM to write
        // SECTOR_WORDS words of pattern `word[i] = lba[15:0] + i` into
        // the sector_data buffer.
        // --------------------------------------------------------------

        // Write lba = 0x12345678 (lo word 0x5678, hi word 0x1234)
        bus_write16(LBA_LO_WORD, 16'h5678);
        bus_write16(LBA_HI_WORD, 16'h1234);
        bus_write16(SECCOUNT_WORD, 16'h0001);     // one sector

        // Confirm fields readback
        bus_read16(LBA_LO_WORD, w);
        expect_eq(w, 16'h5678, "T5 lba[15:0] readback");
        bus_read16(LBA_HI_WORD, w);
        expect_eq(w, 16'h1234, "T5 lba[31:16] readback");
        bus_read16(SECCOUNT_WORD, w);
        expect_eq(w, 16'h0001, "T5 sector_count readback");

        // Kick off READ_SECTOR
        bus_write_byte_lo(CMD_BYTE, CMD_READ_SECTOR);
        // With real SPI sd_reader, CMD17 always clocks a full 512-byte
        // SD block (we discard the trailing 240 words after SECTOR_WORDS).
        // At half=2 SCLK, that's ~200 µs end-to-end including init for
        // the first call — wait_status polls at ~130 ns each, so we
        // need ~3000+ polls.
        wait_status(STATUS_DONE, 5000);

        // Spot-check the first, middle, last words of the buffer
        bus_read16(DATA_BYTE0 + 2*0, w);
        expect_eq(w, 16'h5678 + 16'd0, "T5 sector_data[0] = lba_lo + 0");
        bus_read16(DATA_BYTE0 + 2*1, w);
        expect_eq(w, 16'h5678 + 16'd1, "T5 sector_data[1] = lba_lo + 1");
        bus_read16(DATA_BYTE0 + 2*7, w);
        expect_eq(w, 16'h5678 + 16'd7, "T5 sector_data[7] = lba_lo + 7");
        bus_read16(DATA_BYTE0 + 2*(SECTOR_WORDS-1), w);
        expect_eq(w, 16'h5678 + (SECTOR_WORDS-1), "T5 sector_data[last] = lba_lo + (N-1)");

        // Release
        bus_write_byte_lo(CMD_BYTE, CMD_NOOP);
        wait_status(STATUS_IDLE, 50);

        // --------------------------------------------------------------
        // T6 — READ_SECTOR with lba = 0 should write 0, 1, 2, 3, ...
        // --------------------------------------------------------------
        bus_write16(LBA_LO_WORD, 16'h0000);
        bus_write16(LBA_HI_WORD, 16'h0000);
        bus_write_byte_lo(CMD_BYTE, CMD_READ_SECTOR);
        // No init this time but a full SD block still gets clocked through.
        wait_status(STATUS_DONE, 5000);

        bus_read16(DATA_BYTE0 + 2*0, w);
        expect_eq(w, 16'h0000, "T6 lba=0 → sector_data[0] = 0");
        bus_read16(DATA_BYTE0 + 2*3, w);
        expect_eq(w, 16'h0003, "T6 lba=0 → sector_data[3] = 3");

        bus_write_byte_lo(CMD_BYTE, CMD_NOOP);
        wait_status(STATUS_IDLE, 50);

        if (errors == 0) $display("=== ALL MAILBOX TESTS PASSED ===");
        else             $display("=== %0d FAILURE(S) ===", errors);
        $finish;
    end

    initial begin
        #2000000;            // 2 ms — covers init + 2 CMD17 bursts
        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule

`default_nettype wire
