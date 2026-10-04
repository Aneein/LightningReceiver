// ============================================================================
// Lightning Receiver - DDR4 Ring Buffer (AXI4 writer)
// File: ring_buffer.v
// ----------------------------------------------------------------------------
// Captures LR streams into DDR4 through a 256-bit AXI4 writer in the MIG UI
// domain.  An internal asynchronous FIFO crosses fabric 225M -> MIG 333M;
// single-beat INCR writes wrap at the configurable ring size and expose
// occupancy / overflow status.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module ring_buffer #(
    parameter AXI_DW = 256
)(
    // ---- AXI4 master (MIG ui domain) ----
    input  wire                M_AXI_aclk,
    input  wire                M_AXI_aresetn,
    output wire [3:0]          M_AXI_awid,
    output wire [31:0]         M_AXI_awaddr,
    output wire [7:0]          M_AXI_awlen,
    output wire [2:0]          M_AXI_awsize,
    output wire [1:0]          M_AXI_awburst,
    output wire [0:0]          M_AXI_awlock,
    output wire [3:0]          M_AXI_awcache,
    output wire [2:0]          M_AXI_awprot,
    output wire [3:0]          M_AXI_awqos,
    output wire                M_AXI_awvalid,
    input  wire                M_AXI_awready,
    output wire [AXI_DW-1:0]   M_AXI_wdata,
    output wire [AXI_DW/8-1:0] M_AXI_wstrb,
    output wire                M_AXI_wlast,
    output wire                M_AXI_wvalid,
    input  wire                M_AXI_wready,
    input  wire [1:0]          M_AXI_bresp,
    input  wire                M_AXI_bvalid,
    output wire                M_AXI_bready,
    // read channels (dummy - complete AXI4 master for BD interface inference)
    output wire [3:0]          M_AXI_arid,
    output wire [31:0]         M_AXI_araddr,
    output wire [7:0]          M_AXI_arlen,
    output wire [2:0]          M_AXI_arsize,
    output wire [1:0]          M_AXI_arburst,
    output wire [0:0]          M_AXI_arlock,
    output wire [3:0]          M_AXI_arcache,
    output wire [2:0]          M_AXI_arprot,
    output wire [3:0]          M_AXI_arqos,
    output wire                M_AXI_arvalid,
    input  wire                M_AXI_arready,
    input  wire [AXI_DW-1:0]   M_AXI_rdata,
    input  wire [1:0]          M_AXI_rresp,
    input  wire                M_AXI_rvalid,
    output wire                M_AXI_rready,
    // ---- fabric-side stream input ----
    input  wire                s_clk,         // fabric 225 MHz
    input  wire                rst_n,
    input  wire                rec_enable,
    input  wire [31:0]         base_addr,     // byte address
    input  wire [25:0]         ring_size,     // 32B words
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire                s_tvalid,
    output wire                s_tready,
    input  wire                s_tlast,
    // status
    output wire [31:0]         wr_words,
    output reg  [31:0]         overflow_cnt,
    output wire                axi_write_error,
    output wire                ring_full,
    output wire [25:0]         rd_ptr
);

    // ------------------------------------------------------------------------
    // Async FIFO (fabric domain): 32-bit samples, depth 4096
    // ------------------------------------------------------------------------
    localparam FIFO_DEPTH = 4096;
    wire        wr_full;
    wire        rd_empty;
    wire [31:0] fifo_dout;
    wire        fifo_wr = rec_enable && s_tvalid && s_tready;
    wire        rd_do;

    // Use the common, synthesis-safe dual-clock FIFO.  The former inlined
    // memory mixed custom pointer logic with two reads of fifo_mem in one
    // process; Vivado could neither map that pattern to BRAM nor legally
    // dissolve its 131072 bits.  lr_async_fifo uses a single synchronous
    // show-ahead read port and a single write port, matching UltraScale BRAM.
    lr_async_fifo #(.DATA_W(32), .DEPTH(FIFO_DEPTH)) u_sample_fifo (
        .wr_clk   (s_clk),
        .wr_rst_n (rst_n),
        .wr_en    (fifo_wr),
        .din      (s_tdata),
        .full     (wr_full),
        .rd_clk   (M_AXI_aclk),
        .rd_rst_n (M_AXI_aresetn),
        .rd_en    (rd_do),
        .dout     (fifo_dout),
        .empty    (rd_empty)
    );

    // write-side overflow accounting
    always @(posedge s_clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow_cnt <= 32'd0;
        end else if (rec_enable && s_tvalid && wr_full)
            overflow_cnt <= overflow_cnt + 1'b1;
    end

    // read side (MIG domain): pack 8 x 32-bit into 256-bit words
    reg [2:0]  pack_cnt;
    reg [AXI_DW-1:0] pack_reg;
    reg [AXI_DW-1:0] word_out;
    reg        word_avail;
    wire       word_taken;
    assign rd_do = !rd_empty && !word_avail;

    always @(posedge M_AXI_aclk or negedge M_AXI_aresetn) begin
        if (!M_AXI_aresetn) begin
            pack_cnt  <= 3'd0;
            pack_reg  <= {AXI_DW{1'b0}};
            word_out  <= {AXI_DW{1'b0}};
            word_avail <= 1'b0;
        end else begin
            if (rd_do) begin
                pack_reg[pack_cnt*32 +: 32] <= fifo_dout;
                pack_cnt  <= pack_cnt + 1'b1;
                if (pack_cnt == 3'd7) begin
                    pack_cnt   <= 3'd0;
                    word_avail <= 1'b1;
                    word_out   <= {fifo_dout, pack_reg[AXI_DW-33:0]};
                end
            end else if (word_avail && word_taken) begin
                word_avail <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // AXI4 write engine.  Each packed 256-bit word is issued as a legal
    // single-beat transaction.  The former code advertised a 16-beat burst
    // but cleared word_avail on the AW handshake, so WVALID could never assert.
    // ------------------------------------------------------------------------
    reg [25:0] ring_ptr;
    reg [1:0]  axi_state;
    reg [31:0] wr_words_axi;
    reg        axi_write_error_axi;
    (* ASYNC_REG = "TRUE" *) reg axi_error_s1, axi_error_s2;

    wire [31:0] wr_words_gray_axi = wr_words_axi ^ (wr_words_axi >> 1);
    wire [25:0] ring_ptr_gray_axi = ring_ptr ^ (ring_ptr >> 1);
    (* ASYNC_REG = "TRUE" *) reg [31:0] wr_words_gray_s1, wr_words_gray_s2;
    (* ASYNC_REG = "TRUE" *) reg [25:0] ring_ptr_gray_s1, ring_ptr_gray_s2;

    // Parallel-prefix Gray decoders.  The usual bit-by-bit loop builds a
    // 31-XOR dependency chain on the 225 MHz status path.  These networks
    // have only ceil(log2(width)) XOR levels.
    wire [31:0] wr_bin_s1 = wr_words_gray_s2 ^ (wr_words_gray_s2 >> 1);
    wire [31:0] wr_bin_s2 = wr_bin_s1 ^ (wr_bin_s1 >> 2);
    wire [31:0] wr_bin_s3 = wr_bin_s2 ^ (wr_bin_s2 >> 4);
    wire [31:0] wr_bin_s4 = wr_bin_s3 ^ (wr_bin_s3 >> 8);
    wire [31:0] wr_bin_s5 = wr_bin_s4 ^ (wr_bin_s4 >> 16);

    wire [25:0] rp_bin_s1 = ring_ptr_gray_s2 ^ (ring_ptr_gray_s2 >> 1);
    wire [25:0] rp_bin_s2 = rp_bin_s1 ^ (rp_bin_s1 >> 2);
    wire [25:0] rp_bin_s3 = rp_bin_s2 ^ (rp_bin_s2 >> 4);
    wire [25:0] rp_bin_s4 = rp_bin_s3 ^ (rp_bin_s3 >> 8);
    wire [25:0] rp_bin_s5 = rp_bin_s4 ^ (rp_bin_s4 >> 16);

    localparam AS_IDLE = 2'd0, AS_AW = 2'd1, AS_W = 2'd2, AS_B = 2'd3;

    wire aw_wr_ok = M_AXI_awvalid && M_AXI_awready;
    assign word_taken = M_AXI_wvalid && M_AXI_wready;

    always @(posedge M_AXI_aclk or negedge M_AXI_aresetn) begin
        if (!M_AXI_aresetn) begin
            ring_ptr <= 26'd0;
            axi_state <= AS_IDLE;
            wr_words_axi <= 32'd0;
            axi_write_error_axi <= 1'b0;
        end else begin
            case (axi_state)
                AS_IDLE: begin
                    if (word_avail)
                        axi_state <= AS_AW;
                end
                AS_AW: begin
                    if (aw_wr_ok)
                        axi_state <= AS_W;
                end
                AS_W: begin
                    if (word_taken) begin
                        axi_state <= AS_B;
                        wr_words_axi <= wr_words_axi + 1'b1;
                        // ring_size==0 selects the full 2 GiB/2^26-word span;
                        // natural 26-bit overflow wraps at the end.
                        if ((ring_size != 26'd0) && (ring_ptr >= ring_size - 1'b1))
                            ring_ptr <= 26'd0;
                        else
                            ring_ptr <= ring_ptr + 1'b1;
                    end
                end
                AS_B: begin
                    if (M_AXI_bvalid) begin
                        if (M_AXI_bresp != 2'b00)
                            axi_write_error_axi <= 1'b1;
                        axi_state <= AS_IDLE;
                    end
                end
                default: axi_state <= AS_IDLE;
            endcase
        end
    end

    assign M_AXI_awid    = 4'd0;
    // Explicitly widen before scaling.  In Verilog, (ring_ptr << 5) retains
    // the 26-bit left-operand width and would otherwise wrap every 64 MiB.
    assign M_AXI_awaddr  = base_addr + {1'b0, ring_ptr, 5'b0};
    assign M_AXI_awlen   = 8'd0;
    assign M_AXI_awsize  = 3'b101;              // 32 bytes
    assign M_AXI_awburst = 2'b01;               // INCR
    assign M_AXI_awlock  = 1'b0;
    assign M_AXI_awcache = 4'b0011;
    assign M_AXI_awprot  = 3'b010;
    assign M_AXI_awqos   = 4'd0;
    assign M_AXI_awvalid = (axi_state == AS_AW);
    assign M_AXI_wdata   = word_out;
    assign M_AXI_wstrb   = {AXI_DW/8{1'b1}};
    assign M_AXI_wlast   = M_AXI_wvalid;
    assign M_AXI_wvalid  = (axi_state == AS_W) && word_avail;
    assign M_AXI_bready  = 1'b1;
    assign s_tready = rec_enable && !wr_full;
    assign ring_full = wr_full;

    // Coherent Gray-coded status crossings back to the 225 MHz fabric domain.
    always @(posedge s_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_words_gray_s1 <= 32'd0;
            wr_words_gray_s2 <= 32'd0;
            ring_ptr_gray_s1 <= 26'd0;
            ring_ptr_gray_s2 <= 26'd0;
            axi_error_s1 <= 1'b0;
            axi_error_s2 <= 1'b0;
        end else begin
            wr_words_gray_s1 <= wr_words_gray_axi;
            wr_words_gray_s2 <= wr_words_gray_s1;
            ring_ptr_gray_s1 <= ring_ptr_gray_axi;
            ring_ptr_gray_s2 <= ring_ptr_gray_s1;
            axi_error_s1 <= axi_write_error_axi;
            axi_error_s2 <= axi_error_s1;
        end
    end
    assign wr_words = wr_bin_s5;
    assign axi_write_error = axi_error_s2;

    // dummy read channel (never used)
    assign M_AXI_arid    = 4'd0;
    assign M_AXI_araddr  = 32'd0;
    assign M_AXI_arlen   = 8'd0;
    assign M_AXI_arsize  = 3'b000;
    assign M_AXI_arburst = 2'b00;
    assign M_AXI_arlock  = 1'b0;
    assign M_AXI_arcache = 4'b0011;
    assign M_AXI_arprot  = 3'b010;
    assign M_AXI_arqos   = 4'd0;
    assign M_AXI_arvalid = 1'b0;
    assign M_AXI_rready  = 1'b0;

    assign rd_ptr = rp_bin_s5;

endmodule
