`timescale 1ns/1ps

// Front-panel gestures and LED patterns (1 ms = 10 clocks in this bench).
module tb_ui_panel;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg [3:0] key = 0;
    reg mode_fm = 1, panel_lock = 0, seek_busy = 0;
    wire [1:0] mode_active = mode_fm ? 2'd0 : 2'd1;
    reg evt_notfound = 0, evt_limit = 0;
    reg calib_ok = 1, err_any = 0, sample_pulse = 0, station_ok = 0;
    reg rec_on = 0, rec_drop_pulse = 0, net_on = 1, link_up = 1, net_drop_pulse = 0;
    wire seek_up, seek_down, step_up, step_down, zero, cancel, rec_t, net_t;
    wire [3:0] led;
    wire [31:0] ui_status;

    ui_panel #(.CLK_HZ(10_000)) dut (
        .clk(clk), .rst_n(rst_n), .key_level(key),
        .mode_active(mode_active), .panel_lock(panel_lock), .seek_busy(seek_busy),
        .evt_notfound(evt_notfound), .evt_limit(evt_limit),
        .calib_ok(calib_ok), .err_status({31'd0, err_any}), .sample_pulse(sample_pulse),
        .station_ok(station_ok), .rec_on(rec_on), .rec_drop_pulse(rec_drop_pulse),
        .net_on(net_on), .link_up(link_up), .net_drop_pulse(net_drop_pulse),
        .cmd_seek_up(seek_up), .cmd_seek_down(seek_down),
        .cmd_step_up(step_up), .cmd_step_down(step_down),
        .cmd_zero(zero), .cmd_cancel(cancel),
        .cmd_rec_toggle(rec_t), .cmd_net_toggle(net_t),
        .led(led), .ui_status(ui_status));

    integer n_su = 0, n_sd = 0, n_pu = 0, n_pd = 0, n_z = 0, n_c = 0, n_r = 0, n_n = 0;
    always @(posedge clk) begin
        n_su <= n_su + seek_up;   n_sd <= n_sd + seek_down;
        n_pu <= n_pu + step_up;   n_pd <= n_pd + step_down;
        n_z  <= n_z + zero;       n_c  <= n_c + cancel;
        n_r  <= n_r + rec_t;      n_n  <= n_n + net_t;
    end

    // keep "AD9361 samples" alive unless a test stops them
    reg samples_on = 1;
    always @(posedge clk) sample_pulse <= samples_on && ($urandom % 8 == 0);

    task ms(input integer n); repeat (n * 10) @(negedge clk); endtask

    task check(input integer su, sd, pu, pd, z, c, r, n, input [8*24-1:0] what);
        begin
            ms(2);
            if (n_su != su || n_sd != sd || n_pu != pu || n_pd != pd ||
                n_z != z || n_c != c || n_r != r || n_n != n)
                $fatal(1, "%0s: su%0d sd%0d pu%0d pd%0d z%0d c%0d r%0d n%0d", what,
                       n_su, n_sd, n_pu, n_pd, n_z, n_c, n_r, n_n);
        end
    endtask

    // count LED toggles over a window -> blink rate
    task automatic toggles(input integer idx, input integer win_ms, output integer t);
        reg prev;
        integer k;
        begin
            t = 0; prev = led[idx];
            for (k = 0; k < win_ms * 10; k = k + 1) begin
                @(negedge clk);
                if (led[idx] != prev) begin t = t + 1; prev = led[idx]; end
            end
        end
    endtask

    integer t;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        ms(5);

        // Short KEY2 -> seek up; short KEY1 -> seek down.
        key[1] = 1; ms(100); key[1] = 0;
        check(1,0,0,0,0,0,0,0, "short KEY2");
        key[0] = 1; ms(100); key[0] = 0;
        check(1,1,0,0,0,0,0,0, "short KEY1");

        // Hold KEY1 820 ms -> steps at 500/650/800 ms, no seek.
        key[0] = 1; ms(820); key[0] = 0;
        check(1,1,0,3,0,0,0,0, "hold KEY1");

        // KEY1 then KEY2, hold 1.1 s -> zero once.
        key[0] = 1; ms(80); key[1] = 1; ms(1100); key = 0;
        check(1,1,0,3,1,0,0,0, "combo zero");
        // Combo released early -> nothing.
        key[1] = 1; ms(50); key[0] = 1; ms(400); key = 0;
        check(1,1,0,3,1,0,0,0, "combo early");

        // KEY3 / KEY4 toggles, LED3 acknowledges with an inversion.
        key[2] = 1; ms(2);
        if (led[2] !== 1'b1) $fatal(1, "LED3 ack missing");   // base off ^ ack
        ms(50); key[2] = 0;
        check(1,1,0,3,1,0,1,0, "KEY3");
        key[3] = 1; ms(50); key[3] = 0;
        check(1,1,0,3,1,0,1,1, "KEY4");

        // While seeking, any key only cancels.
        seek_busy = 1;
        key[2] = 1; ms(50); key[2] = 0;
        key[1] = 1; ms(700); key[1] = 0;      // a hold must not step either
        check(1,1,0,3,1,2,1,1, "cancel while seeking");
        seek_busy = 0;

        // Locked panel: nothing happens, all LEDs flash once.
        panel_lock = 1;
        key[3] = 1; ms(2);
        if (led !== 4'hF) $fatal(1, "locked flash missing");
        ms(150);
        if (led !== 4'h0) $fatal(1, "locked flash second half missing");
        key[3] = 0;
        key[0] = 1; ms(700); key[0] = 0;
        check(1,1,0,3,1,2,1,1, "locked");
        if (ui_status[7:4] != 4'd9) $fatal(1, "lock reject not reported");
        panel_lock = 0;

        // Not FM mode: same rejection.
        mode_fm = 0;
        key[2] = 1; ms(30); key[2] = 0;
        check(1,1,0,3,1,2,1,1, "SDR mode");
        if (ui_status[7:4] != 4'd10) $fatal(1, "mode reject not reported");
        mode_fm = 1;
        ms(300);

        // ---- LED patterns ----
        toggles(0, 2000, t); if (t != 0) $fatal(1, "LED1 should be steady (%0d)", t);
        calib_ok = 0; toggles(0, 2000, t);
        if (t < 3 || t > 5) $fatal(1, "LED1 slow blink wrong (%0d)", t);
        calib_ok = 1; err_any = 1; toggles(0, 1000, t);
        if (t < 7 || t > 9) $fatal(1, "LED1 fast blink wrong (%0d)", t);
        err_any = 0;

        station_ok = 1; ms(20);
        if (led[1] !== 1'b1) $fatal(1, "LED2 station not shown");
        station_ok = 0; toggles(1, 2000, t);
        if (t < 3 || t > 5) $fatal(1, "LED2 no-station slow blink wrong (%0d)", t);
        samples_on = 0; ms(30);
        if (led[1] !== 1'b0) $fatal(1, "LED2 should be off without samples");
        samples_on = 1;
        @(negedge clk); evt_notfound = 1; @(negedge clk); evt_notfound = 0;
        toggles(1, 760, t);
        // 6 fast half-periods plus the entry/exit edges against the slow base
        if (t < 5 || t > 9) $fatal(1, "LED2 not-found flash wrong (%0d)", t);

        link_up = 0; toggles(3, 2000, t);
        if (t < 3 || t > 5) $fatal(1, "LED4 link-down blink wrong (%0d)", t);
        link_up = 1; ms(10);
        if (led[3] !== 1'b1) $fatal(1, "LED4 should be on");
        net_on = 0; ms(10);
        if (led[3] !== 1'b0) $fatal(1, "LED4 should be off");

        $display("TB_UI_PANEL_PASS");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "ui panel timeout");
    end
endmodule
