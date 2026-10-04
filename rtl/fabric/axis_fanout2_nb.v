// ============================================================================
// Lightning Receiver - Non-blocking 2-way AXIS fan-out
// File: axis_fanout2_nb.v
// ----------------------------------------------------------------------------
// Splits one low-rate stream (48 kHz PCM) into two independent consumers,
// e.g. m0 = DDR recorder, m1 = network packetizer.  The input is never
// backpressured (s_tready = 1), so one stalled or disconnected consumer can
// never stop the other or the upstream DSP chain.
//
// Each branch has a one-word output register.  On every input word, an
// enabled branch either loads it (register empty or being drained this
// cycle) or drops it and counts the drop.  A disabled branch discards input
// silently (not counted as an error).  mute replaces TDATA with zeros while
// keeping the sample timing, so recorded audio stays time-continuous.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module axis_fanout2_nb (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s:m0:m1, FREQ_HZ 225014957, PHASE 0.0" *)
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   en0,
    input  wire                   en1,
    input  wire                   mute,
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire                   s_tvalid,
    output wire                   s_tready,
    input  wire                   s_tlast,
    output reg  [`LR_TDATA_W-1:0] m0_tdata,
    output reg  [`LR_TUSER_W-1:0] m0_tuser,
    output reg                    m0_tvalid,
    input  wire                   m0_tready,
    output reg                    m0_tlast,
    output reg  [`LR_TDATA_W-1:0] m1_tdata,
    output reg  [`LR_TUSER_W-1:0] m1_tuser,
    output reg                    m1_tvalid,
    input  wire                   m1_tready,
    output reg                    m1_tlast,
    output reg  [15:0]            drop0_count,
    output reg  [15:0]            drop1_count,
    output reg                    drop0_pulse,
    output reg                    drop1_pulse
);

    assign s_tready = 1'b1;

    wire [`LR_TDATA_W-1:0] data_in = mute ? {`LR_TDATA_W{1'b0}} : s_tdata;
    wire free0 = !m0_tvalid || m0_tready;
    wire free1 = !m1_tvalid || m1_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m0_tdata <= {`LR_TDATA_W{1'b0}};
            m0_tuser <= {`LR_TUSER_W{1'b0}};
            m0_tvalid <= 1'b0;
            m0_tlast <= 1'b0;
            m1_tdata <= {`LR_TDATA_W{1'b0}};
            m1_tuser <= {`LR_TUSER_W{1'b0}};
            m1_tvalid <= 1'b0;
            m1_tlast <= 1'b0;
            drop0_count <= 16'd0;
            drop1_count <= 16'd0;
            drop0_pulse <= 1'b0;
            drop1_pulse <= 1'b0;
        end else begin
            drop0_pulse <= 1'b0;
            drop1_pulse <= 1'b0;

            if (m0_tvalid && m0_tready) m0_tvalid <= 1'b0;
            if (m1_tvalid && m1_tready) m1_tvalid <= 1'b0;

            if (s_tvalid && en0) begin
                if (free0) begin
                    m0_tdata <= data_in;
                    m0_tuser <= s_tuser;
                    m0_tlast <= s_tlast;
                    m0_tvalid <= 1'b1;
                end else begin
                    drop0_pulse <= 1'b1;
                    if (drop0_count != 16'hFFFF)
                        drop0_count <= drop0_count + 1'b1;
                end
            end

            if (s_tvalid && en1) begin
                if (free1) begin
                    m1_tdata <= data_in;
                    m1_tuser <= s_tuser;
                    m1_tlast <= s_tlast;
                    m1_tvalid <= 1'b1;
                end else begin
                    drop1_pulse <= 1'b1;
                    if (drop1_count != 16'hFFFF)
                        drop1_count <= drop1_count + 1'b1;
                end
            end
        end
    end

endmodule
