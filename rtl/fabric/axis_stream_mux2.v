// ============================================================================
// Two-input LR AXI-stream selector.
// Input 0 is FM/audio and input 1 is raw IQ.  The unselected input is drained
// so a dormant network branch can never backpressure the shared fanout.
// Selection changes only while the packetizer is idle (enforced by the BD).
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module lr_axis_stream_mux2 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s0:s1:m, FREQ_HZ 225014957, PHASE 0.0" *)
    input  wire clk,
    input  wire rst_n,
    input  wire select_raw,
    input  wire audio_enable,
    input  wire raw_enable,
    input  wire [`LR_TDATA_W-1:0] s0_tdata,
    input  wire [`LR_TUSER_W-1:0] s0_tuser,
    input  wire s0_tvalid,
    output wire s0_tready,
    input  wire s0_tlast,
    input  wire [`LR_TDATA_W-1:0] s1_tdata,
    input  wire [`LR_TUSER_W-1:0] s1_tuser,
    input  wire s1_tvalid,
    output wire s1_tready,
    input  wire s1_tlast,
    output wire [`LR_TDATA_W-1:0] m_tdata,
    output wire [`LR_TUSER_W-1:0] m_tuser,
    output wire m_tvalid,
    input  wire m_tready,
    output wire m_tlast,
    output wire [1:0] flow_sel,
    output wire tx_enable
);
    // Register control in the fabric clock domain.  Apart from making the
    // AXIS clock association explicit to IP Integrator, this prevents an AXI
    // register write from changing the combinational selection mid-cycle.
    reg select_raw_q;
    reg audio_enable_q;
    reg raw_enable_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            select_raw_q   <= 1'b0;
            audio_enable_q <= 1'b0;
            raw_enable_q   <= 1'b0;
        end else begin
            select_raw_q   <= select_raw;
            audio_enable_q <= audio_enable;
            raw_enable_q   <= raw_enable;
        end
    end

    assign m_tdata  = select_raw_q ? s1_tdata  : s0_tdata;
    assign m_tuser  = select_raw_q ? s1_tuser  : s0_tuser;
    assign m_tvalid = select_raw_q ? s1_tvalid : s0_tvalid;
    assign m_tlast  = select_raw_q ? s1_tlast  : s0_tlast;
    assign s0_tready = select_raw_q ? 1'b1 : m_tready;
    assign s1_tready = select_raw_q ? m_tready : 1'b1;
    assign flow_sel = select_raw_q ? 2'd0 : 2'd3;
    assign tx_enable = select_raw_q ? raw_enable_q : audio_enable_q;
endmodule
