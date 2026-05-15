// SPDX-License-Identifier: MIT
//
// sd_reader.sv — SPI-mode SD-card host for RGBLorean.
//
// Phase 2 of the sector-source abstraction. Replaces the earlier
// behavioral stub (which emitted word[i]=lba[15:0]+i without ever
// touching the SPI wires).
//
// External contract (towards pcmcia_target's mailbox FSM) is unchanged:
//
//     1. Host pulses `req` for one cycle with a stable LBA.
//     2. `busy` rises. The module emits `SECTOR_WORDS` 16-bit words via
//        (wr_idx, wr_data, wr_en), one word per word's worth of SPI bits.
//        `wr_idx` runs 0..SECTOR_WORDS-1.
//     3. `done` pulses for one cycle on the last word, `busy` drops.
//
// Internally, one host-side request is split into `BLOCKS_PER_REQ`
// successive CMD17 reads of 512-byte SD blocks. Block N covers host
// words [N*256 .. N*256+255]. Default BLOCKS_PER_REQ=4 → 1024 words =
// 2 KB = one Marty CD-ROM sector. Testbenches that shrink SECTOR_WORDS
// must also shrink BLOCKS_PER_REQ to match (e.g. SECTOR_WORDS=16,
// BLOCKS_PER_REQ=1, ignoring the unused 240 trailing words from the
// 256-word SD block).
//
// SPI wire conventions:
//   - Mode 0 (CPOL=0, CPHA=0): SCLK idle low, MOSI changes on falling
//     edge of SCLK, MISO sampled on rising edge.
//   - MSB first on both directions.
//   - On reset, init is *lazy*: the FSM stays in S_IDLE_PREINIT and
//     does not toggle SCLK until the first `req`. This lets the IPL
//     smoke / pcmcia_target self-tests instantiate sd_reader without
//     wiring up an sd_model (their MISO can stay floating-high).
//
// See `docs/sd-protocol.md` for the SD command/response details.

