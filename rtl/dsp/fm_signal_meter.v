// ============================================================================
// Lightning Receiver - FM channel signal meter (pass-through AXIS tap)
// File: fm_signal_meter.v
// ----------------------------------------------------------------------------
// Sits between the CIC (192 ksample/s complex channel) and the FM
// demodulator.  The stream passes through combinationally; every accepted
// sample also feeds block statistics over N = 2^LOG2N samples:
//
//   power_mean = sum(p) / N,                 p = I^2 + Q^2
//   flat_q8    = 256 * N * sum(p^2) / sum(p)^2   (Q8.8, saturated)
//
// flat is the normalised second moment of the envelope power.  An FM station
// has a constant envelope (flat -> 1.0); complex Gaussian noise gives 2.0.
// With carrier-to-noise ratio s: flat = (s^2 + 4s + 2) / (s + 1)^2, so the
// default threshold 1.25 (0x140) corresponds to about 8 dB CNR.  The ratio is
// independent of gain/AGC and of the programme audio.
//
//   station_ok = flat_q8 <= thr_q8 && power_mean[31:16] >= min_power
//
// All wide arithmetic is bit-serial (one adder per clock); a block result
// takes ~200 clocks while samples arrive every ~1170 clocks.  Samples that
// arrive while a result is being computed are passed through but not counted.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module fm_signal_meter #(
    parameter integer LOG2N = 10
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s:m, FREQ_HZ 225014957, PHASE 0.0" *)
    input  wire              clk,
    input  wire              rst_n,
    // pass-through stream
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    output wire [`LR_TDATA_W-1:0] m_tdata,
    output wire [`LR_TUSER_W-1:0] m_tuser,
    output wire              m_tvalid,
    input  wire              m_tready,
    output wire              m_tlast,
    // control / config
    input  wire              restart,       // discard the current block
    input  wire [15:0]       thr_q8,
    input  wire [15:0]       min_power,
    // results (held until the next block completes)
    output reg  [31:0]       power_mean,
    output reg  [15:0]       flat_q8,
    output reg               station_ok,
    output reg               result_valid,  // 1-cycle pulse per block
    output reg  [7:0]        result_count
);

    assign m_tdata  = s_tdata;
    assign m_tuser  = s_tuser;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

    localparam integer SP_W  = 32 + LOG2N;          // sum(p)
    localparam integer SP2_W = 62 + LOG2N;          // sum(p^2), p^2 < 2^62
    localparam integer B_W   = 2 * SP_W;            // sum(p)^2
    localparam integer D_W   = SP2_W + LOG2N + 8;   // N*sum(p^2)*256
    localparam integer Q_W   = LOG2N + 9;           // flat_q8 <= N*256

    localparam [2:0] S_IDLE = 3'd0, S_SQ1 = 3'd1, S_SQ2 = 3'd2, S_P2 = 3'd3,
                     S_ACC = 3'd4, S_SQB = 3'd5, S_DIV = 3'd6, S_DONE = 3'd7;
    reg [2:0] state;

    reg signed [15:0] si, sq;
    reg [31:0] ii, qq;
    reg [31:0] p;
    reg [SP_W-1:0]  sum_p;
    reg [SP2_W-1:0] sum_p2;
    reg [LOG2N:0]   n_cnt;
    // serial multiplier (shared by p^2 and sum_p^2)
    reg [B_W-1:0] mul_a, mul_acc;
    reg [SP_W-1:0] mul_b;
    reg [7:0] cnt;
    // restoring divider
    reg [D_W-1:0]  div_n;
    reg [B_W:0]    div_r;
    reg [Q_W-1:0]  div_q;

    wire hs = s_tvalid && m_tready;
    wire [B_W:0] div_r_sh = {div_r[B_W-1:0], div_n[D_W-1]};
    wire div_ge = (div_r_sh >= {1'b0, mul_acc});
    wire [SP_W-1:0] mean_full = sum_p >> LOG2N;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            si <= 16'sd0; sq <= 16'sd0;
            ii <= 32'd0; qq <= 32'd0; p <= 32'd0;
            sum_p <= {SP_W{1'b0}};
            sum_p2 <= {SP2_W{1'b0}};
            n_cnt <= {(LOG2N+1){1'b0}};
            mul_a <= {B_W{1'b0}}; mul_acc <= {B_W{1'b0}};
            mul_b <= {SP_W{1'b0}}; cnt <= 8'd0;
            div_n <= {D_W{1'b0}}; div_r <= {(B_W+1){1'b0}};
            div_q <= {Q_W{1'b0}};
            power_mean <= 32'd0;
            flat_q8 <= 16'd0;
            station_ok <= 1'b0;
            result_valid <= 1'b0;
            result_count <= 8'd0;
        end else begin
            result_valid <= 1'b0;
            if (restart) begin
                sum_p <= {SP_W{1'b0}};
                sum_p2 <= {SP2_W{1'b0}};
                n_cnt <= {(LOG2N+1){1'b0}};
                state <= S_IDLE;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (hs) begin
                            si <= s_tdata[31:16];
                            sq <= s_tdata[15:0];
                            state <= S_SQ1;
                        end
                    end
                    S_SQ1: begin
                        ii <= si * si;
                        qq <= sq * sq;
                        state <= S_SQ2;
                    end
                    S_SQ2: begin
                        p <= ii + qq;
                        mul_a <= {{(B_W-32){1'b0}}, ii + qq};
                        mul_b <= {{(SP_W-32){1'b0}}, ii + qq};
                        mul_acc <= {B_W{1'b0}};
                        cnt <= 8'd32;
                        state <= S_P2;
                    end
                    S_P2: begin                       // p^2, 32 cycles
                        if (mul_b[0]) mul_acc <= mul_acc + mul_a;
                        mul_a <= mul_a << 1;
                        mul_b <= mul_b >> 1;
                        cnt <= cnt - 1'b1;
                        if (cnt == 8'd1) state <= S_ACC;
                    end
                    S_ACC: begin
                        sum_p  <= sum_p + p;
                        sum_p2 <= sum_p2 + mul_acc[SP2_W-1:0];
                        if (n_cnt == (1 << LOG2N) - 1) begin
                            mul_a <= {{(B_W-SP_W){1'b0}}, sum_p + p};
                            mul_b <= sum_p + p;
                            mul_acc <= {B_W{1'b0}};
                            cnt <= SP_W;
                            state <= S_SQB;
                        end else begin
                            n_cnt <= n_cnt + 1'b1;
                            state <= S_IDLE;
                        end
                    end
                    S_SQB: begin                      // sum(p)^2
                        if (mul_b[0]) mul_acc <= mul_acc + mul_a;
                        mul_a <= mul_a << 1;
                        mul_b <= mul_b >> 1;
                        cnt <= cnt - 1'b1;
                        if (cnt == 8'd1) begin
                            div_n <= {sum_p2, {(LOG2N + 8){1'b0}}};
                            div_r <= {(B_W+1){1'b0}};
                            div_q <= {Q_W{1'b0}};
                            cnt <= D_W;
                            state <= S_DIV;
                        end
                    end
                    S_DIV: begin                      // 256*N*sum(p^2)/sum(p)^2
                        div_n <= div_n << 1;
                        div_r <= div_ge ? (div_r_sh - {1'b0, mul_acc}) : div_r_sh;
                        div_q <= {div_q[Q_W-2:0], div_ge};
                        cnt <= cnt - 1'b1;
                        if (cnt == 8'd1) state <= S_DONE;
                    end
                    S_DONE: begin
                        power_mean <= mean_full[31:0];
                        if (mul_acc == {B_W{1'b0}}) begin
                            flat_q8 <= 16'hFFFF;      // no energy at all
                            station_ok <= 1'b0;
                        end else begin
                            flat_q8 <= (div_q > 16'hFFFF) ? 16'hFFFF : div_q[15:0];
                            station_ok <= (div_q <= thr_q8) &&
                                          (mean_full[31:16] >= min_power);
                        end
                        result_valid <= 1'b1;
                        result_count <= result_count + 1'b1;
                        sum_p <= {SP_W{1'b0}};
                        sum_p2 <= {SP2_W{1'b0}};
                        n_cnt <= {(LOG2N+1){1'b0}};
                        state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
