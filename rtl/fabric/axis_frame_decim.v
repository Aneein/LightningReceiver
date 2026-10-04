// ============================================================================
// Lightning Receiver - AXIS frame decimator (spectrum branch)
// File: axis_frame_decim.v
// ----------------------------------------------------------------------------
// Passes one FRAME-sample frame out of every N and discards the others, so
// the spectrum chain (window -> xFFT -> spectrum_engine) only has to keep up
// with a fraction of the 61.44 Msps stream.  spectrum_engine needs 4 clocks
// per bin (16384 clocks per 4096-point frame) while a frame arrives every
// ~15000 fabric clocks, so without decimation the dsp_router spectrum FIFO
// overflowed continuously (millions of drops/s, ERR_STATUS bit1).
//
//   N = factor   (factor < 2 selects the default 4; sampled at frame start)
//
// Discarded frames are consumed at full rate (s_tready = 1) so the router
// never sees backpressure.  Kept frames pass through combinationally; m_tlast
// marks the last sample of each FRAME-sample frame.  Downstream frame
// counters (window_mult, xFFT) stay aligned because only whole frames pass.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module axis_frame_decim #(
    parameter integer FRAME = 4096
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s:m, FREQ_HZ 225014957, PHASE 0.0" *)
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [7:0]             factor,
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire                   s_tvalid,
    output wire                   s_tready,
    input  wire                   s_tlast,
    output wire [`LR_TDATA_W-1:0] m_tdata,
    output wire [`LR_TUSER_W-1:0] m_tuser,
    output wire                   m_tvalid,
    input  wire                   m_tready,
    output wire                   m_tlast
);

    localparam integer CW = $clog2(FRAME);

    reg [CW-1:0] sample_cnt;
    reg [7:0]    frame_cnt;
    reg [7:0]    n_eff;

    wire keep = (frame_cnt == 8'd0);
    wire fire = s_tvalid && s_tready;

    assign m_tdata  = s_tdata;
    assign m_tuser  = s_tuser;
    assign m_tvalid = s_tvalid && keep;
    assign m_tlast  = (sample_cnt == FRAME - 1);
    assign s_tready = keep ? m_tready : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_cnt <= {CW{1'b0}};
            frame_cnt  <= 8'd0;
            n_eff      <= 8'd4;
        end else if (fire) begin
            if (sample_cnt == FRAME - 1) begin
                sample_cnt <= {CW{1'b0}};
                if (frame_cnt >= n_eff - 1'b1) begin
                    frame_cnt <= 8'd0;
                    // new factor takes effect at a decimation-cycle boundary
                    n_eff <= (factor < 8'd2) ? 8'd4 : factor;
                end else begin
                    frame_cnt <= frame_cnt + 1'b1;
                end
            end else begin
                sample_cnt <= sample_cnt + 1'b1;
            end
        end
    end

endmodule
