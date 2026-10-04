// ============================================================================
// Lightning Receiver - Complex 3-stage CIC decimator
// File: complex_cic_decimator.v
// ----------------------------------------------------------------------------
// Filters packed 16-bit I/Q as two independent channels.  A scalar CIC/FIR
// must not be connected to a packed {I,Q} word: doing so mixes the two fields
// arithmetically.  The comb section is spread over three clocks at each output
// sample, which is negligible at DECIM=320 and keeps 48-bit paths short.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module complex_cic_decimator #(
    parameter integer DECIM = 320,
    parameter integer GAIN_SHIFT = 25
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [15:0]             decim_rate,
    input  wire [`LR_TDATA_W-1:0]  s_tdata,
    input  wire [`LR_TUSER_W-1:0]  s_tuser,
    input  wire                    s_tvalid,
    output wire                    s_tready,
    input  wire                    s_tlast,
    output reg  [`LR_TDATA_W-1:0]  m_tdata,
    output reg  [`LR_TUSER_W-1:0]  m_tuser,
    output reg                     m_tvalid,
    input  wire                    m_tready,
    output reg                     m_tlast
);

    localparam ACC_W = 48;
    localparam ST_RUN = 2'd0, ST_COMB2 = 2'd1, ST_COMB3 = 2'd2;

    wire signed [15:0] in_i = s_tdata[31:16];
    wire signed [15:0] in_q = s_tdata[15:0];

    reg signed [ACC_W-1:0] int1_i, int2_i, int3_i;
    reg signed [ACC_W-1:0] int1_q, int2_q, int3_q;
    reg signed [ACC_W-1:0] delay1_i, delay2_i, delay3_i;
    reg signed [ACC_W-1:0] delay1_q, delay2_q, delay3_q;
    reg signed [ACC_W-1:0] comb1_i, comb2_i;
    reg signed [ACC_W-1:0] comb1_q, comb2_q;
    reg [15:0] dec_count;
    reg [1:0] state;
    reg block_last;
    reg [`LR_TUSER_W-1:0] meta_user;
    reg meta_last;

    wire signed [ACC_W-1:0] int3_i_next = int3_i + int2_i;
    wire signed [ACC_W-1:0] int3_q_next = int3_q + int2_q;

    function [15:0] sat16;
        input signed [ACC_W-1:0] value;
        begin
            if (value > 32767)
                sat16 = 16'h7FFF;
            else if (value < -32768)
                sat16 = 16'h8000;
            else
                sat16 = value[15:0];
        end
    endfunction

    assign s_tready = (state == ST_RUN) && (!m_tvalid || m_tready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int1_i <= 0; int2_i <= 0; int3_i <= 0;
            int1_q <= 0; int2_q <= 0; int3_q <= 0;
            delay1_i <= 0; delay2_i <= 0; delay3_i <= 0;
            delay1_q <= 0; delay2_q <= 0; delay3_q <= 0;
            comb1_i <= 0; comb2_i <= 0;
            comb1_q <= 0; comb2_q <= 0;
            dec_count <= 16'd0;
            state <= ST_RUN;
            block_last <= 1'b0;
            meta_user <= {`LR_TUSER_W{1'b0}};
            meta_last <= 1'b0;
            m_tdata <= {`LR_TDATA_W{1'b0}};
            m_tuser <= {`LR_TUSER_W{1'b0}};
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
        end else begin
            if (m_tvalid && m_tready)
                m_tvalid <= 1'b0;

            case (state)
                ST_RUN: begin
                    if (s_tvalid && s_tready) begin
                        int1_i <= int1_i + in_i;
                        int2_i <= int2_i + int1_i;
                        int3_i <= int3_i_next;
                        int1_q <= int1_q + in_q;
                        int2_q <= int2_q + int1_q;
                        int3_q <= int3_q_next;

                        if ((decim_rate <= 16'd1) ||
                            (dec_count == decim_rate - 1'b1)) begin
                            dec_count <= 16'd0;
                            comb1_i <= int3_i_next - delay1_i;
                            comb1_q <= int3_q_next - delay1_q;
                            delay1_i <= int3_i_next;
                            delay1_q <= int3_q_next;
                            meta_user <= s_tuser;
                            meta_last <= block_last | s_tlast;
                            block_last <= 1'b0;
                            state <= ST_COMB2;
                        end else begin
                            dec_count <= dec_count + 1'b1;
                            block_last <= block_last | s_tlast;
                        end
                    end
                end

                ST_COMB2: begin
                    comb2_i <= comb1_i - delay2_i;
                    comb2_q <= comb1_q - delay2_q;
                    delay2_i <= comb1_i;
                    delay2_q <= comb1_q;
                    state <= ST_COMB3;
                end

                ST_COMB3: begin
                    m_tdata[31:16] <= sat16(
                        ($signed(comb2_i) - $signed(delay3_i)) >>> GAIN_SHIFT);
                    m_tdata[15:0] <= sat16(
                        ($signed(comb2_q) - $signed(delay3_q)) >>> GAIN_SHIFT);
                    delay3_i <= comb2_i;
                    delay3_q <= comb2_q;
                    m_tuser <= meta_user;
                    m_tlast <= meta_last;
                    m_tvalid <= 1'b1;
                    state <= ST_RUN;
                end

                default: state <= ST_RUN;
            endcase
        end
    end

endmodule
