// SPDX-License-Identifier: MIT
//
// sd_model.sv — simulation-only SD-card peer (SPI mode).
//
// Sits on the SPI wires opposite sd_reader and answers the minimum
// command set our host issues:
//
//     CMD0  GO_IDLE_STATE     → R1 = 0x01
//     CMD8  SEND_IF_COND      → R1 = 0x01 + 4-byte R7 echo
//     CMD55 APP_CMD           → R1 = 0x01
//     ACMD41 SD_SEND_OP_COND  → R1 (= 0x01 N times, then 0x00)
//     CMD17 READ_SINGLE_BLOCK → R1=0x00, 0xFE start token,
//                               512 data bytes, 2 CRC16 bytes
//
// Block data for CMD17 to block `sd_lba` follows a deterministic
// pattern that lets a testbench check the read path end-to-end:
//
//     byte[2*i + 0] = (sd_lba[15:0] + i)[ 7:0]      // little-endian
//     byte[2*i + 1] = (sd_lba[15:0] + i)[15:8]
//
// A host that pairs bytes into little-endian 16-bit words sees
// word[i] = sd_lba[15:0] + i — the same pattern the old behavioral
// sd_reader stub used, so mailbox / PCMCIA TBs that called READ_SECTOR
// can keep their existing assertions when wired against this model.
//
// CRC7 / CRC16 are not validated — real SDHC cards in SPI mode don't
// check CRC7 by default, and our docs/sd-protocol.md notes CRC16
// validation is optional for the host. The model returns CRC16=0x0000
// after each data block.
//
// This is **simulation only** — uses always @(posedge spi_clk) /
// @(negedge spi_clk), not synthesizable.