`default_nettype none

module sd_reader #(
    // 16-bit words returned to the host per `req`. Default = 1024 (2 KB,
    // one Marty CD-ROM sector). For sim, smaller values work but the
    // module always clocks in a full SD block per CMD17 (excess bytes
    // are silently dropped after SECTOR_WORDS).
    parameter int SECTOR_WORDS    = 1024,
    // SD blocks read per `req`. Production: 4 (= 2048 bytes / 1024 words).
    parameter int BLOCKS_PER_REQ  = 4,
    // Half-period of SCLK during init, in system-clock cycles. With a
    // 100 MHz sysclk, 128 = 391 kHz (spec: 100–400 kHz).
    parameter int SCLK_HALF_INIT  = 128,
    // Half-period of SCLK during data transfer. 2 = 25 MHz (spec max
    // for default-speed cards). Override smaller in sim.
    parameter int SCLK_HALF_RUN   = 2,
    // Dummy SCLK cycles to clock with CS high before CMD0. Spec ≥ 74.
    parameter int INIT_DUMMY_CLKS = 80,
    // Maximum CMD55+ACMD41 retries before giving up.
    parameter int ACMD41_MAX_TRIES = 64,
    // Maximum idle bytes to clock while waiting for a non-0xFF response
    // (R1) or 0xFE (start token). 512 is generous for SD spec.
    parameter int RX_POLL_MAX      = 512
)(
    input  wire        clk,
    input  wire        rst_n,

    // Host-side request interface
    input  wire        req,
    input  wire [31:0] lba,
    output reg  [15:0] wr_idx,
    output reg  [15:0] wr_data,
    output reg         wr_en,
    output reg         busy,
    output reg         done,

    // SPI wires
    output reg         spi_clk,
    output reg         spi_cs_n,
    output wire        spi_mosi,
    input  wire        spi_miso
);

    // ==================================================================
    // CRC7 over the 40-bit start+tx+idx+arg field. Used in the 6-byte
    // command frame's last byte (`{crc7, 1'b1}`).
    // ==================================================================
    function automatic [6:0] crc7_calc(input [39:0] data);
        integer i;
        reg [6:0] crc;
        reg       fb;
        begin
            crc = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                fb  = crc[6] ^ data[i];
                crc = {crc[5:0], 1'b0};
                if (fb) crc = crc ^ 7'h09;
            end
            crc7_calc = crc;
        end
    endfunction

    function automatic [47:0] make_frame(input [5:0] idx, input [31:0] arg);
        reg [39:0] core;
        reg [6:0]  crc;
        begin
            core       = {2'b01, idx, arg};
            crc        = crc7_calc(core);
            make_frame = {core, crc, 1'b1};
        end
    endfunction

    // ==================================================================
    // SPI clock divider — free-running while `sclk_enable=1`. Generates
    // SPI mode-0 SCLK plus two single-cycle strobes the rest of the
    // module triggers on.
    // ==================================================================
    reg [15:0] half_period;
    reg [15:0] phase_cnt;
    reg        sclk_enable;

    // Using `>=` rather than `==` so that a mid-run change of
    // half_period (e.g. INIT→RUN after ACMD41 success) can't leave
    // phase_cnt past the new full mark with no wrap condition matching.
    // Worst-case the change forces a single falling edge before the
    // divider snaps back to the new cadence — spurious *risings* never
    // happen this way, so sd_model's bit-count alignment stays intact.
    wire phase_at_half_minus1 = (phase_cnt == half_period - 16'd1);
    wire phase_at_full_minus1 = (phase_cnt + 16'd1 >= (half_period << 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt <= 16'd0;
            spi_clk   <= 1'b0;
        end else if (sclk_enable) begin
            if (phase_at_full_minus1) begin
                phase_cnt <= 16'd0;
                spi_clk   <= 1'b0;       // entering low half
            end else begin
                phase_cnt <= phase_cnt + 16'd1;
                if (phase_at_half_minus1) spi_clk <= 1'b1;  // entering high half
            end
        end else begin
            phase_cnt <= 16'd0;
            spi_clk   <= 1'b0;
        end
    end

    // sclk_fall_tick fires the system-clock cycle the falling edge of
    // SCLK happens (= phase wraps to 0). sclk_rise_tick fires the cycle
    // the rising edge happens (= phase reaches half_period). Both are
    // single-cycle pulses; the FSM uses them to advance bit shifters.
    wire sclk_fall_tick = sclk_enable && phase_at_full_minus1;
    wire sclk_rise_tick = sclk_enable && phase_at_half_minus1;

    // ==================================================================
    // Bit-engine — drives MOSI / samples MISO under control of
    // `start_tx_pulse` / `start_rx_pulse` (1-cycle pulses from the main
    // FSM). Owns: tx_byte, rx_byte, tx_bits_left, rx_bits_left, mosi_q,
    // tx_byte_done, rx_byte_done. The main FSM owns the start pulses.
    //
    // start_tx_pulse + tx_byte_load: latch byte, drive MSB onto MOSI at
    //   the next sclk_fall_tick, shift on every subsequent fall, fire
    //   tx_byte_done once 8 bits have been clocked (= 8 fall ticks).
    // start_rx_pulse: arm RX shifter. On every sclk_rise_tick sample
    //   MISO into LSB. After 8 samples fire rx_byte_done.
    // ==================================================================
    reg        start_tx_pulse;
    reg        start_rx_pulse;
    reg [7:0]  tx_byte_load;

    reg [7:0]  tx_byte;
    reg [7:0]  rx_byte;
    reg [3:0]  tx_bits_left;
    reg [3:0]  rx_bits_left;
    reg        mosi_q;
    reg        tx_byte_done;
    reg        rx_byte_done;

    assign spi_mosi = mosi_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_byte      <= 8'hFF;
            rx_byte      <= 8'hFF;
            tx_bits_left <= 4'd0;
            rx_bits_left <= 4'd0;
            mosi_q       <= 1'b1;
            tx_byte_done <= 1'b0;
            rx_byte_done <= 1'b0;
        end else begin
            tx_byte_done <= 1'b0;
            rx_byte_done <= 1'b0;

            if (start_tx_pulse) begin
                tx_byte      <= tx_byte_load;
                tx_bits_left <= 4'd8;
                mosi_q       <= tx_byte_load[7];
            end
            if (start_rx_pulse) begin
                rx_bits_left <= 4'd8;
            end

            // TX advance on falling edge of SCLK
            if (sclk_fall_tick && tx_bits_left != 4'd0) begin
                if (tx_bits_left == 4'd1) begin
                    tx_bits_left <= 4'd0;
                    tx_byte_done <= 1'b1;
                    mosi_q       <= 1'b1;     // idle high after last bit
                end else begin
                    // Bit that was on the wire just got clocked into the
                    // card; present the next MSB.
                    tx_byte      <= {tx_byte[6:0], 1'b1};
                    mosi_q       <= tx_byte[6];
                    tx_bits_left <= tx_bits_left - 4'd1;
                end
            end

            // RX advance on rising edge of SCLK. The `start_rx_pulse`
            // arrival can race with a rising tick — if both fire the
            // same cycle, the FSM "intended" the burst to include this
            // tick, so we sample with an effective rx_bits_left of 8
            // (and consume one of those eight here). Without this
            // explicit handling we'd skip the first rising whenever
            // start_rx_pulse landed on its cycle, putting sd_model's
            // bit count out of byte alignment after every RX retry.
            if (sclk_rise_tick) begin
                if (start_rx_pulse) begin
                    rx_byte      <= {rx_byte[6:0], spi_miso};
                    rx_bits_left <= 4'd7;
                end else if (rx_bits_left != 4'd0) begin
                    rx_byte <= {rx_byte[6:0], spi_miso};
                    if (rx_bits_left == 4'd1) begin
                        rx_bits_left <= 4'd0;
                        rx_byte_done <= 1'b1;
                    end else begin
                        rx_bits_left <= rx_bits_left - 4'd1;
                    end
                end
            end
        end
    end

    // ==================================================================
    // High-level FSM.
    // ==================================================================
    localparam [5:0]
        S_IDLE_PREINIT  = 6'd0,
        S_INIT_DUMMY    = 6'd1,
        S_CMD_LOAD      = 6'd2,
        S_CMD_TX        = 6'd3,
        S_R1_RX         = 6'd5,
        S_R1_CHECK      = 6'd6,
        S_R7_DRAIN      = 6'd7,
        S_TOKEN_RX      = 6'd8,
        S_DATA_RX       = 6'd9,
        S_CRC_RX        = 6'd11,
        S_NEXT_BLOCK    = 6'd12,
        S_REQ_DONE      = 6'd13,
        S_REINIT_WAIT   = 6'd14,
        S_ERROR         = 6'd31;

    // Which command is currently in flight — drives what we do after R1.
    localparam [2:0]
        CMD_NONE   = 3'd0,
        CMD_CMD0   = 3'd1,
        CMD_CMD8   = 3'd2,
        CMD_CMD55  = 3'd3,
        CMD_ACMD41 = 3'd4,
        CMD_CMD17  = 3'd5;

    reg [5:0]  state;
    reg [2:0]  cur_cmd;

    reg [47:0] cmd_frame;
    reg [3:0]  cmd_byte_idx;

    reg [15:0] init_dummy_left;
    reg [15:0] r1_poll_left;
    reg [15:0] r7_bytes_left;
    reg [15:0] data_byte_idx;
    reg [15:0] crc_bytes_left;
    reg [15:0] block_idx;
    reg [15:0] word_idx_within_req;
    reg        byte_pair_low;
    reg [7:0]  pair_low_byte;
    reg [31:0] sd_lba_base;
    reg [15:0] acmd41_tries_left;
    reg        initialized;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= S_IDLE_PREINIT;
            cur_cmd             <= CMD_NONE;
            spi_cs_n            <= 1'b1;
            sclk_enable         <= 1'b0;
            half_period         <= SCLK_HALF_INIT[15:0];
            wr_idx              <= 16'd0;
            wr_data             <= 16'd0;
            wr_en               <= 1'b0;
            busy                <= 1'b0;
            done                <= 1'b0;
            cmd_frame           <= 48'h0;
            cmd_byte_idx        <= 4'd0;
            init_dummy_left     <= 16'd0;
            r1_poll_left        <= 16'd0;
            r7_bytes_left       <= 16'd0;
            data_byte_idx       <= 16'd0;
            crc_bytes_left      <= 16'd0;
            block_idx           <= 16'd0;
            word_idx_within_req <= 16'd0;
            byte_pair_low       <= 1'b0;
            pair_low_byte       <= 8'h0;
            sd_lba_base         <= 32'd0;
            acmd41_tries_left   <= ACMD41_MAX_TRIES[15:0];
            initialized         <= 1'b0;
            start_tx_pulse      <= 1'b0;
            start_rx_pulse      <= 1'b0;
            tx_byte_load        <= 8'hFF;
        end else begin
            // Defaults — pulses deassert each cycle
            wr_en          <= 1'b0;
            done           <= 1'b0;
            start_tx_pulse <= 1'b0;
            start_rx_pulse <= 1'b0;

            case (state)

                // ---- Lazy idle: wait for first req. SCLK off, CS high.
                S_IDLE_PREINIT: begin
                    busy        <= 1'b0;
                    spi_cs_n    <= 1'b1;
                    sclk_enable <= 1'b0;
                    if (req) begin
                        busy        <= 1'b1;
                        sd_lba_base <= lba;
                        if (initialized) begin
                            // Already through init. Spin SCLK while
                            // CS stays high until we hit a falling
                            // tick — then drop CS coincident with
                            // that tick. This makes the CS-low edge
                            // line up with a falling spi_clk just
                            // like at the end of the dummy phase,
                            // keeping sd_model's byte alignment
                            // identical between the first and any
                            // subsequent req. Without this, the
                            // model's tx-bit counter is off by one
                            // bit on subsequent reqs.
                            block_idx           <= 16'd0;
                            word_idx_within_req <= 16'd0;
                            byte_pair_low       <= 1'b0;
                            half_period         <= SCLK_HALF_RUN[15:0];
                            sclk_enable         <= 1'b1;
                            spi_cs_n            <= 1'b1;
                            state               <= S_REINIT_WAIT;
                        end else begin
                            half_period     <= SCLK_HALF_INIT[15:0];
                            init_dummy_left <= INIT_DUMMY_CLKS[15:0];
                            sclk_enable     <= 1'b1;
                            spi_cs_n        <= 1'b1;
                            state           <= S_INIT_DUMMY;
                        end
                    end
                end

                // ---- Brief pre-CMD17 phase for re-armed sessions.
                //      Wait one falling tick, then drop CS on that edge.
                S_REINIT_WAIT: begin
                    if (sclk_fall_tick) begin
                        spi_cs_n     <= 1'b0;
                        cmd_frame    <= make_frame(6'd17, sd_lba_base);
                        cmd_byte_idx <= 4'd0;
                        cur_cmd      <= CMD_CMD17;
                        state        <= S_CMD_LOAD;
                    end
                end

                // ---- ≥74 dummy SCLK cycles with CS high.
                S_INIT_DUMMY: begin
                    if (sclk_fall_tick) begin
                        if (init_dummy_left == 16'd1) begin
                            spi_cs_n          <= 1'b0;
                            cmd_frame         <= make_frame(6'd0, 32'h00000000);
                            cmd_byte_idx      <= 4'd0;
                            cur_cmd           <= CMD_CMD0;
                            state             <= S_CMD_LOAD;
                            acmd41_tries_left <= ACMD41_MAX_TRIES[15:0];
                        end else begin
                            init_dummy_left <= init_dummy_left - 16'd1;
                        end
                    end
                end

                // ---- Generic 6-byte command-frame transmit.
                S_CMD_LOAD: begin
                    // Prime the byte engine with cmd_frame[47:40] and
                    // wait one tick for it to start clocking out.
                    tx_byte_load    <= cmd_frame[47:40];
                    start_tx_pulse  <= 1'b1;
                    state           <= S_CMD_TX;
                end

                S_CMD_TX: begin
                    if (tx_byte_done) begin
                        if (cmd_byte_idx == 4'd5) begin
                            // Command fully sent. Start hunting for R1.
                            cmd_byte_idx   <= 4'd0;
                            r1_poll_left   <= RX_POLL_MAX[15:0];
                            start_rx_pulse <= 1'b1;
                            state          <= S_R1_RX;
                        end else begin
                            // Chain to next byte same cycle. cmd_frame[39:32]
                            // is the OLD pre-shift value = the next byte;
                            // the parallel cmd_frame <= … shift lines that
                            // up at [47:40] for symmetry with subsequent
                            // chained iterations.
                            cmd_frame      <= {cmd_frame[39:0], 8'hFF};
                            cmd_byte_idx   <= cmd_byte_idx + 4'd1;
                            tx_byte_load   <= cmd_frame[39:32];
                            start_tx_pulse <= 1'b1;
                        end
                    end
                end

                // ---- Wait for first byte with MSB=0; that's R1.
                S_R1_RX: begin
                    if (rx_byte_done) begin
                        if (rx_byte[7] == 1'b0) begin
                            state <= S_R1_CHECK;
                        end else if (r1_poll_left == 16'd1) begin
                            state <= S_ERROR;
                        end else begin
                            r1_poll_left   <= r1_poll_left - 16'd1;
                            start_rx_pulse <= 1'b1;
                        end
                    end
                end

                S_R1_CHECK: begin
                    // rx_byte holds R1. Decide what to do next based on cur_cmd.
                    case (cur_cmd)
                        CMD_CMD0: begin
                            // Accept any R1; advance to CMD8.
                            cmd_frame    <= make_frame(6'd8, 32'h000001AA);
                            cmd_byte_idx <= 4'd0;
                            cur_cmd      <= CMD_CMD8;
                            state        <= S_CMD_LOAD;
                        end
                        CMD_CMD8: begin
                            // R7 has 4 trailing bytes to drain.
                            r7_bytes_left  <= 16'd4;
                            start_rx_pulse <= 1'b1;
                            state          <= S_R7_DRAIN;
                        end
                        CMD_CMD55: begin
                            cmd_frame    <= make_frame(6'd41, 32'h40FF8000);
                            cmd_byte_idx <= 4'd0;
                            cur_cmd      <= CMD_ACMD41;
                            state        <= S_CMD_LOAD;
                        end
                        CMD_ACMD41: begin
                            if (rx_byte == 8'h00) begin
                                // Card ready. Switch to fast SCLK and
                                // begin the CMD17 sequence.
                                initialized         <= 1'b1;
                                half_period         <= SCLK_HALF_RUN[15:0];
                                block_idx           <= 16'd0;
                                word_idx_within_req <= 16'd0;
                                byte_pair_low       <= 1'b0;
                                cmd_frame           <= make_frame(6'd17, sd_lba_base);
                                cmd_byte_idx        <= 4'd0;
                                cur_cmd             <= CMD_CMD17;
                                state               <= S_CMD_LOAD;
                            end else if (acmd41_tries_left == 16'd1) begin
                                state <= S_ERROR;
                            end else begin
                                acmd41_tries_left <= acmd41_tries_left - 16'd1;
                                cmd_frame         <= make_frame(6'd55, 32'h00000000);
                                cmd_byte_idx      <= 4'd0;
                                cur_cmd           <= CMD_CMD55;
                                state             <= S_CMD_LOAD;
                            end
                        end
                        CMD_CMD17: begin
                            if (rx_byte != 8'h00) state <= S_ERROR;
                            else begin
                                r1_poll_left   <= RX_POLL_MAX[15:0];
                                start_rx_pulse <= 1'b1;
                                state          <= S_TOKEN_RX;
                            end
                        end
                        default: state <= S_ERROR;
                    endcase
                end

                // ---- Drain R7 trailing bytes (CMD8 only).
                S_R7_DRAIN: begin
                    if (rx_byte_done) begin
                        if (r7_bytes_left == 16'd1) begin
                            // Done draining — move on to CMD55+ACMD41 loop.
                            cmd_frame    <= make_frame(6'd55, 32'h00000000);
                            cmd_byte_idx <= 4'd0;
                            cur_cmd      <= CMD_CMD55;
                            state        <= S_CMD_LOAD;
                        end else begin
                            r7_bytes_left  <= r7_bytes_left - 16'd1;
                            start_rx_pulse <= 1'b1;
                        end
                    end
                end

                // ---- Hunt for 0xFE start token (CMD17 data phase).
                S_TOKEN_RX: begin
                    if (rx_byte_done) begin
                        if (rx_byte == 8'hFE) begin
                            data_byte_idx  <= 16'd0;
                            start_rx_pulse <= 1'b1;
                            state          <= S_DATA_RX;
                        end else if (r1_poll_left == 16'd1) begin
                            state <= S_ERROR;
                        end else begin
                            r1_poll_left   <= r1_poll_left - 16'd1;
                            start_rx_pulse <= 1'b1;
                        end
                    end
                end

                // ---- Read 512 data bytes, pairing into little-endian
                //      16-bit words for the host buffer.
                S_DATA_RX: begin
                    if (rx_byte_done) begin
                        if (byte_pair_low == 1'b0) begin
                            pair_low_byte <= rx_byte;
                            byte_pair_low <= 1'b1;
                        end else begin
                            byte_pair_low <= 1'b0;
                            if (word_idx_within_req < SECTOR_WORDS[15:0]) begin
                                wr_idx              <= word_idx_within_req;
                                wr_data             <= {rx_byte, pair_low_byte};
                                wr_en               <= 1'b1;
                                word_idx_within_req <= word_idx_within_req + 16'd1;
                            end
                        end

                        if (data_byte_idx == 16'd511) begin
                            crc_bytes_left <= 16'd2;
                            start_rx_pulse <= 1'b1;
                            state          <= S_CRC_RX;
                        end else begin
                            data_byte_idx  <= data_byte_idx + 16'd1;
                            start_rx_pulse <= 1'b1;
                        end
                    end
                end

                S_CRC_RX: begin
                    if (rx_byte_done) begin
                        if (crc_bytes_left == 16'd1) begin
                            state <= S_NEXT_BLOCK;
                        end else begin
                            crc_bytes_left <= crc_bytes_left - 16'd1;
                            start_rx_pulse <= 1'b1;
                        end
                    end
                end

                S_NEXT_BLOCK: begin
                    if (block_idx == BLOCKS_PER_REQ[15:0] - 16'd1) begin
                        state <= S_REQ_DONE;
                    end else begin
                        block_idx     <= block_idx + 16'd1;
                        cmd_frame     <= make_frame(6'd17, sd_lba_base
                                                    + {16'd0, block_idx} + 32'd1);
                        cmd_byte_idx  <= 4'd0;
                        cur_cmd       <= CMD_CMD17;
                        byte_pair_low <= 1'b0;
                        state         <= S_CMD_LOAD;
                    end
                end

                S_REQ_DONE: begin
                    done        <= 1'b1;
                    busy        <= 1'b0;
                    spi_cs_n    <= 1'b1;
                    sclk_enable <= 1'b0;
                    state       <= S_IDLE_PREINIT;
                end

                S_ERROR: begin
                    busy        <= 1'b0;
                    spi_cs_n    <= 1'b1;
                    sclk_enable <= 1'b0;
                    // Stay here until reset. (Mailbox FSM will eventually
                    // time out — improving this is a follow-up.)
                end

                default: state <= S_IDLE_PREINIT;
            endcase
        end
    end

endmodule

`default_nettype wire
