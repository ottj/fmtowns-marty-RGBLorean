// SPDX-License-Identifier: MIT
//
// pcmcia_target.sv — RGBLorean PCMCIA memory-window target + mailbox FSM
//
// Phase 1+: SRAM-style slave for the FM Towns Marty IC card slot, with a
// command-mailbox FSM that lets the resident x86 driver issue requests
// (FPGA_INFO, READ_SECTOR, ...) and read results back through the same
// memory window.
//
// Memory map (byte addresses, all relative to card window base 0xD00000):
//
//   0x0000 .. 0x07FF   Boot region — BRAM, preloaded from INIT_FILE.
//                      Contains the IPL4 boot sector (0x000..0x3FF) and
//                      the loaded sector-1 payload (0x400..0x7FF).
//   0x0800             command (R/W from host; low byte of MBX word 0)
//   0x0801             status  (R-only host; high byte of MBX word 0)
//   0x0802 .. 0x0803   seq         (MBX word 1, R/W host, FSM ignored P1)
//   0x0804 .. 0x0807   lba (32-bit LE)  (MBX words 2..3, R/W host)
//   0x0808 .. 0x0809   sector_count     (MBX word 4, R/W host)
//   0x080A .. 0x0FFF   Reserved (reads 0xFF, writes ignored)
//   0x1000 .. 0x1FFF   sector_data buffer — BRAM, FPGA writes / host reads.
//
// FSM-supported commands (others → status = ERROR):
//   0x00 NOOP        → status = IDLE (used to clear DONE / ERROR)
//   0x01 READ_SECTOR → writes SECTOR_WORDS words to sector_data buffer,
//                      pattern `word[i] = lba[15:0] + i`; status = DONE.
//                      Phase 1 stub for SD-card-backed sector reads.
//   0x10 FPGA_INFO   → writes "RGBL0001" to sector_data[0..7]; status = DONE.
//
// Bus semantics:
//   - Word/byte writes via separate ~CE1 / ~CE2 byte enables
//   - WE# falling edge latches the write
//   - OE# asserted with at least one CE# drives fp_d
//   - PCMCIA RESET is active-high; clears mailbox flops, preserves BRAM
//
// ADDR_BITS must be >= 12 (mailbox at word 0x400 = byte 0x800; sector_data
// at word 0x800 = byte 0x1000).

