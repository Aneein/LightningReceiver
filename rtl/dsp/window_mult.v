// ============================================================================
// Lightning Receiver - Window Multiplier (FFT input)
// File: window_mult.v
// ----------------------------------------------------------------------------
// Multiplies the IQ stream by window coefficients (hanning ROM, Q0.15).
// win_sel=0 -> rect (passthrough); otherwise hanning.
// Coefficient ROM loaded from window_hanning.mem ($readmemh).
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module window_mult #(
    parameter WIN_LEN = 4096
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [1:0]        win_sel,
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

    reg [11:0] idx;
    reg [15:0] coef_rom [0:WIN_LEN-1];
    reg signed [15:0] i_d, q_d, coef_d;
    reg [`LR_TUSER_W-1:0] user_d;
    reg last_d, valid_d;
    wire signed [31:0] i_windowed = i_d * coef_d;
    wire signed [31:0] q_windowed = q_d * coef_d;
    wire pipe_ce = !m_tvalid || m_tready;

    assign s_tready = pipe_ce;

    initial begin
        $readmemh("window_hanning.mem", coef_rom);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 12'd0;
            i_d <= 16'sd0; q_d <= 16'sd0; coef_d <= 16'sd0;
            user_d <= {`LR_TUSER_W{1'b0}};
            last_d <= 1'b0; valid_d <= 1'b0;
            m_tdata <= {`LR_TDATA_W{1'b0}};
            m_tuser <= {`LR_TUSER_W{1'b0}};
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
        end else if (pipe_ce) begin
            // Output the registered sample/coefficient pair.
            m_tvalid <= valid_d;
            if (valid_d) begin
                m_tdata[31:16] <= i_windowed >>> 15;
                m_tdata[15:0]  <= q_windowed >>> 15;
                m_tuser <= user_d;
                m_tlast <= last_d;
            end

            // Capture the next sample and the coefficient at the same index.
            valid_d <= s_tvalid;
            if (s_tvalid) begin
                i_d <= s_tdata[31:16];
                q_d <= s_tdata[15:0];
                coef_d <= (win_sel == 2'd0) ? 16'sh7FFF : coef_rom[idx];
                user_d <= s_tuser;
                last_d <= (idx == WIN_LEN-1);
                if (idx == WIN_LEN-1)
                    idx <= 12'd0;
                else
                    idx <= idx + 1'b1;
            end
        end
    end

endmodule
