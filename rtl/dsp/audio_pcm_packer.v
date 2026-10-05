// ============================================================================
// Lightning Receiver - Audio PCM packer (48 kHz mono -> DDR audio ring)
// File: audio_pcm_packer.v
// ----------------------------------------------------------------------------
// Packs two consecutive 16-bit PCM samples (taken from i_data = s_tdata[31:16])
// into one 32-bit word: {sample[n+1], sample[n]}.  The DDR ring buffer stores
// words little-endian, so host memory reads back a plain int16 LE PCM stream.
//
// Recording sessions (enable = AUDIO_CFG.REC):
//   * enable rising  : a session starts; rec_start_words latches the session
//                      start in 32-byte ring words (same unit as the ring's
//                      wr_words), so the host can locate a session that was
//                      started from the front panel while no GUI was attached.
//   * enable falling : the session is closed gracefully - a pending odd sample
//                      is paired with silence and the stream is padded with
//                      zero words up to the next 32-byte ring word.  Every
//                      session therefore starts on a fresh ring word and never
//                      shares a word with the previous one.
//
// The input never backpressures the audio pipeline: while recording, a sample
// pair that cannot be handed to the ring is dropped and counted (drop_count).
// Padding words are never dropped; they wait for the ring.
//
// Narrowband IQ mode (iq_mode = AUDIO_CFG[19]) is latched when a session
// starts (rec_iq), so one session never mixes formats.  In IQ mode every
// input beat {I,Q} becomes one word {Q, I}: the host reads interleaved
// int16 LE I, Q, I, Q ... at 48 ksample/s complex.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module audio_pcm_packer (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s:m, FREQ_HZ 225014957, PHASE 0.0" *)
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   enable,
    input  wire                   iq_mode,
    // 48 kHz PCM stream (or {I,Q} in IQ mode)
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire                   s_tvalid,
    output wire                   s_tready,
    input  wire                   s_tlast,
    // packed words to ring_buffer
    output reg  [`LR_TDATA_W-1:0] m_tdata,
    output reg                    m_tvalid,
    input  wire                   m_tready,
    output reg                    m_tlast,
    // status
    output reg  [31:0]            drop_count,
    output reg                    drop_pulse,
    output reg                    word_pulse,
    output wire                   rec_active,
    output reg                    rec_iq,        // format of the current/last session
    output reg  [31:0]            rec_start_words
);

    localparam [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_FLUSH = 2'd2;

    reg [1:0]  state;
    reg        enable_q;
    reg        half_valid;
    reg [15:0] half_sample;
    reg [34:0] word_cnt;        // 32-bit words issued to the ring

    assign s_tready   = 1'b1;
    assign rec_active = (state != ST_IDLE);

    wire in_fire  = s_tvalid && (state == ST_RUN);
    wire out_busy = m_tvalid && !m_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            enable_q        <= 1'b0;
            half_valid      <= 1'b0;
            half_sample     <= 16'd0;
            word_cnt        <= 35'd0;
            m_tdata         <= {`LR_TDATA_W{1'b0}};
            m_tvalid        <= 1'b0;
            m_tlast         <= 1'b0;
            drop_count      <= 32'd0;
            drop_pulse      <= 1'b0;
            word_pulse      <= 1'b0;
            rec_start_words <= 32'd0;
            rec_iq          <= 1'b0;
        end else begin
            enable_q   <= enable;
            word_pulse <= 1'b0;
            drop_pulse <= 1'b0;

            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast  <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    if (enable_q) begin
                        // word_cnt is a multiple of 8 here (previous flush).
                        rec_start_words <= word_cnt[34:3];
                        rec_iq <= iq_mode;
                        half_valid <= 1'b0;
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (!enable_q) begin
                        state <= ST_FLUSH;
                    end else if (in_fire && rec_iq) begin
                        if (out_busy) begin
                            drop_pulse <= 1'b1;
                            if (drop_count != 32'hFFFF_FFFF)
                                drop_count <= drop_count + 1'b1;
                        end else begin
                            m_tdata    <= {s_tdata[15:0], s_tdata[31:16]};
                            m_tlast    <= s_tlast;
                            m_tvalid   <= 1'b1;
                            word_pulse <= 1'b1;
                            word_cnt   <= word_cnt + 1'b1;
                        end
                    end else if (in_fire) begin
                        if (!half_valid) begin
                            half_sample <= s_tdata[31:16];
                            half_valid  <= 1'b1;
                        end else begin
                            half_valid <= 1'b0;
                            if (out_busy) begin
                                drop_pulse <= 1'b1;
                                if (drop_count != 32'hFFFF_FFFF)
                                    drop_count <= drop_count + 1'b1;
                            end else begin
                                m_tdata    <= {s_tdata[31:16], half_sample};
                                m_tlast    <= s_tlast;
                                m_tvalid   <= 1'b1;
                                word_pulse <= 1'b1;
                                word_cnt   <= word_cnt + 1'b1;
                            end
                        end
                    end
                end

                ST_FLUSH: begin
                    if (!out_busy) begin
                        if (half_valid) begin
                            // Close the odd sample with silence.
                            m_tdata    <= {16'd0, half_sample};
                            m_tlast    <= 1'b0;
                            m_tvalid   <= 1'b1;
                            word_pulse <= 1'b1;
                            word_cnt   <= word_cnt + 1'b1;
                            half_valid <= 1'b0;
                        end else if (word_cnt[2:0] != 3'd0) begin
                            // Pad to the 32-byte ring word boundary.
                            m_tdata    <= {`LR_TDATA_W{1'b0}};
                            m_tlast    <= (word_cnt[2:0] == 3'd7);
                            m_tvalid   <= 1'b1;
                            word_pulse <= 1'b1;
                            word_cnt   <= word_cnt + 1'b1;
                        end else begin
                            // Last word is accepted this cycle (or already).
                            state <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