`default_nettype none

module pcmcia_target #(
    // Word depth: ADDR_BITS = 12 → 4 KB BRAM (8 KB byte addr range).
    parameter int    ADDR_BITS    = 12,
    // Optional power-on preload (one 16-bit hex word per line).
    parameter        INIT_FILE    = "",
    // Word address of the mailbox base (default = byte 0x800).
    parameter [11:0] MBX_WORD     = 12'h400,
    // Word address where sector_data starts (default = byte 0x1000).
    parameter [11:0] SECDATA_WORD = 12'h800,
    // Number of 16-bit words per sector. 1024 = 2 KB (Marty CD-ROM Mode 1
    // sector). Override to a small value in sim to keep test time short.
    parameter int    SECTOR_WORDS = 1024,
    // SD-reader timing overrides — exposed here so testbenches that run
    // with shrunk SECTOR_WORDS can also dial the SCLK rates up to keep
    // simulation time bounded.
    parameter int    SD_SCLK_HALF_INIT = 128,
    parameter int    SD_SCLK_HALF_RUN  = 2,
    parameter int    SD_INIT_DUMMY     = 80
) (
    input  wire        clk,
    input  wire        rst_n,

    // PCMCIA bus (FPGA side, post level shifters)
    input  wire [25:0] fp_a,
    inout  wire [15:0] fp_d,
    input  wire        fp_ce1_n,
    input  wire        fp_ce2_n,
    input  wire        fp_oe_n,
    input  wire        fp_we_n,
    input  wire        fp_reset,

    // SD-card SPI lines — passed straight through to sd_reader. Top
    // module on the ECP5 routes these to the MicroSD socket pins
    // (FP_SD_CLK, FP_SD_DAT3=/CS, FP_SD_CMD=MOSI, FP_SD_DAT0=MISO).
    output wire        sd_spi_clk,
    output wire        sd_spi_cs_n,
    output wire        sd_spi_mosi,
    input  wire        sd_spi_miso,

    // Debug taps
    output wire        dbg_bus_sel,
    output wire        dbg_bus_rd,
    output wire        dbg_bus_wr,
    output wire [3:0]  dbg_mbx_state
);

    // ------------------------------------------------------------------
    // Synchronizers
    // ------------------------------------------------------------------
    reg [1:0] ce1_sync, ce2_sync, oe_sync, we_sync, reset_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ce1_sync   <= 2'b11;
            ce2_sync   <= 2'b11;
            oe_sync    <= 2'b11;
            we_sync    <= 2'b11;
            reset_sync <= 2'b00;
        end else begin
            ce1_sync   <= {ce1_sync[0],   fp_ce1_n};
            ce2_sync   <= {ce2_sync[0],   fp_ce2_n};
            oe_sync    <= {oe_sync[0],    fp_oe_n};
            we_sync    <= {we_sync[0],    fp_we_n};
            reset_sync <= {reset_sync[0], fp_reset};
        end
    end

    wire ce1_n_s    = ce1_sync[1];
    wire ce2_n_s    = ce2_sync[1];
    wire oe_n_s     = oe_sync[1];
    wire we_n_s     = we_sync[1];
    wire pcmcia_rst = reset_sync[1];

    reg we_n_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) we_n_prev <= 1'b1;
        else        we_n_prev <= we_n_s;
    end
    wire we_falling = we_n_prev && !we_n_s;

    wire selected = !ce1_n_s || !ce2_n_s;
    wire reading  = selected && !oe_n_s;
    wire writing  = selected && !we_n_s;

    assign dbg_bus_sel = selected;
    assign dbg_bus_rd  = reading;
    assign dbg_bus_wr  = writing;

    // ------------------------------------------------------------------
    // Address decode — mailbox region occupies 5 contiguous words
    // ------------------------------------------------------------------
    wire [ADDR_BITS-1:0] word_addr = fp_a[ADDR_BITS:1];
    wire [ADDR_BITS-1:0] mbx_base  = MBX_WORD[ADDR_BITS-1:0];

    wire mbx_w0 = (word_addr == mbx_base);                    // {status, command}
    wire mbx_w1 = (word_addr == mbx_base + 'd1);              // seq
    wire mbx_w2 = (word_addr == mbx_base + 'd2);              // lba[15:0]
    wire mbx_w3 = (word_addr == mbx_base + 'd3);              // lba[31:16]
    wire mbx_w4 = (word_addr == mbx_base + 'd4);              // sector_count

    wire mbx_flop_hit = mbx_w0 || mbx_w1 || mbx_w2 || mbx_w3 || mbx_w4;

    // ------------------------------------------------------------------
    // BRAM (boot region + sector_data + everything not mailbox)
    // ------------------------------------------------------------------
    reg [15:0] mem [0:(1<<ADDR_BITS)-1];
    reg [15:0] mem_read_data;

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (selected) mem_read_data <= mem[word_addr];
    end

    // ------------------------------------------------------------------
    // Mailbox flops
    // ------------------------------------------------------------------
    reg [7:0]  command_reg;
    reg [7:0]  status_reg;
    reg [15:0] seq_reg;
    reg [31:0] lba_reg;
    reg [15:0] sector_count_reg;

    wire host_write_strobe = writing && we_falling;

    // Host writes to mailbox flops (status is read-only for the host)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || pcmcia_rst) begin
            command_reg      <= 8'h00;
            seq_reg          <= 16'h0000;
            lba_reg          <= 32'h00000000;
            sector_count_reg <= 16'h0000;
        end else if (host_write_strobe) begin
            if (mbx_w0 && !ce1_n_s) command_reg              <= fp_d[7:0];
            if (mbx_w1) begin
                if (!ce1_n_s) seq_reg[7:0]                   <= fp_d[7:0];
                if (!ce2_n_s) seq_reg[15:8]                  <= fp_d[15:8];
            end
            if (mbx_w2) begin
                if (!ce1_n_s) lba_reg[7:0]                   <= fp_d[7:0];
                if (!ce2_n_s) lba_reg[15:8]                  <= fp_d[15:8];
            end
            if (mbx_w3) begin
                if (!ce1_n_s) lba_reg[23:16]                 <= fp_d[7:0];
                if (!ce2_n_s) lba_reg[31:24]                 <= fp_d[15:8];
            end
            if (mbx_w4) begin
                if (!ce1_n_s) sector_count_reg[7:0]          <= fp_d[7:0];
                if (!ce2_n_s) sector_count_reg[15:8]         <= fp_d[15:8];
            end
        end
    end

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam logic [3:0] S_IDLE        = 4'd0;
    localparam logic [3:0] S_DECODE      = 4'd1;
    localparam logic [3:0] S_INFO_W0     = 4'd2;
    localparam logic [3:0] S_INFO_W1     = 4'd3;
    localparam logic [3:0] S_INFO_W2     = 4'd4;
    localparam logic [3:0] S_INFO_W3     = 4'd5;
    localparam logic [3:0] S_DONE_WAIT   = 4'd6;
    localparam logic [3:0] S_READ_WAIT   = 4'd7;
    localparam logic [3:0] S_ERROR_WAIT  = 4'd15;

    localparam logic [7:0] STATUS_IDLE  = 8'h00;
    localparam logic [7:0] STATUS_BUSY  = 8'h01;
    localparam logic [7:0] STATUS_DONE  = 8'h02;
    localparam logic [7:0] STATUS_ERROR = 8'hFF;

    localparam logic [7:0] CMD_NOOP        = 8'h00;
    localparam logic [7:0] CMD_READ_SECTOR = 8'h01;
    localparam logic [7:0] CMD_FPGA_INFO   = 8'h10;

    reg [3:0]              mbx_state;
    reg [ADDR_BITS-1:0]    fsm_waddr;
    reg [15:0]             fsm_wdata;
    reg                    fsm_we;

    // ------------------------------------------------------------------
    // sd_reader instance — feeds sector_data for CMD_READ_SECTOR. The FSM
    // pulses sd_req when entering S_READ_WAIT; sd_reader streams its
    // SECTOR_WORDS writes through (sd_wr_idx, sd_wr_data, sd_wr_en) and
    // pulses sd_done when finished. The BRAM-write mux below routes
    // sd_wr_en into the mem[] array at SECDATA_WORD + sd_wr_idx.
    // ------------------------------------------------------------------
    reg                    sd_req;
    wire [15:0]            sd_wr_idx;
    wire [15:0]            sd_wr_data;
    wire                   sd_wr_en;
    wire                   sd_done;
    wire                   sd_busy;

    sd_reader #(
        .SECTOR_WORDS    (SECTOR_WORDS),
        // For SECTOR_WORDS=16 (sim default in mailbox_tb), 1 block is
        // already more bytes than we'll keep; the parameter is plumbed
        // through anyway so production keeps 4 = 1024 words = 2 KB.
        .BLOCKS_PER_REQ  (SECTOR_WORDS > 16 ? 4 : 1),
        .SCLK_HALF_INIT  (SD_SCLK_HALF_INIT),
        .SCLK_HALF_RUN   (SD_SCLK_HALF_RUN),
        .INIT_DUMMY_CLKS (SD_INIT_DUMMY)
    ) u_sd_reader (
        .clk      (clk),
        .rst_n    (rst_n && !pcmcia_rst),
        .req      (sd_req),
        .lba      (lba_reg),
        .wr_idx   (sd_wr_idx),
        .wr_data  (sd_wr_data),
        .wr_en    (sd_wr_en),
        .busy     (sd_busy),
        .done     (sd_done),
        .spi_clk  (sd_spi_clk),
        .spi_cs_n (sd_spi_cs_n),
        .spi_mosi (sd_spi_mosi),
        .spi_miso (sd_spi_miso)
    );

    assign dbg_mbx_state = mbx_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || pcmcia_rst) begin
            mbx_state  <= S_IDLE;
            status_reg <= STATUS_IDLE;
            fsm_we     <= 1'b0;
            fsm_waddr  <= '0;
            fsm_wdata  <= '0;
            sd_req     <= 1'b0;
        end else begin
            fsm_we <= 1'b0;
            sd_req <= 1'b0;
            case (mbx_state)

                S_IDLE: begin
                    status_reg <= STATUS_IDLE;
                    if (command_reg != CMD_NOOP) begin
                        status_reg <= STATUS_BUSY;
                        mbx_state  <= S_DECODE;
                    end
                end

                S_DECODE: begin
                    case (command_reg)
                        CMD_FPGA_INFO:    mbx_state <= S_INFO_W0;
                        CMD_READ_SECTOR: begin
                            sd_req    <= 1'b1;       // one-cycle pulse
                            mbx_state <= S_READ_WAIT;
                        end
                        default:          mbx_state <= S_ERROR_WAIT;
                    endcase
                end

                // ---- FPGA_INFO: write "RGBL0001" (4 words) ----
                S_INFO_W0: begin
                    fsm_waddr <= SECDATA_WORD[ADDR_BITS-1:0] + 'd0;
                    fsm_wdata <= 16'h4752;    // 'R' 'G'
                    fsm_we    <= 1'b1;
                    mbx_state <= S_INFO_W1;
                end
                S_INFO_W1: begin
                    fsm_waddr <= SECDATA_WORD[ADDR_BITS-1:0] + 'd1;
                    fsm_wdata <= 16'h4C42;    // 'B' 'L'
                    fsm_we    <= 1'b1;
                    mbx_state <= S_INFO_W2;
                end
                S_INFO_W2: begin
                    fsm_waddr <= SECDATA_WORD[ADDR_BITS-1:0] + 'd2;
                    fsm_wdata <= 16'h3030;    // '0' '0'
                    fsm_we    <= 1'b1;
                    mbx_state <= S_INFO_W3;
                end
                S_INFO_W3: begin
                    fsm_waddr <= SECDATA_WORD[ADDR_BITS-1:0] + 'd3;
                    fsm_wdata <= 16'h3130;    // '0' '1'
                    fsm_we    <= 1'b1;
                    mbx_state <= S_DONE_WAIT;
                end

                // ---- READ_SECTOR: sd_reader is doing the streaming work
                //      this cycle. We just wait for its `done` pulse. The
                //      BRAM-write mux below catches each sd_wr_en and lands
                //      the word at SECDATA_WORD + sd_wr_idx. ----
                S_READ_WAIT: begin
                    if (sd_done) mbx_state <= S_DONE_WAIT;
                end

                S_DONE_WAIT: begin
                    status_reg <= STATUS_DONE;
                    if (command_reg == CMD_NOOP) mbx_state <= S_IDLE;
                end

                S_ERROR_WAIT: begin
                    status_reg <= STATUS_ERROR;
                    if (command_reg == CMD_NOOP) mbx_state <= S_IDLE;
                end

                default: mbx_state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // BRAM write port — three writers, priority host > FSM > sd_reader.
    // - Host: PCMCIA bus writes to everything except mailbox flops.
    // - FSM: synchronous FPGA_INFO bytes into sector_data.
    // - sd_reader: streams READ_SECTOR contents into sector_data.
    //
    // In practice the protocol keeps the host in poll-read mode while
    // sd_reader is BUSY, so host and sd_reader don't collide. FSM writes
    // (FPGA_INFO) and sd_reader writes never both happen — they're
    // mutually exclusive command paths.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (host_write_strobe && !mbx_flop_hit) begin
            if (!ce1_n_s) mem[word_addr][7:0]  <= fp_d[7:0];
            if (!ce2_n_s) mem[word_addr][15:8] <= fp_d[15:8];
        end else if (fsm_we) begin
            mem[fsm_waddr] <= fsm_wdata;
        end else if (sd_wr_en) begin
            mem[SECDATA_WORD[ADDR_BITS-1:0] + sd_wr_idx[ADDR_BITS-1:0]] <= sd_wr_data;
        end
    end

    // ------------------------------------------------------------------
    // Read path — mailbox flop words combinational; everything else
    // synchronous from BRAM.
    // ------------------------------------------------------------------
    wire [15:0] mbx_read =
        mbx_w0 ? {status_reg, command_reg}                  :
        mbx_w1 ? seq_reg                                    :
        mbx_w2 ? lba_reg[15:0]                              :
        mbx_w3 ? lba_reg[31:16]                             :
        mbx_w4 ? sector_count_reg                           :
                 16'hFFFF;

    wire [15:0] read_data = mbx_flop_hit ? mbx_read : mem_read_data;

    assign fp_d = reading ? read_data : 16'bz;

endmodule

`default_nettype wire
