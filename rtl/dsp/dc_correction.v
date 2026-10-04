// ============================================================================
// Lightning Receiver - DC Correction
// File: dc_correction.v
// ----------------------------------------------------------------------------
// First-order IIR DC estimate removed from I/Q; bypass option. AXIS passthrough.
//
//   acc += x - (acc >>> ALPHA_SHIFT)      (acc = DC estimate * 2^ALPHA_SHIFT)
//   y    = x - round(acc / 2^ALPHA_SHIFT)
//
// The estimate keeps ALPHA_SHIFT fractional bits.  The former integer form
// dc += (x - dc) >>> ALPHA_SHIFT could only move dc downwards for |x - dc| <
// 2^ALPHA_SHIFT (the arithmetic shift floors every small negative error to
// -1 and every small positive error to 0), so with 12-bit AD9361 data the
// "DC estimate" ran away to about -3000 and *injected* a near full-scale DC
// term at the LO (seen on hardware 2026-10-05).  Time constant: 2^ALPHA_SHIFT
// samples (4096 @ 61.44 Msps = 67 us, corner ~2.4 kHz).
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module dc_correction #(
    parameter ALPHA_SHIFT = 12
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              bypass,
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    output reg  [`LR_TDATA_W-1:0] m_tdata,
    output reg  [`LR_TUSER_W-1:0] m_tuser,
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast
);

    localparam ACC_W = 17 + ALPHA_SHIFT;    // |acc| <= 32768 * 2^ALPHA

    // One-entry elastic output register.  Hold payload/valid while stalled.
    assign s_tready = !m_tvalid || m_tready;

    reg signed [ACC_W-1:0] acc_i, acc_q;

    wire signed [15:0] s_i = s_tdata[31:16];
    wire signed [15:0] s_q = s_tdata[15:0];

    // Rounded DC estimate (add half an LSB before the arithmetic shift).
    wire signed [ACC_W-1:0] half = {{(ACC_W-ALPHA_SHIFT){1'b0}}, 1'b1, {(ALPHA_SHIFT-1){1'b0}}};
    wire signed [16:0] dc_i = (acc_i + half) >>> ALPHA_SHIFT;
    wire signed [16:0] dc_q = (acc_q + half) >>> ALPHA_SHIFT;
    wire signed [17:0] y_i = $signed(s_i) - dc_i;
    wire signed [17:0] y_q = $signed(s_q) - dc_q;

    function [15:0] sat16;
        input signed [17:0] v;
        begin
            if (v > 18'sd32767)       sat16 = 16'h7FFF;
            else if (v < -18'sd32768) sat16 = 16'h8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_i <= {ACC_W{1'b0}};
            acc_q <= {ACC_W{1'b0}};
            m_tdata <= {`LR_TDATA_W{1'b0}};
            m_tuser <= {`LR_TUSER_W{1'b0}};
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
        end else if (s_tready) begin
            if (s_tvalid) begin
                acc_i <= acc_i + $signed(s_i) - (acc_i >>> ALPHA_SHIFT);
                acc_q <= acc_q + $signed(s_q) - (acc_q >>> ALPHA_SHIFT);
                if (bypass) begin
                    m_tdata <= s_tdata;
                end else begin
                    m_tdata[31:16] <= sat16(y_i);
                    m_tdata[15:0]  <= sat16(y_q);
                end
                m_tuser  <= s_tuser;
                m_tvalid <= 1'b1;
                m_tlast  <= s_tlast;
            end else begin
                m_tvalid <= 1'b0;
            end
        end
    end

endmodule
