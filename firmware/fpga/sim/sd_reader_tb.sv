// SPDX-License-Identifier: MIT
//
// sd_reader_tb.sv — pair sd_reader.sv with sd_model.sv over the SPI
// wires and verify the end-to-end read path.
//
// Exercises:
//   T1 — On reset, sd_reader does not toggle SCLK until first `req`.
//   T2 — First req triggers init: dummy clocks, CMD0/8/55/ACMD41 loop,
//        then CMD17. sd_model returns deterministic block data.
//   T3 — Collected wr_data words match sd_model's pattern.
//   T4 — Subsequent `req` skips init (initialized stays high) and just
//        issues another CMD17 burst.
//
// Sim params shrink SECTOR_WORDS down to 256 (= 1 SD block) with
// BLOCKS_PER_REQ=1 to keep the test under a few hundred microseconds.

`default_nettype none
`timescale 1ns/100ps

module sd_reader_tb;

    // ------------------------------------------------------------------
    // Clock + reset
    // ------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;            // 100 MHz sys clock
    reg rst_n = 0;

    // ------------------------------------------------------------------
    // Wires between sd_reader and sd_model
    // ------------------------------------------------------------------
    reg         req     = 1'b0;
    reg  [31:0] lba     = 32'd0;
    wire [15:0] wr_idx;
    wire [15:0] wr_data;
    wire        wr_en;
    wire        busy;
    wire        done;

    wire spi_clk_w;
    wire spi_cs_n_w;
    wire spi_mosi_w;
    wire spi_miso_w;

    // ------------------------------------------------------------------
    // DUT — host. Shrink BLOCKS_PER_REQ=1 and SECTOR_WORDS=256 so one
    // CMD17 covers the whole request. Use fast SCLK (half=2 sys
    // clocks = 25 MHz at 100 MHz sysclk) for both init and run; the
    // init dummy-clock count stays at 80 per spec.
    // ------------------------------------------------------------------
    localparam int TB_SECTOR_WORDS = 256;
    localparam int TB_BLOCKS       = 1;
    sd_reader #(
        .SECTOR_WORDS    (TB_SECTOR_WORDS),
        .BLOCKS_PER_REQ  (TB_BLOCKS),
        .SCLK_HALF_INIT  (2),
        .SCLK_HALF_RUN   (2),
        .INIT_DUMMY_CLKS (80),
        .ACMD41_MAX_TRIES(8)
    ) u_reader (
        .clk      (clk),
        .rst_n    (rst_n),
        .req      (req),
        .lba      (lba),
        .wr_idx   (wr_idx),
        .wr_data  (wr_data),
        .wr_en    (wr_en),
        .busy     (busy),
        .done     (done),
        .spi_clk  (spi_clk_w),
        .spi_cs_n (spi_cs_n_w),
        .spi_mosi (spi_mosi_w),
        .spi_miso (spi_miso_w)
    );

    // ------------------------------------------------------------------
    // DUT — model
    // ------------------------------------------------------------------
    sd_model #(
        .ACMD41_BUSY_RETRIES (1),
        .CMD17_NAC_BYTES     (2),
        .VERBOSE             (1'b1)
    ) u_model (
        .spi_clk  (spi_clk_w),
        .spi_cs_n (spi_cs_n_w),
        .spi_mosi (spi_mosi_w),
        .spi_miso (spi_miso_w)
    );

    // ------------------------------------------------------------------
    // Captured wr_data — testbench mirror of what the BRAM would hold.
    // ------------------------------------------------------------------
    reg [15:0] capture [0:TB_SECTOR_WORDS-1];
    integer    capture_count;

    always @(posedge clk) begin
        if (!rst_n) capture_count <= 0;
        else if (wr_en) begin
            capture[wr_idx] <= wr_data;
            capture_count   <= capture_count + 1;
        end
    end

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    integer errors = 0;

    task expect_eq16(input [15:0] got, input [15:0] want, input [255:0] msg);
        begin
            if (got !== want) begin
                $display("[%0t] FAIL: %s — got %04h, expected %04h",
                         $time, msg, got, want);
                errors = errors + 1;
            end else begin
                $display("[%0t] PASS: %s — %04h", $time, msg, got);
            end
        end
    endtask

    task expect_eq_int(input integer got, input integer want, input [255:0] msg);
        begin
            if (got !== want) begin
                $display("[%0t] FAIL: %s — got %0d, expected %0d",
                         $time, msg, got, want);
                errors = errors + 1;
            end else begin
                $display("[%0t] PASS: %s — %0d", $time, msg, got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Wait helpers
    // ------------------------------------------------------------------
    task wait_done(input integer max_cycles);
        integer i;
        begin
            for (i = 0; i < max_cycles; i = i + 1) begin
                @(posedge clk);
                if (done) disable wait_done;
            end
            $display("[%0t] FAIL: wait_done timeout after %0d cycles",
                     $time, max_cycles);
            errors = errors + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    integer i;
    reg [15:0] expected;
    initial begin
        $dumpfile("sd_reader_tb.vcd");
        $dumpvars(0, sd_reader_tb);

        $display("=== sd_reader_tb start ===");
        #20;
        rst_n = 1'b1;
        #100;

        // --------------------------------------------------------------
        // T1 — no SCLK toggling pre-req (lazy init).
        // --------------------------------------------------------------
        if (spi_clk_w !== 1'b0) begin
            $display("[%0t] FAIL: SCLK toggling before first req (=%b)",
                     $time, spi_clk_w);
            errors = errors + 1;
        end else begin
            $display("[%0t] PASS: SCLK idle (= 0) before first req", $time);
        end
        if (spi_cs_n_w !== 1'b1) begin
            $display("[%0t] FAIL: CS not high pre-req (=%b)", $time, spi_cs_n_w);
            errors = errors + 1;
        end else begin
            $display("[%0t] PASS: CS high before first req", $time);
        end

        // --------------------------------------------------------------
        // T2 — first req: init + CMD17 with lba = 0x1234.
        // --------------------------------------------------------------
        lba = 32'h00001234;
        @(posedge clk); req = 1'b1;
        @(posedge clk); req = 1'b0;
        // Init takes: 80 dummy SCLKs + 6*8 = 48 SCLKs per cmd * 4 cmds
        // (CMD0, CMD8 with R7 drain, CMD55, ACMD41) plus R1 polling
        // plus CMD17 = 256 data bytes + R1 + NAC + token + 2 CRC.
        // With half=2 (period=4 sys clocks per SCLK cycle), the data
        // phase alone is ~ (256 data + 4 protocol) * 8 bits * 4 cycles
        // ≈ 8300 sys clocks. Allow plenty of margin.
        wait_done(50000);
        expect_eq_int(capture_count, TB_SECTOR_WORDS,
                      "T2 wr_en count = SECTOR_WORDS");

        // --------------------------------------------------------------
        // T3 — captured pattern matches sd_model's deterministic data.
        //
        // Model pattern: byte[2i+0] = (lba_lo + i)[7:0], byte[2i+1] =
        // (lba_lo + i)[15:8]. With sd_reader's little-endian pairing
        // (low byte first), wr_data[i] = (lba_lo + i).
        // --------------------------------------------------------------
        for (i = 0; i < TB_SECTOR_WORDS; i = i + 1) begin
            expected = 16'h1234 + i[15:0];
            if (capture[i] !== expected) begin
                $display("[%0t] FAIL: T3 word[%0d] got %04h, expected %04h",
                         $time, i, capture[i], expected);
                errors = errors + 1;
                if (errors > 5) begin
                    $display("[%0t] ... suppressing further mismatches",
                             $time);
                    i = TB_SECTOR_WORDS;
                end
            end
        end
        if (errors == 0) $display("[%0t] PASS: T3 all %0d words match",
                                  $time, TB_SECTOR_WORDS);

        // --------------------------------------------------------------
        // T4 — second req with different LBA should skip init.
        // --------------------------------------------------------------
        lba = 32'h0000ABCD;
        capture_count = 0;
        @(posedge clk); req = 1'b1;
        @(posedge clk); req = 1'b0;
        wait_done(20000);                  // shorter — no init this time
        expect_eq_int(capture_count, TB_SECTOR_WORDS,
                      "T4 second req wr_en count = SECTOR_WORDS");
        for (i = 0; i < 8; i = i + 1) begin
            expected = 16'hABCD + i[15:0];
            if (capture[i] !== expected) begin
                $display("[%0t] FAIL: T4 word[%0d] got %04h, expected %04h",
                         $time, i, capture[i], expected);
                errors = errors + 1;
            end
        end
        if (capture[TB_SECTOR_WORDS-1] === (16'hABCD + (TB_SECTOR_WORDS-1)))
            $display("[%0t] PASS: T4 last word matches", $time);
        else begin
            $display("[%0t] FAIL: T4 last word got %04h, expected %04h",
                     $time, capture[TB_SECTOR_WORDS-1],
                     16'hABCD + (TB_SECTOR_WORDS-1));
            errors = errors + 1;
        end

        if (errors == 0) $display("=== ALL SD_READER TESTS PASSED ===");
        else             $display("=== %0d FAILURE(S) ===", errors);
        $finish;
    end

    // Safety timeout
    initial begin
        #1000000;
        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule

`default_nettype wire
