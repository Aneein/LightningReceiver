// ============================================================================
// Lightning Receiver - Front panel controller (4 keys + 4 LEDs, FM mode)
// File: ui_panel.v
// ----------------------------------------------------------------------------
// Keys (debounced, active-high levels; KEY1..KEY4 = key_level[0..3]):
//   KEY1 short  : seek down          KEY1 hold >= LONG  : step down, auto-repeat
//   KEY2 short  : seek up            KEY2 hold >= LONG  : step up,   auto-repeat
//   KEY3        : DDR recording on/off
//   KEY4        : network audio on/off
//   KEY1+KEY2 held >= COMBO : tuning offset back to 0 (LO centre)
//   Any key while seeking   : cancel the seek (restores the start frequency)
//   Locked by host (CONTROL.PANEL_LOCK) or not in FM mode: keys are ignored
//   and all four LEDs blink once as feedback.
//
// LEDs (base pattern, then an 80 ms inversion acknowledges an accepted key):
//   LED1 system : on ready | slow: DDR not calibrated | fast: sticky error
//   LED2 tuning : off no AD9361 samples | slow: no station here |
//                 on station here | fast: seeking (3 fast after not-found/limit)
//   LED3 record : off idle | on recording | fast: samples dropped (last 1 s)
//   LED4 network: off disabled | slow: link down | on sending |
//                 fast: drops on the network branch (last 1 s)
// (If the fabric clock is not running, all LEDs are held off by reset.)
// ============================================================================
`timescale 1ns/1ps

module ui_panel #(
    parameter integer CLK_HZ    = 225_014_957,
    parameter integer LONG_MS   = 500,
    parameter integer REPEAT_MS = 150,
    parameter integer COMBO_MS  = 1000,
    parameter integer ACK_MS    = 80,
    parameter integer FLASH_MS  = 120,
    parameter integer ACT_MS    = 10,
    parameter integer EVENT_MS  = 1000,
    parameter integer FLASH3_MS = 750
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  key_level,
    // context
    input  wire [1:0]  mode_active,     // mode_manager: 0 = FM
    input  wire        panel_lock,
    input  wire        seek_busy,
    input  wire        evt_notfound,
    input  wire        evt_limit,
    // status for LEDs
    input  wire        calib_ok,
    input  wire [31:0] err_status,      // telemetry sticky errors
    input  wire        sample_pulse,
    input  wire        station_ok,
    input  wire        rec_on,
    input  wire        rec_drop_pulse,
    input  wire        net_on,
    input  wire        link_up,
    input  wire        net_drop_pulse,
    // commands (1-cycle pulses)
    output reg         cmd_seek_up,
    output reg         cmd_seek_down,
    output reg         cmd_step_up,
    output reg         cmd_step_down,
    output reg         cmd_zero,
    output reg         cmd_cancel,
    output reg         cmd_rec_toggle,
    output reg         cmd_net_toggle,
    // outputs
    output reg  [3:0]  led,
    output wire [31:0] ui_status
);

    localparam integer TICK_DIV = CLK_HZ / 1000;

    wire mode_fm = (mode_active == 2'd0);
    wire err_any = (err_status != 32'd0);

    localparam [3:0] A_SEEK_UP = 4'd1, A_SEEK_DOWN = 4'd2, A_STEP_UP = 4'd3,
                     A_STEP_DOWN = 4'd4, A_ZERO = 4'd5, A_CANCEL = 4'd6,
                     A_REC = 4'd7, A_NET = 4'd8, A_LOCKED = 4'd9,
                     A_NOT_FM = 4'd10;

    // ---------------- 1 ms tick and blink phases ----------------
    reg [31:0] div_cnt;
    reg        ms_tick;
    reg [9:0]  ms_1000;
    reg [7:0]  ms_250;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 32'd0;
            ms_tick <= 1'b0;
            ms_1000 <= 10'd0;
            ms_250  <= 8'd0;
        end else begin
            ms_tick <= 1'b0;
            if (div_cnt == TICK_DIV - 1) begin
                div_cnt <= 32'd0;
                ms_tick <= 1'b1;
                ms_1000 <= (ms_1000 == 10'd999) ? 10'd0 : ms_1000 + 1'b1;
                ms_250  <= (ms_250 == 8'd249) ? 8'd0 : ms_250 + 1'b1;
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end
    wire blink_slow = (ms_1000 < 10'd500);
    wire blink_fast = (ms_250 < 8'd125);

    // ---------------- key edges ----------------
    reg  [3:0] key_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) key_q <= 4'd0; else key_q <= key_level;
    wire [3:0] press = key_level & ~key_q;
    wire k1 = key_level[0];
    wire k2 = key_level[1];

    wire blocked = panel_lock || !mode_fm;

    // ---------------- KEY1/KEY2 gesture FSM ----------------
    localparam [2:0] F_IDLE = 3'd0, F_ARM = 3'd1, F_REPEAT = 3'd2,
                     F_COMBO = 3'd3, F_WAIT = 3'd4;
    reg [2:0]  fstate;
    reg        fsel_up;            // 1 = KEY2 (up), 0 = KEY1 (down)
    reg [15:0] fms;                // ms in the current gesture state
    wire       fsel_level = fsel_up ? k2 : k1;
    wire       other_level = fsel_up ? k1 : k2;

    // ---------------- action bookkeeping ----------------
    reg [3:0]  last_action;
    reg [7:0]  action_count;
    reg [15:0] ack_t [0:3];
    reg [15:0] rej_t;
    reg [15:0] act_t, recdrop_t, netdrop_t, flash3_t;
    integer i;

    task act;
        input [3:0] code;
        input integer led_idx;     // -1: no LED acknowledgement
        begin
            last_action  <= code;
            action_count <= action_count + 1'b1;
            if (led_idx >= 0)
                ack_t[led_idx] <= ACK_MS;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate <= F_IDLE;
            fsel_up <= 1'b0;
            fms <= 16'd0;
            cmd_seek_up <= 1'b0; cmd_seek_down <= 1'b0;
            cmd_step_up <= 1'b0; cmd_step_down <= 1'b0;
            cmd_zero <= 1'b0; cmd_cancel <= 1'b0;
            cmd_rec_toggle <= 1'b0; cmd_net_toggle <= 1'b0;
            last_action <= 4'd0;
            action_count <= 8'd0;
            for (i = 0; i < 4; i = i + 1) ack_t[i] <= 16'd0;
            rej_t <= 16'd0;
            act_t <= 16'd0;
            recdrop_t <= 16'd0;
            netdrop_t <= 16'd0;
            flash3_t <= 16'd0;
        end else begin
            cmd_seek_up <= 1'b0; cmd_seek_down <= 1'b0;
            cmd_step_up <= 1'b0; cmd_step_down <= 1'b0;
            cmd_zero <= 1'b0; cmd_cancel <= 1'b0;
            cmd_rec_toggle <= 1'b0; cmd_net_toggle <= 1'b0;

            // ---- ms timers ----
            if (ms_tick) begin
                fms <= (fms == 16'hFFFF) ? fms : fms + 1'b1;
                for (i = 0; i < 4; i = i + 1)
                    if (ack_t[i] != 0) ack_t[i] <= ack_t[i] - 1'b1;
                if (rej_t != 0) rej_t <= rej_t - 1'b1;
                if (act_t != 0) act_t <= act_t - 1'b1;
                if (recdrop_t != 0) recdrop_t <= recdrop_t - 1'b1;
                if (netdrop_t != 0) netdrop_t <= netdrop_t - 1'b1;
                if (flash3_t != 0) flash3_t <= flash3_t - 1'b1;
            end
            if (sample_pulse)   act_t <= ACT_MS;
            if (rec_drop_pulse) recdrop_t <= EVENT_MS;
            if (net_drop_pulse) netdrop_t <= EVENT_MS;
            if (evt_notfound || evt_limit) flash3_t <= FLASH3_MS;

            // ---- generic press handling ----
            if (press != 4'd0) begin
                if (blocked) begin
                    rej_t <= 2 * FLASH_MS;
                    last_action <= panel_lock ? A_LOCKED : A_NOT_FM;
                    action_count <= action_count + 1'b1;
                end else if (seek_busy) begin
                    cmd_cancel <= 1'b1;
                    act(A_CANCEL, 1);
                end else if (press[2]) begin
                    cmd_rec_toggle <= 1'b1;
                    act(A_REC, 2);
                end else if (press[3]) begin
                    cmd_net_toggle <= 1'b1;
                    act(A_NET, 3);
                end
            end

            // ---- KEY1/KEY2 gestures ----
            case (fstate)
                F_IDLE: begin
                    if (press[0] || press[1]) begin
                        fms <= 16'd0;
                        if (blocked || seek_busy)
                            fstate <= F_WAIT;          // consumed above
                        else if (press[0] && press[1])
                            fstate <= F_COMBO;
                        else begin
                            fsel_up <= press[1];
                            fstate <= F_ARM;
                        end
                    end
                end
                F_ARM: begin
                    if (other_level) begin
                        fms <= 16'd0;
                        fstate <= F_COMBO;
                    end else if (!fsel_level) begin
                        // short press -> seek
                        if (fsel_up) begin
                            cmd_seek_up <= 1'b1;
                            act(A_SEEK_UP, -1);
                        end else begin
                            cmd_seek_down <= 1'b1;
                            act(A_SEEK_DOWN, -1);
                        end
                        fstate <= F_WAIT;
                    end else if (fms >= LONG_MS) begin
                        fms <= 16'd0;
                        if (fsel_up) begin
                            cmd_step_up <= 1'b1;
                            act(A_STEP_UP, 1);
                        end else begin
                            cmd_step_down <= 1'b1;
                            act(A_STEP_DOWN, 1);
                        end
                        fstate <= F_REPEAT;
                    end
                end
                F_REPEAT: begin
                    if (!fsel_level) begin
                        fstate <= F_WAIT;
                    end else if (fms >= REPEAT_MS) begin
                        fms <= 16'd0;
                        if (fsel_up) begin
                            cmd_step_up <= 1'b1;
                            act(A_STEP_UP, 1);
                        end else begin
                            cmd_step_down <= 1'b1;
                            act(A_STEP_DOWN, 1);
                        end
                    end
                end
                F_COMBO: begin
                    if (!(k1 && k2)) begin
                        fstate <= F_WAIT;               // released early
                    end else if (fms >= COMBO_MS) begin
                        cmd_zero <= 1'b1;
                        act(A_ZERO, 1);
                        fstate <= F_WAIT;
                    end
                end
                F_WAIT: begin
                    if (!k1 && !k2)
                        fstate <= F_IDLE;
                end
                default: fstate <= F_IDLE;
            endcase
        end
    end

    // ---------------- LED patterns ----------------
    reg [3:0] led_base;
    always @(*) begin
        // LED1 system
        if (!calib_ok)      led_base[0] = blink_slow;
        else if (err_any)   led_base[0] = blink_fast;
        else                led_base[0] = 1'b1;
        // LED2 tuning
        if (seek_busy || flash3_t != 0) led_base[1] = blink_fast;
        else if (act_t == 0)            led_base[1] = 1'b0;
        else if (station_ok)            led_base[1] = 1'b1;
        else                            led_base[1] = blink_slow;
        // LED3 record
        if (!rec_on)                led_base[2] = 1'b0;
        else if (recdrop_t != 0)    led_base[2] = blink_fast;
        else                        led_base[2] = 1'b1;
        // LED4 network
        if (!net_on)                led_base[3] = 1'b0;
        else if (!link_up)          led_base[3] = blink_slow;
        else if (netdrop_t != 0)    led_base[3] = blink_fast;
        else                        led_base[3] = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            led <= 4'd0;
        end else if (rej_t != 0) begin
            // Rejected key: all LEDs on, then all off, once.
            led <= (rej_t > FLASH_MS) ? 4'hF : 4'h0;
        end else begin
            for (i = 0; i < 4; i = i + 1)
                led[i] <= led_base[i] ^ (ack_t[i] != 0);
        end
    end

    assign ui_status = {8'd0, 1'b0, (act_t != 0), mode_fm, panel_lock,
                        led, action_count, last_action, key_level};

endmodule
