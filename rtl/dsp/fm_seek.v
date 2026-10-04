// ============================================================================
// Lightning Receiver - FM seek / tuning controller
// File: fm_seek.v
// ----------------------------------------------------------------------------
// Owns all *panel/host-command* changes of the DDC offset (reg_ddc_freq):
//
//   seek up/down : step the DDC offset on a grid of step_khz around the
//                  starting frequency, measure each point with
//                  fm_signal_meter, and stop on the first point that
//                    (a) passes the meter's station test (CNR), and
//                    (b) is a local power maximum on the grid
//                  (P[k-1] <= P[k] > P[k+1]), so the seek lands on the
//                  station centre, not on its adjacent-channel skirt.
//                  The band wraps at +/-range_khz; one full lap without a
//                  station returns to the start ("not found").
//   step up/down : one manual grid step, clamped to +/-range (limit event).
//   zero         : back to the LO centre (offset 0).
//
// The audio is muted while seeking (mute=1).  Any command during a seek
// cancels it and restores the starting frequency.  A host write to the DDC
// register during a seek (host_abort) stops immediately and keeps the host
// value: the GUI always wins.
//
// The starting point itself is measured first so a seek never stops on the
// skirt of the station it started from, and never selects the start point.
// If no meter result arrives within MEAS_TIMEOUT_CYC (no AD9361 samples,
// e.g. before the RF front end is initialised) the seek gives up, restores
// the start frequency and reports "not found" with status[5] (no signal).
// ============================================================================
`timescale 1ns/1ps

module fm_seek #(
    parameter integer SETTLE_CYC = 112_500,   // 0.5 ms @ 225 MHz
    parameter integer MAX_STEPS  = 4095,
    parameter integer MEAS_TIMEOUT_CYC = 5_625_000   // 25 ms @ 225 MHz
)(
    input  wire               clk,
    input  wire               rst_n,
    // configuration
    input  wire [15:0]        step_khz,
    input  wire [15:0]        range_khz,
    input  wire signed [31:0] cur_freq,       // current reg_ddc_freq
    // commands (1-cycle pulses)
    input  wire               cmd_seek_up,
    input  wire               cmd_seek_down,
    input  wire               cmd_cancel,
    input  wire               cmd_step_up,
    input  wire               cmd_step_down,
    input  wire               cmd_zero,
    // host SEEK_CTRL write: 1 seek up, 2 seek down, 3 cancel
    input  wire               host_cmd_valid,
    input  wire [1:0]         host_cmd,
    input  wire               host_abort,
    // signal meter
    input  wire               meter_valid,
    input  wire [31:0]        meter_power,
    input  wire               meter_ok,
    output reg                meter_restart,
    // DDC write request (to register_bank)
    output reg                freq_wr_valid,
    output reg  signed [31:0] freq_wr_data,
    // status
    output wire               busy,
    output wire               mute,
    output reg                evt_found,
    output reg                evt_notfound,
    output reg                evt_limit,
    output wire [7:0]         status          // [0]busy [1]dir_up [3:2]result [4]limit [5]no signal
);

    localparam [2:0] S_IDLE = 3'd0, S_SETTLE = 3'd1, S_MEAS = 3'd2,
                     S_DECIDE = 3'd3, S_NEXT = 3'd4, S_WRAP = 3'd5,
                     S_FINAL = 3'd6;
    localparam [1:0] R_NONE = 2'd0, R_FOUND = 2'd1, R_NOTFOUND = 2'd2,
                     R_CANCEL = 2'd3;

    reg [2:0] state;
    reg       dir_up;
    reg [1:0] result;
    reg       limit_flag;
    reg       nosig_flag;
    reg [22:0] meas_timer;

    // kHz -> Hz (x1000 = x1024 - x16 - x8), registered.
    reg signed [31:0] step_hz, range_hz;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_hz  <= 32'sd0;
            range_hz <= 32'sd0;
        end else begin
            step_hz  <= ({16'd0, step_khz} << 10) - ({16'd0, step_khz} << 4)
                      - ({16'd0, step_khz} << 3);
            range_hz <= ({16'd0, range_khz} << 10) - ({16'd0, range_khz} << 4)
                      - ({16'd0, range_khz} << 3);
        end
    end

    reg signed [31:0] start_f, f, f_prev, wf;
    reg [31:0] p_cur, p_prev, p_prev2;
    reg        ok_cur, ok_prev, prev_valid, prev2_valid, prev_is_start;
    reg        at_start;
    reg [12:0] steps;
    reg [17:0] timer;

    assign busy   = (state != S_IDLE);
    assign mute   = busy;
    assign status = {2'd0, nosig_flag, limit_flag, result, dir_up, busy};

    wire seek_up_req   = cmd_seek_up   || (host_cmd_valid && host_cmd == 2'd1);
    wire seek_down_req = cmd_seek_down || (host_cmd_valid && host_cmd == 2'd2);
    wire cancel_req    = cmd_cancel    || (host_cmd_valid && host_cmd == 2'd3);
    wire any_cmd = seek_up_req | seek_down_req | cancel_req |
                   cmd_step_up | cmd_step_down | cmd_zero;

    wire signed [32:0] up_next   = $signed({f[31], f}) + $signed({step_hz[31], step_hz});
    wire signed [32:0] down_next = $signed({f[31], f}) - $signed({step_hz[31], step_hz});
    wire signed [32:0] man_up    = $signed({cur_freq[31], cur_freq}) + $signed({step_hz[31], step_hz});
    wire signed [32:0] man_down  = $signed({cur_freq[31], cur_freq}) - $signed({step_hz[31], step_hz});
    wire signed [32:0] range_p   = $signed({range_hz[31], range_hz});
    wire signed [32:0] range_n   = -range_p;
    wire signed [32:0] wf_down   = $signed({wf[31], wf}) - $signed({step_hz[31], step_hz});
    wire signed [32:0] wf_up     = $signed({wf[31], wf}) + $signed({step_hz[31], step_hz});

    wire peak_at_prev = prev_valid && ok_prev && !prev_is_start &&
                        (p_prev > p_cur) &&
                        (!prev2_valid || (p_prev >= p_prev2));

    task go_to;
        input signed [31:0] target;
        begin
            freq_wr_valid <= 1'b1;
            freq_wr_data  <= target;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            dir_up <= 1'b0;
            result <= R_NONE;
            limit_flag <= 1'b0;
            nosig_flag <= 1'b0;
            meas_timer <= 23'd0;
            start_f <= 32'sd0; f <= 32'sd0; f_prev <= 32'sd0; wf <= 32'sd0;
            p_cur <= 32'd0; p_prev <= 32'd0; p_prev2 <= 32'd0;
            ok_cur <= 1'b0; ok_prev <= 1'b0;
            prev_valid <= 1'b0; prev2_valid <= 1'b0; prev_is_start <= 1'b0;
            at_start <= 1'b0;
            steps <= 13'd0;
            timer <= 18'd0;
            meter_restart <= 1'b0;
            freq_wr_valid <= 1'b0;
            freq_wr_data <= 32'sd0;
            evt_found <= 1'b0;
            evt_notfound <= 1'b0;
            evt_limit <= 1'b0;
        end else begin
            meter_restart <= 1'b0;
            freq_wr_valid <= 1'b0;
            evt_found <= 1'b0;
            evt_notfound <= 1'b0;
            evt_limit <= 1'b0;

            if (state != S_IDLE && host_abort) begin
                // Host took over the tuning: keep its value, stop at once.
                result <= R_CANCEL;
                state <= S_IDLE;
            end else if (state != S_IDLE && state != S_FINAL && any_cmd) begin
                // Any key / command during a seek cancels it.
                go_to(start_f);
                result <= R_CANCEL;
                timer <= SETTLE_CYC;
                state <= S_FINAL;
            end else begin
                case (state)
                    S_IDLE: begin
                        if ((seek_up_req || seek_down_req) && step_hz != 0) begin
                            dir_up <= seek_up_req;
                            start_f <= cur_freq;
                            f <= cur_freq;
                            prev_valid <= 1'b0;
                            prev2_valid <= 1'b0;
                            at_start <= 1'b1;
                            steps <= 13'd0;
                            limit_flag <= 1'b0;
                            nosig_flag <= 1'b0;
                            timer <= SETTLE_CYC;
                            state <= S_SETTLE;
                        end else if (cmd_step_up || cmd_step_down) begin
                            if (cmd_step_up ? (man_up > range_p) : (man_down < range_n)) begin
                                evt_limit <= 1'b1;
                                limit_flag <= 1'b1;
                            end else begin
                                go_to(cmd_step_up ? man_up[31:0] : man_down[31:0]);
                                limit_flag <= 1'b0;
                            end
                        end else if (cmd_zero) begin
                            go_to(32'sd0);
                            limit_flag <= 1'b0;
                        end
                    end

                    S_SETTLE: begin
                        if (timer == 18'd0) begin
                            meter_restart <= 1'b1;      // fresh block at new freq
                            meas_timer <= 23'd0;
                            state <= S_MEAS;
                        end else begin
                            timer <= timer - 1'b1;
                        end
                    end

                    S_MEAS: begin
                        if (meter_valid) begin
                            p_cur <= meter_power;
                            ok_cur <= meter_ok;
                            state <= S_DECIDE;
                        end else if (meas_timer >= MEAS_TIMEOUT_CYC - 1) begin
                            // No samples reach the meter: give up cleanly.
                            go_to(start_f);
                            result <= R_NOTFOUND;
                            nosig_flag <= 1'b1;
                            evt_notfound <= 1'b1;
                            timer <= SETTLE_CYC;
                            state <= S_FINAL;
                        end else begin
                            meas_timer <= meas_timer + 1'b1;
                        end
                    end

                    S_DECIDE: begin
                        if (peak_at_prev) begin
                            go_to(f_prev);
                            result <= R_FOUND;
                            evt_found <= 1'b1;
                            timer <= SETTLE_CYC;
                            state <= S_FINAL;
                        end else if ((steps != 13'd0 && at_start) ||
                                     steps >= MAX_STEPS) begin
                            go_to(start_f);
                            result <= R_NOTFOUND;
                            evt_notfound <= 1'b1;
                            timer <= SETTLE_CYC;
                            state <= S_FINAL;
                        end else begin
                            p_prev2 <= p_prev;
                            prev2_valid <= prev_valid;
                            p_prev <= p_cur;
                            ok_prev <= ok_cur;
                            prev_valid <= 1'b1;
                            prev_is_start <= at_start;
                            f_prev <= f;
                            state <= S_NEXT;
                        end
                    end

                    S_NEXT: begin
                        if (dir_up ? (up_next > range_p) : (down_next < range_n)) begin
                            // Wrap to the far band edge, staying on the grid.
                            wf <= f;
                            prev_valid <= 1'b0;
                            prev2_valid <= 1'b0;
                            state <= S_WRAP;
                        end else begin
                            f <= dir_up ? up_next[31:0] : down_next[31:0];
                            at_start <= ((dir_up ? up_next[31:0] : down_next[31:0]) == start_f);
                            go_to(dir_up ? up_next[31:0] : down_next[31:0]);
                            steps <= steps + 1'b1;
                            timer <= SETTLE_CYC;
                            state <= S_SETTLE;
                        end
                    end

                    S_WRAP: begin
                        // Walk the grid to the opposite edge (one step/clock).
                        if (dir_up ? (wf_down >= range_n) : (wf_up <= range_p)) begin
                            wf <= dir_up ? wf_down[31:0] : wf_up[31:0];
                        end else begin
                            f <= wf;
                            at_start <= (wf == start_f);
                            go_to(wf);
                            steps <= steps + 1'b1;
                            timer <= SETTLE_CYC;
                            state <= S_SETTLE;
                        end
                    end

                    S_FINAL: begin
                        // Let the new tuning settle before un-muting.
                        if (timer == 18'd0)
                            state <= S_IDLE;
                        else
                            timer <= timer - 1'b1;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
