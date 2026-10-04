// ============================================================================
// Lightning Receiver - DSP Router (4-way fanout, explicit outputs)
// File: dsp_router.v
// ----------------------------------------------------------------------------
// Fans out stream 0 to FM, DDR, FFT, and raw-network consumers.
// Per-output enable; disabled outputs drop and count.
// (Explicit non-array ports so Vivado BD can import this as a module cell.)
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module dsp_router #(
    parameter FIFO_DEPTH = 256
) (
    input  wire              clk,
    input  wire              rst_n,
    // input stream
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    // output 0 (FM/audio path)
    output wire [`LR_TDATA_W-1:0] m0_tdata,
    output wire [`LR_TUSER_W-1:0] m0_tuser,
    output wire              m0_tvalid,
    input  wire              m0_tready,
    output wire              m0_tlast,
    // output 1 (DDR recorder)
    output wire [`LR_TDATA_W-1:0] m1_tdata,
    output wire [`LR_TUSER_W-1:0] m1_tuser,
    output wire              m1_tvalid,
    input  wire              m1_tready,
    output wire              m1_tlast,
    // output 2 (FFT path)
    output wire [`LR_TDATA_W-1:0] m2_tdata,
    output wire [`LR_TUSER_W-1:0] m2_tuser,
    output wire              m2_tvalid,
    input  wire              m2_tready,
    output wire              m2_tlast,
    // output 3 (raw network path)
    output wire [`LR_TDATA_W-1:0] m3_tdata,
    output wire [`LR_TUSER_W-1:0] m3_tuser,
    output wire              m3_tvalid,
    input  wire              m3_tready,
    output wire              m3_tlast,
    // enable mask [3:0] (bit0=out0 ...)
    input  wire [3:0]        en_mask,
    output reg  [31:0]       drop_count,
    output reg               drop_event
);

    localparam FIFO_W = `LR_TDATA_W + `LR_TUSER_W + 1;
    wire [FIFO_W-1:0] fifo_in = {s_tlast, s_tuser, s_tdata};
    wire [FIFO_W-1:0] fifo_out0, fifo_out1, fifo_out2, fifo_out3;
    wire [3:0] fifo_full, fifo_empty;
    wire [3:0] branch_ready = ~fifo_full;
    wire [3:0] fifo_wr = {4{s_tvalid && s_tready}} & en_mask & branch_ready;
    wire [3:0] fifo_rd = {m3_tready, m2_tready, m1_tready, m0_tready} &
                         ~fifo_empty;
    wire any_branch_drop = s_tvalid && s_tready &&
                           ((en_mask == 4'd0) ||
                            (|(en_mask & fifo_full)));

    // Never allow a slow branch to backpressure the shared source.  Each
    // enabled branch either queues the sample or reports a branch-local drop.
    assign s_tready = 1'b1;

    lr_async_fifo #(.DATA_W(FIFO_W), .DEPTH(FIFO_DEPTH)) u_fifo0 (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(fifo_wr[0]), .din(fifo_in),
        .full(fifo_full[0]), .rd_clk(clk), .rd_rst_n(rst_n),
        .rd_en(fifo_rd[0]), .dout(fifo_out0), .empty(fifo_empty[0]));
    lr_async_fifo #(.DATA_W(FIFO_W), .DEPTH(FIFO_DEPTH)) u_fifo1 (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(fifo_wr[1]), .din(fifo_in),
        .full(fifo_full[1]), .rd_clk(clk), .rd_rst_n(rst_n),
        .rd_en(fifo_rd[1]), .dout(fifo_out1), .empty(fifo_empty[1]));
    lr_async_fifo #(.DATA_W(FIFO_W), .DEPTH(FIFO_DEPTH)) u_fifo2 (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(fifo_wr[2]), .din(fifo_in),
        .full(fifo_full[2]), .rd_clk(clk), .rd_rst_n(rst_n),
        .rd_en(fifo_rd[2]), .dout(fifo_out2), .empty(fifo_empty[2]));
    lr_async_fifo #(.DATA_W(FIFO_W), .DEPTH(FIFO_DEPTH)) u_fifo3 (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(fifo_wr[3]), .din(fifo_in),
        .full(fifo_full[3]), .rd_clk(clk), .rd_rst_n(rst_n),
        .rd_en(fifo_rd[3]), .dout(fifo_out3), .empty(fifo_empty[3]));

    assign {m0_tlast, m0_tuser, m0_tdata} = fifo_out0;
    assign {m1_tlast, m1_tuser, m1_tdata} = fifo_out1;
    assign {m2_tlast, m2_tuser, m2_tdata} = fifo_out2;
    assign {m3_tlast, m3_tuser, m3_tdata} = fifo_out3;
    assign m0_tvalid = !fifo_empty[0];
    assign m1_tvalid = !fifo_empty[1];
    assign m2_tvalid = !fifo_empty[2];
    assign m3_tvalid = !fifo_empty[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drop_count <= 32'd0;
            drop_event <= 1'b0;
        end else begin
            drop_event <= any_branch_drop;
            if (any_branch_drop) begin
                if (drop_count != 32'hFFFF_FFFF)
                    drop_count <= drop_count + 1'b1;
            end
        end
    end

endmodule
