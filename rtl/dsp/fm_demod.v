// ============================================================================
// Lightning Receiver - FM Demodulator (phase-difference discriminator)
// File: fm_demod.v
// ----------------------------------------------------------------------------
//   z[n] = x[n] * conj(x[n-1]),   y[n] = atan2(Im z, Re z)
// y is the true phase step per sample, linear over the full +/-pi range.
// At the 192 ksample/s channel rate a +/-75 kHz broadcast deviation is
// +/-2.45 rad.  The former cross-product discriminator returned sin(dphi),
// which folds back beyond pi/2 (48 kHz deviation) and distorted loud audio.
//
// atan2 uses an iterative CORDIC (vectoring mode, 18 iterations, one per
// clock).  Samples arrive about every 1170 fabric clocks, so the ~60-cycle
// latency costs no throughput and keeps every adder path short.
//
// Output: m_tdata[31:16] = dphi / pi * 32768 (saturated, +pi -> 32767),
//         m_tdata[15:0]  = 0.  Positive output = positive frequency offset.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module fm_demod (
    input  wire              clk,
    input  wire              rst_n,
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

    localparam ST_IDLE = 3'd0;
    localparam ST_SUM  = 3'd1;
    localparam ST_HALF = 3'd2;
    localparam ST_NORM = 3'd3;
    localparam ST_ROT  = 3'd4;
    localparam ST_OUT  = 3'd5;

    // Angle units: pi = 2^19 (21-bit signed holds +/-pi).
    localparam signed [20:0] ANG_PI = 21'sd524288;
    localparam integer ITER = 18;

    function [19:0] atan_tab;
        input [4:0] i;
        begin
            case (i)
                5'd0:  atan_tab = 20'd131072;
                5'd1:  atan_tab = 20'd77376;
                5'd2:  atan_tab = 20'd40884;
                5'd3:  atan_tab = 20'd20753;
                5'd4:  atan_tab = 20'd10417;
                5'd5:  atan_tab = 20'd5213;
                5'd6:  atan_tab = 20'd2607;
                5'd7:  atan_tab = 20'd1304;
                5'd8:  atan_tab = 20'd652;
                5'd9:  atan_tab = 20'd326;
                5'd10: atan_tab = 20'd163;
                5'd11: atan_tab = 20'd81;
                5'd12: atan_tab = 20'd41;
                5'd13: atan_tab = 20'd20;
                5'd14: atan_tab = 20'd10;
                5'd15: atan_tab = 20'd5;
                5'd16: atan_tab = 20'd3;
                default: atan_tab = 20'd1;
            endcase
        end
    endfunction

    reg [2:0] state;
    assign s_tready = (state == ST_IDLE) && (!m_tvalid || m_tready);

    wire signed [15:0] sample_i = s_tdata[31:16];
    wire signed [15:0] sample_q = s_tdata[15:0];

    reg signed [15:0] i_d1, q_d1;
    reg signed [31:0] p_ii, p_qq, p_qi, p_iq;
    reg signed [35:0] cx, cy;
    reg signed [20:0] cz;
    reg [4:0]  iter;
    reg [`LR_TUSER_W-1:0] meta_user;
    reg                   meta_last;

    // re = I*I' + Q*Q',  im = Q*I' - I*Q'
    wire signed [32:0] z_re = $signed(p_ii) + $signed(p_qq);
    wire signed [32:0] z_im = $signed(p_qi) - $signed(p_iq);

    wire signed [35:0] cx_sh = cx >>> iter;
    wire signed [35:0] cy_sh = cy >>> iter;
    wire signed [20:0] atan_i = $signed({1'b0, atan_tab(iter)});

    // Normalisation keeps both components below 2^31 so CORDIC growth
    // (x1.65, plus sqrt(2)) fits the 36-bit signed datapath.
    wire cx_small = (cx < 36'sh0_4000_0000);
    wire cy_small = (cy < 36'sh0_4000_0000) && (cy > -36'sh0_4000_0000);

    wire signed [20:0] z_out = cz >>> 4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            i_d1      <= 16'sd0;
            q_d1      <= 16'sd0;
            p_ii      <= 32'sd0;
            p_qq      <= 32'sd0;
            p_qi      <= 32'sd0;
            p_iq      <= 32'sd0;
            cx        <= 36'sd0;
            cy        <= 36'sd0;
            cz        <= 21'sd0;
            iter      <= 5'd0;
            meta_user <= {`LR_TUSER_W{1'b0}};
            meta_last <= 1'b0;
            m_tdata   <= {`LR_TDATA_W{1'b0}};
            m_tuser   <= {`LR_TUSER_W{1'b0}};
            m_tvalid  <= 1'b0;
            m_tlast   <= 1'b0;
        end else begin
            if (m_tvalid && m_tready)
                m_tvalid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (s_tvalid && s_tready) begin
                        p_ii      <= sample_i * i_d1;
                        p_qq      <= sample_q * q_d1;
                        p_qi      <= sample_q * i_d1;
                        p_iq      <= sample_i * q_d1;
                        i_d1      <= sample_i;
                        q_d1      <= sample_q;
                        meta_user <= s_tuser;
                        meta_last <= s_tlast;
                        state     <= ST_SUM;
                    end
                end

                ST_SUM: begin
                    cx    <= {{3{z_re[32]}}, z_re};
                    cy    <= {{3{z_im[32]}}, z_im};
                    state <= ST_HALF;
                end

                ST_HALF: begin
                    // Rotate into the right half-plane so CORDIC converges.
                    if (cx < 0) begin
                        cx <= -cx;
                        cy <= -cy;
                        cz <= (cy >= 0) ? ANG_PI : -ANG_PI;
                    end else begin
                        cz <= 21'sd0;
                    end
                    iter  <= 5'd0;
                    state <= ST_NORM;
                end

                ST_NORM: begin
                    if (cx == 0 && cy == 0) begin
                        cz    <= 21'sd0;         // no signal: report 0 Hz
                        state <= ST_OUT;
                    end else if (cx_small && cy_small) begin
                        cx <= cx <<< 1;
                        cy <= cy <<< 1;
                    end else begin
                        state <= ST_ROT;
                    end
                end

                ST_ROT: begin
                    if (cy >= 0) begin
                        cx <= cx + cy_sh;
                        cy <= cy - cx_sh;
                        cz <= cz + atan_i;
                    end else begin
                        cx <= cx - cy_sh;
                        cy <= cy + cx_sh;
                        cz <= cz - atan_i;
                    end
                    if (iter == ITER - 1)
                        state <= ST_OUT;
                    else
                        iter <= iter + 1'b1;
                end

                ST_OUT: begin
                    if (!m_tvalid || m_tready) begin
                        m_tdata[31:16] <= (z_out > 21'sd32767) ? 16'h7FFF :
                                          (z_out < -21'sd32768) ? 16'h8000 :
                                          z_out[15:0];
                        m_tdata[15:0]  <= 16'd0;
                        m_tuser        <= meta_user;
                        m_tlast        <= meta_last;
                        m_tvalid       <= 1'b1;
                        state          <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