`default_nettype none

module sd_model #(
    parameter int ACMD41_BUSY_RETRIES = 1,
    parameter int CMD17_NAC_BYTES     = 4,
    parameter bit VERBOSE              = 1'b1
)(
    input  wire spi_clk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    output reg  spi_miso
);

    // ------------------------------------------------------------------
    // RX byte assembly — every 8 rising SCLK edges produce a new byte.
    // ------------------------------------------------------------------
    reg [7:0] rx_shift;
    reg [2:0] rx_bit_cnt;             // bits accumulated in rx_shift
    reg [7:0] rx_byte;
    reg       rx_byte_strobe;

    initial begin
        rx_shift       = 8'h00;
        rx_bit_cnt     = 3'd0;
        rx_byte        = 8'h00;
        rx_byte_strobe = 1'b0;
        spi_miso       = 1'b1;
    end

    always @(posedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            rx_bit_cnt     <= 3'd0;
            rx_byte_strobe <= 1'b0;
        end else begin
            rx_byte_strobe <= 1'b0;
            if (rx_bit_cnt == 3'd7) begin
                rx_byte        <= {rx_shift[6:0], spi_mosi};
                rx_shift       <= {rx_shift[6:0], spi_mosi};
                rx_bit_cnt     <= 3'd0;
                rx_byte_strobe <= 1'b1;
            end else begin
                rx_shift   <= {rx_shift[6:0], spi_mosi};
                rx_bit_cnt <= rx_bit_cnt + 3'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Command-frame parser. Watches rx_byte_strobe for "01xxxxxx" start
    // byte, captures 5 more bytes, then signals `cmd_ready` with the
    // 6-bit index and 32-bit arg. The response-program FSM below picks
    // it up on the next clock and starts queuing the answer.
    // ------------------------------------------------------------------
    reg        in_frame;
    reg [2:0]  cmd_byte_cnt;
    reg [5:0]  cmd_idx;
    reg [31:0] cmd_arg;
    reg        cmd_ready;

    initial begin
        in_frame     = 1'b0;
        cmd_byte_cnt = 3'd0;
        cmd_idx      = 6'd0;
        cmd_arg      = 32'd0;
        cmd_ready    = 1'b0;
    end

    always @(posedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            in_frame     <= 1'b0;
            cmd_byte_cnt <= 3'd0;
            cmd_ready    <= 1'b0;
        end else begin
            cmd_ready <= 1'b0;
            if (rx_byte_strobe) begin
                if (!in_frame) begin
                    if (rx_byte[7:6] == 2'b01) begin
                        cmd_idx      <= rx_byte[5:0];
                        in_frame     <= 1'b1;
                        cmd_byte_cnt <= 3'd1;
                    end
                end else begin
                    case (cmd_byte_cnt)
                        3'd1: cmd_arg[31:24] <= rx_byte;
                        3'd2: cmd_arg[23:16] <= rx_byte;
                        3'd3: cmd_arg[15: 8] <= rx_byte;
                        3'd4: cmd_arg[ 7: 0] <= rx_byte;
                        3'd5: begin
                            // CRC byte — we don't validate it.
                            cmd_ready    <= 1'b1;
                            in_frame     <= 1'b0;
                            cmd_byte_cnt <= 3'd0;
                        end
                        default: ;
                    endcase
                    if (cmd_byte_cnt != 3'd5) cmd_byte_cnt <= cmd_byte_cnt + 3'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Response-program FSM
    //
    // Translates a completed command into a byte sequence streamed back
    // on MISO. Each command type lives in its own state; the state
    // advances one byte at a time, paced by the MISO TX byte boundary
    // signal `tx_byte_advance` (= falling SCLK where tx_bit_idx wrapped).
    //
    // The MISO byte source (tx_shift) is loaded with the byte to send
    // *one byte boundary in advance* (so it's stable for the first MSB
    // of the response on the next byte interval).
    //
    // Programs implemented:
    //   PROG_R1     : one R1 byte
    //   PROG_R7     : R1 + 4 bytes (CMD8)
    //   PROG_CMD17  : R1=0x00 + N idle bytes + 0xFE + 512 data + 2 CRC
    //
    // All other commands return R1 = 0x04 (illegal command bit).
    // ------------------------------------------------------------------
    localparam [3:0]
        P_IDLE       = 4'd0,
        P_SEND_R1    = 4'd1,    // one byte (next_tx_byte)
        P_SEND_R7    = 4'd2,    // 4 bytes from r7_payload
        P_NAC        = 4'd3,    // emit CMD17_NAC_BYTES 0xFF bytes
        P_TOKEN      = 4'd4,    // emit 0xFE
        P_DATA       = 4'd5,    // emit 512 data bytes
        P_CRC1       = 4'd6,    // emit CRC16 hi (0x00)
        P_CRC2       = 4'd7;    // emit CRC16 lo (0x00)

    reg [3:0]  prog_state;
    reg [7:0]  next_tx_byte;     // byte to load into tx_shift at next boundary
    reg        next_tx_valid;
    reg [3:0]  r7_idx;
    reg [7:0]  r7_payload [0:3];
    reg [15:0] nac_left;
    reg [15:0] data_idx;
    reg [15:0] block_lba_lo;
    reg        app_cmd_armed;
    integer    acmd41_busy_left;

    initial begin
        prog_state       = P_IDLE;
        next_tx_byte     = 8'hFF;
        next_tx_valid    = 1'b0;
        r7_idx           = 4'd0;
        nac_left         = 16'd0;
        data_idx         = 16'd0;
        block_lba_lo     = 16'd0;
        app_cmd_armed    = 1'b0;
        acmd41_busy_left = ACMD41_BUSY_RETRIES;
    end

    // ------------------------------------------------------------------
    // MISO byte source — drives spi_miso on falling SCLK edges, MSB
    // first. On each byte boundary (= tx_bit_idx wraps from 0 back to
    // 7), the response program supplies the next byte via
    // (next_tx_byte, next_tx_valid). If next_tx_valid is 0, we send 0xFF.
    // The program FSM observes `tx_byte_advance` to know when to fill
    // next_tx_byte for the *following* byte.
    // ------------------------------------------------------------------
    reg [7:0] tx_shift;
    reg [2:0] tx_bit_idx;
    reg       tx_byte_advance;   // pulses on the falling edge that ends a byte

    initial begin
        tx_shift        = 8'hFF;
        tx_bit_idx      = 3'd7;
        tx_byte_advance = 1'b0;
    end

    always @(negedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            tx_shift        <= 8'hFF;
            tx_bit_idx      <= 3'd7;
            tx_byte_advance <= 1'b0;
            spi_miso        <= 1'b1;
        end else begin
            tx_byte_advance <= 1'b0;
            // SPI mode 0: the *first* sd_clk falling edge is the very
            // edge on which CS dropped (the host's last init-dummy
            // SCLK fall and `spi_cs_n <= 0` resolve in the same NBA
            // cycle). That falling stages bit 7 of byte 1 — which is
            // what host rising 1 samples. Subsequent fallings stage
            // bits 6, 5, …, 0; falling 7 then loads the next byte and
            // also drives byte 1 bit 0 (so rising 8 sees it).  Net
            // result: byte 1 spans host risings 1..8.
            spi_miso <= tx_shift[tx_bit_idx];
            if (tx_bit_idx == 3'd0) begin
                tx_shift        <= next_tx_valid ? next_tx_byte : 8'hFF;
                tx_bit_idx      <= 3'd7;
                tx_byte_advance <= 1'b1;
            end else begin
                tx_bit_idx <= tx_bit_idx - 3'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Program FSM — advances exactly one step per `tx_byte_advance`
    // pulse OR on `cmd_ready` (to kick off a new response).
    //
    // To keep this in a single always block without re-introducing the
    // multi-driver problem, we use a clocked block on spi_clk's falling
    // edge (= same time `tx_byte_advance` fires) plus a posedge spi_clk
    // observation of `cmd_ready` via a 1-bit latching reg.
    // ------------------------------------------------------------------
    reg cmd_pending;
    reg [5:0]  pending_idx;
    reg [31:0] pending_arg;

    always @(posedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            cmd_pending <= 1'b0;
        end else if (cmd_ready) begin
            cmd_pending <= 1'b1;
            pending_idx <= cmd_idx;
            pending_arg <= cmd_arg;
            if (VERBOSE)
                $display("[%0t] sd_model: rx CMD%0d arg=%08h", $time, cmd_idx, cmd_arg);
        end else if (prog_state != P_IDLE) begin
            // Once we've started a response we don't take a new cmd
            cmd_pending <= 1'b0;
        end
    end

    always @(negedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            prog_state       <= P_IDLE;
            next_tx_byte     <= 8'hFF;
            next_tx_valid    <= 1'b0;
            r7_idx           <= 4'd0;
            nac_left         <= 16'd0;
            data_idx         <= 16'd0;
            block_lba_lo     <= 16'd0;
            app_cmd_armed    <= 1'b0;
            acmd41_busy_left <= ACMD41_BUSY_RETRIES;
        end else begin
            // Default: next_tx_byte goes invalid (idle 0xFF) unless we
            // reassert it below.
            if (tx_byte_advance) next_tx_valid <= 1'b0;

            case (prog_state)
                P_IDLE: begin
                    if (cmd_pending) begin
                        case (pending_idx)
                            6'd0: begin                            // CMD0
                                next_tx_byte  <= 8'h01;
                                next_tx_valid <= 1'b1;
                                prog_state    <= P_SEND_R1;
                                app_cmd_armed <= 1'b0;
                            end
                            6'd8: begin                            // CMD8
                                next_tx_byte    <= 8'h01;          // R1
                                next_tx_valid   <= 1'b1;
                                r7_payload[0]   <= 8'h00;
                                r7_payload[1]   <= 8'h00;
                                r7_payload[2]   <= 8'h01;          // voltage 2.7-3.6V
                                r7_payload[3]   <= pending_arg[7:0]; // check pattern echo
                                r7_idx          <= 4'd0;
                                prog_state      <= P_SEND_R1;      // R1 first
                                app_cmd_armed   <= 1'b0;
                                // After R1 we'll fall into P_SEND_R7 below.
                            end
                            6'd55: begin                           // CMD55
                                next_tx_byte  <= 8'h01;
                                next_tx_valid <= 1'b1;
                                prog_state    <= P_SEND_R1;
                                app_cmd_armed <= 1'b1;
                            end
                            6'd41: begin                           // ACMD41
                                if (app_cmd_armed) begin
                                    if (acmd41_busy_left > 0) begin
                                        next_tx_byte     <= 8'h01;
                                        acmd41_busy_left <= acmd41_busy_left - 1;
                                    end else begin
                                        next_tx_byte <= 8'h00;
                                    end
                                end else begin
                                    next_tx_byte <= 8'h05;         // illegal cmd
                                end
                                next_tx_valid <= 1'b1;
                                prog_state    <= P_SEND_R1;
                                app_cmd_armed <= 1'b0;
                            end
                            6'd17: begin                           // CMD17
                                next_tx_byte  <= 8'h00;            // R1 = ready
                                next_tx_valid <= 1'b1;
                                block_lba_lo  <= pending_arg[15:0];
                                nac_left      <= CMD17_NAC_BYTES[15:0];
                                data_idx      <= 16'd0;
                                prog_state    <= P_SEND_R1;
                                app_cmd_armed <= 1'b0;
                                // After R1 we fall into P_NAC → P_TOKEN → P_DATA → CRCs
                            end
                            default: begin
                                next_tx_byte  <= 8'h04;            // illegal cmd
                                next_tx_valid <= 1'b1;
                                prog_state    <= P_SEND_R1;
                                app_cmd_armed <= 1'b0;
                            end
                        endcase
                    end
                end

                P_SEND_R1: if (tx_byte_advance) begin
                    // R1 byte just got latched into tx_shift. What's next?
                    case (pending_idx)
                        6'd8:  begin
                            next_tx_byte  <= r7_payload[0];
                            next_tx_valid <= 1'b1;
                            r7_idx        <= 4'd1;
                            prog_state    <= P_SEND_R7;
                        end
                        6'd17: begin
                            if (CMD17_NAC_BYTES == 0) begin
                                next_tx_byte  <= 8'hFE;
                                next_tx_valid <= 1'b1;
                                prog_state    <= P_TOKEN;
                            end else begin
                                // First post-R1 byte is idle 0xFF
                                // (next_tx_valid stays 0); switch to
                                // P_NAC to count the remaining idle
                                // bytes and finally arm the 0xFE token.
                                prog_state <= P_NAC;
                            end
                        end
                        default: prog_state <= P_IDLE;
                    endcase
                end

                P_SEND_R7: if (tx_byte_advance) begin
                    if (r7_idx == 4'd4) begin
                        prog_state <= P_IDLE;
                    end else begin
                        next_tx_byte  <= r7_payload[r7_idx[1:0]];
                        next_tx_valid <= 1'b1;
                        r7_idx        <= r7_idx + 4'd1;
                    end
                end

                P_NAC: if (tx_byte_advance) begin
                    // tx_byte_advance fires AT THE END of each NAC idle
                    // byte. When nac_left==1 we've just sent the last
                    // idle byte, so arm 0xFE as the next byte.
                    if (nac_left == 16'd1) begin
                        next_tx_byte  <= 8'hFE;
                        next_tx_valid <= 1'b1;
                        nac_left      <= 16'd0;
                        prog_state    <= P_TOKEN;
                    end else begin
                        nac_left <= nac_left - 16'd1;
                    end
                end

                P_TOKEN: if (tx_byte_advance) begin
                    // 0xFE has been latched into tx_shift. Now stream data.
                    next_tx_byte  <= data_byte(block_lba_lo, 16'd0);
                    next_tx_valid <= 1'b1;
                    data_idx      <= 16'd1;
                    prog_state    <= P_DATA;
                end

                P_DATA: if (tx_byte_advance) begin
                    if (data_idx == 16'd512) begin
                        next_tx_byte  <= 8'h00;
                        next_tx_valid <= 1'b1;
                        prog_state    <= P_CRC1;
                    end else begin
                        next_tx_byte  <= data_byte(block_lba_lo, data_idx);
                        next_tx_valid <= 1'b1;
                        data_idx      <= data_idx + 16'd1;
                    end
                end

                P_CRC1: if (tx_byte_advance) begin
                    next_tx_byte  <= 8'h00;
                    next_tx_valid <= 1'b1;
                    prog_state    <= P_CRC2;
                end

                P_CRC2: if (tx_byte_advance) begin
                    prog_state <= P_IDLE;
                end

                default: prog_state <= P_IDLE;
            endcase
        end
    end

    // Deterministic data pattern: low byte of word i = (lba_lo + i)[7:0],
    // high byte = (lba_lo + i)[15:8]. Word index i = byte_idx >> 1.
    function automatic [7:0] data_byte(input [15:0] lba_lo, input [15:0] byte_idx);
        reg [15:0] w;
        begin
            w = lba_lo + (byte_idx >> 1);
            data_byte = byte_idx[0] ? w[15:8] : w[7:0];
        end
    endfunction

endmodule

`default_nettype wire
