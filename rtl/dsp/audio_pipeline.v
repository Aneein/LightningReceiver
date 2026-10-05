// ============================================================================
// Lightning Receiver - Audio Pipeline (de-emphasis + anti-alias FIR + 4:1)
// File: audio_pipeline.v
// ----------------------------------------------------------------------------
// FM discriminator output (192 ksample/s, s_tdata[31:16]) ->
//   1) de-emphasis, 1st-order IIR  y = x + a*(y[n-1] - x),  a = e^(-1/(fs*tau))
//        tau = 50 us (deemph_75us = 0, China/Europe) or 75 us (Americas/Korea)
//   2) 191-tap low-pass FIR (lr_audio_fir_rom: pass 15 kHz, stop >= 19 kHz,
//      removes the stereo pilot and everything that would alias at 48 kHz),
//      evaluated only for every 4th input sample (polyphase 4:1 decimation)
//   3) gain (Q0.15, 0x7FFF ~ unity) and saturation -> 48 kHz PCM (flow 3)
//
// The former single-pole "LPF" (y += (x-y)>>4) had its corner at ~1.9 kHz and
// no real stop band, so audio was muffled and 19-53 kHz content aliased.
// The FIR is a serial MAC (~200 clocks per 48 kHz output) - samples arrive
// only every ~1170 fabric clocks.
//
// iq_mode = 1 (narrowband IQ, AUDIO_CFG[19]; fm_demod passes {I,Q} through):
// de-emphasis is skipped and the same FIR/4:1 decimation runs on I and Q in
// parallel (a second MAC), giving 48 ksample/s complex baseband
// m_tdata = {I, Q} (+/-15 kHz pass band) for demodulation on the host.
// In FM mode m_tdata[15:0] stays 0 exactly as before.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module audio_pipeline (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [15:0]       gain,          // audio gain (Q0.15)
    input  wire              deemph_75us,   // 0: 50 us, 1: 75 us
    input  wire              iq_mode,       // 1: complex {I,Q} in/out, no de-emphasis
    // stream in (FM baseband in i_data, or {I,Q} in IQ mode)
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    // stream out (48 kHz PCM, mono in i_data)
    output reg  [`LR_TDATA_W-1:0] m_tdata,
    output reg  [`LR_TUSER_W-1:0] m_tuser,
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast
);

    localparam integer TAPS = 191;
    // a = e^(-1/(192e3*tau)) in Q15
    localparam signed [16:0] DEEM_A_50 = 17'sd29526;   // 0.90108
    localparam signed [16:0] DEEM_A_75 = 17'sd30569;   // 0.93291

    localparam [2:0] ST_IDLE = 3'd0, ST_DEEM = 3'd1, ST_UPD = 3'd2,
                     ST_FIR = 3'd3, ST_GAIN = 3'd4, ST_OUT = 3'd5;
    reg [2:0] state;

    assign s_tready = (state == ST_IDLE) && (!m_tvalid || m_tready);

    // ---------------- de-emphasis (Q.8 state) ----------------
    reg signed [31:0] y_f;            // de-emphasis output, 8 fractional bits
    reg signed [15:0] x_q;
    reg signed [15:0] xq_q;           // Q input (IQ mode)
    reg               iq_s;           // mode of the sample being processed
    reg               iq_grp;         // mode of the current output group
    reg signed [32:0] err_q;
    reg signed [49:0] deem_prod;
    wire signed [16:0] deem_a = deemph_75us ? DEEM_A_75 : DEEM_A_50;
    wire signed [31:0] y_new = ($signed(x_q) <<< 8) + (deem_prod >>> 15);
    wire signed [23:0] y_round = (y_new + 32'sd128) >>> 8;
    wire signed [15:0] y16 = (y_round > 24'sd32767)  ? 16'sh7FFF :
                             (y_round < -24'sd32768) ? 16'sh8000 : y_round[15:0];

    // ---------------- sample history (circular, 256 x 16, I and Q) --------
    reg [15:0] hist  [0:255];         // FM audio / I
    reg [15:0] histq [0:255];         // Q (IQ mode)
    reg [7:0]  wp;                    // next write position
    reg [15:0] hist_q, histq_q;       // registered reads
    reg [7:0]  rd_addr;
    always @(posedge clk) begin
        if (state == ST_UPD) begin
            hist[wp]  <= iq_s ? x_q : y16;
            histq[wp] <= iq_s ? xq_q : 16'd0;
        end
        hist_q  <= hist[rd_addr];
        histq_q <= histq[rd_addr];
    end

    // ---------------- FIR serial MAC ----------------
    reg [7:0]  tap;                   // tap whose operands are being fetched
    reg [7:0]  coef_addr;
    wire signed [17:0] coef_q;
    lr_audio_fir_rom u_coef (.clk(clk), .ce(1'b1), .addr(coef_addr), .dout(coef_q));
    // pipeline valids: address presented -> operands registered -> product
    reg        addr_v, op_v, prod_v;
    reg signed [33:0] prod, prodq;
    reg signed [43:0] acc, accq;
    reg [1:0]  phase;                 // input sample index within the 4:1 group
    reg [`LR_TUSER_W-1:0] user_q;
    reg        last_acc;
    reg signed [16:0] gain_s;
    reg signed [33:0] pcm_q, pcmq_q;

    function [15:0] sat16;
        input signed [50:0] v;
        begin
            if (v > 51'sd32767)       sat16 = 16'h7FFF;
            else if (v < -51'sd32768) sat16 = 16'h8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            y_f <= 32'sd0; x_q <= 16'sd0; err_q <= 33'sd0; deem_prod <= 50'sd0;
            xq_q <= 16'sd0; iq_s <= 1'b0; iq_grp <= 1'b0;
            wp <= 8'd0; rd_addr <= 8'd0; coef_addr <= 8'd0; tap <= 8'd0;
            addr_v <= 1'b0; op_v <= 1'b0; prod_v <= 1'b0;
            prod <= 34'sd0; acc <= 44'sd0; prodq <= 34'sd0; accq <= 44'sd0;
            phase <= 2'd0; user_q <= {`LR_TUSER_W{1'b0}}; last_acc <= 1'b0;
            gain_s <= 17'sd0; pcm_q <= 34'sd0; pcmq_q <= 34'sd0;
            m_tdata <= {`LR_TDATA_W{1'b0}};
            m_tuser <= {`LR_TUSER_W{1'b0}};
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
        end else begin
            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    if (s_tvalid && s_tready) begin
                        x_q <= s_tdata[31:16];
                        xq_q <= s_tdata[15:0];
                        iq_s <= iq_mode;
                        err_q <= y_f - ($signed(s_tdata[31:16]) <<< 8);
                        user_q <= s_tuser;
                        last_acc <= last_acc | s_tlast;
                        state <= ST_DEEM;
                    end
                end

                ST_DEEM: begin
                    deem_prod <= deem_a * err_q;
                    state <= ST_UPD;
                end

                ST_UPD: begin
                    // y16 is written to hist[wp] by the RAM process this cycle.
                    y_f <= y_new;
                    wp <= wp + 1'b1;
                    if (phase == 2'd3) begin
                        phase <= 2'd0;
                        iq_grp <= iq_s;
                        // newest sample (just written at wp) first
                        rd_addr <= wp;
                        coef_addr <= 8'd0;
                        tap <= 8'd0;
                        addr_v <= 1'b1;
                        op_v <= 1'b0;
                        prod_v <= 1'b0;
                        acc <= 44'sd0;
                        accq <= 44'sd0;
                        state <= ST_FIR;
                    end else begin
                        phase <= phase + 1'b1;
                        state <= ST_IDLE;
                    end
                end

                ST_FIR: begin
                    // addr_v : rd_addr/coef_addr hold tap 'tap' this cycle
                    // op_v   : hist_q/coef_q (registered reads) are valid
                    // prod_v : prod holds hist*coef for one tap
                    op_v <= addr_v;
                    prod_v <= op_v;
                    if (op_v) begin
                        prod  <= $signed(hist_q) * coef_q;
                        prodq <= $signed(histq_q) * coef_q;
                    end
                    if (prod_v) begin
                        acc  <= acc + prod;
                        accq <= accq + prodq;
                    end
                    if (addr_v) begin
                        if (tap == TAPS - 1) begin
                            addr_v <= 1'b0;
                        end else begin
                            tap <= tap + 1'b1;
                            rd_addr <= rd_addr - 1'b1;   // older samples
                            coef_addr <= coef_addr + 1'b1;
                        end
                    end
                    if (!addr_v && !op_v && !prod_v)
                        state <= ST_GAIN;
                end

                ST_GAIN: begin
                    // Q1.17 coefficients: round and drop 17 fractional bits.
                    pcm_q  <= (acc + 44'sd65536) >>> 17;
                    pcmq_q <= (accq + 44'sd65536) >>> 17;
                    gain_s <= {1'b0, gain};
                    state <= ST_OUT;
                end

                ST_OUT: begin
                    if (!m_tvalid || m_tready) begin
                        m_tdata[31:16] <= sat16(($signed(pcm_q) * gain_s) >>> 15);
                        m_tdata[15:0]  <= iq_grp ? sat16(($signed(pcmq_q) * gain_s) >>> 15)
                                                 : 16'd0;
                        m_tuser  <= user_q;
                        m_tlast  <= last_acc;
                        m_tvalid <= 1'b1;
                        last_acc <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
