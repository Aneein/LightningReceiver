`timescale 1ns/1ps

// fm_seek against a behavioural band model + meter model.
module tb_fm_seek;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg  signed [31:0] cur_freq = 0;      // register-bank model
    reg  cmd_seek_up = 0, cmd_seek_down = 0, cmd_cancel = 0;
    reg  cmd_step_up = 0, cmd_step_down = 0, cmd_zero = 0, host_abort = 0;
    reg  host_cmd_valid = 0;
    reg  [1:0] host_cmd = 0;
    reg  meter_valid = 0;
    reg  [31:0] meter_power = 0;
    reg  meter_ok = 0;
    wire meter_restart, freq_wr_valid;
    wire signed [31:0] freq_wr_data;
    wire busy, mute, evt_found, evt_notfound, evt_limit;
    wire [7:0] status;

    fm_seek #(.SETTLE_CYC(20), .MAX_STEPS(4095), .MEAS_TIMEOUT_CYC(500)) dut (
        .clk(clk), .rst_n(rst_n),
        .step_khz(16'd100), .range_khz(16'd10000), .cur_freq(cur_freq),
        .cmd_seek_up(cmd_seek_up), .cmd_seek_down(cmd_seek_down),
        .cmd_cancel(cmd_cancel), .cmd_step_up(cmd_step_up),
        .cmd_step_down(cmd_step_down), .cmd_zero(cmd_zero),
        .host_cmd_valid(host_cmd_valid), .host_cmd(host_cmd),
        .host_abort(host_abort),
        .meter_valid(meter_valid), .meter_power(meter_power), .meter_ok(meter_ok),
        .meter_restart(meter_restart),
        .freq_wr_valid(freq_wr_valid), .freq_wr_data(freq_wr_data),
        .busy(busy), .mute(mute), .evt_found(evt_found),
        .evt_notfound(evt_notfound), .evt_limit(evt_limit), .status(status));

    // ---- band model: triangular stations, skirts pass the CNR test ----
    reg band_on = 1;
    function automatic [32:0] band(input integer fhz);   // {ok, power}
        integer k, d;
        integer fk [0:2];
        integer pk [0:2];
        reg [31:0] p;
        reg ok;
        begin
            fk[0] = 1_200_000;  pk[0] = 900_000;
            fk[1] = -3_500_000; pk[1] = 200_000;
            fk[2] = 7_000_000;  pk[2] = 1_500_000;
            p = 1000; ok = 0;
            if (band_on) begin
                for (k = 0; k < 3; k = k + 1) begin
                    d = (fhz > fk[k]) ? fhz - fk[k] : fk[k] - fhz;
                    if (d < 250_000) p = p + (pk[k] / 250) * (250 - d / 1000);
                    if (d <= 150_000) ok = 1;
                end
            end
            band = {ok, p};
        end
    endfunction

    always @(posedge clk) if (freq_wr_valid) cur_freq <= freq_wr_data;

    // Continuous meter: a result every 60 clocks; restart re-times it.
    // meter_dead models "no AD9361 samples": no results at all.
    integer mcnt = 0;
    reg meter_dead = 0;
    reg [32:0] bv;
    always @(posedge clk) begin
        meter_valid <= 0;
        if (meter_dead) mcnt <= 0;
        else if (meter_restart) mcnt <= 0;
        else if (mcnt == 59) begin
            mcnt <= 0;
            bv = band(cur_freq);
            meter_power <= bv[31:0];
            meter_ok <= bv[32];
            meter_valid <= 1;
        end else mcnt <= mcnt + 1;
    end

    task automatic pulse(ref reg sig);
        begin @(negedge clk); sig = 1; @(negedge clk); sig = 0; end
    endtask

    task automatic seek(input up, input integer expect_hz, input [1:0] expect_res);
        begin
            if (up) pulse(cmd_seek_up); else pulse(cmd_seek_down);
            @(posedge clk); #1;
            if (!busy || !mute) $fatal(1, "seek did not start / mute");
            wait (!busy);
            #1;
            if (mute) $fatal(1, "mute not released");
            if (cur_freq !== expect_hz || status[3:2] !== expect_res)
                $fatal(1, "seek %s: got %0d result %0d, expected %0d result %0d",
                       up ? "up" : "down", cur_freq, status[3:2], expect_hz, expect_res);
            $display("seek %s -> %0d Hz (result %0d)", up ? "up  " : "down", cur_freq, status[3:2]);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // Lands on the station centre, not on the passing skirt (1.1 MHz).
        seek(1, 1_200_000, 2'd1);
        // Starting station and its upper skirt are skipped.
        seek(1, 7_000_000, 2'd1);
        // Wraps +10 MHz -> -10 MHz and finds the weak station.
        seek(1, -3_500_000, 2'd1);
        // Downward wrap -10 -> +10 MHz.
        seek(0, 7_000_000, 2'd1);
        seek(0, 1_200_000, 2'd1);

        // Cancel restores the starting frequency.
        pulse(cmd_seek_up);
        repeat (300) @(posedge clk);
        if (!busy) $fatal(1, "seek ended too early for cancel test");
        pulse(cmd_cancel);
        wait (!busy); #1;
        if (cur_freq !== 1_200_000 || status[3:2] !== 2'd3)
            $fatal(1, "cancel did not restore start: %0d", cur_freq);

        // Host SEEK_CTRL: seek up via register, then cancel via register.
        @(negedge clk); host_cmd = 2'd1; host_cmd_valid = 1;
        @(negedge clk); host_cmd_valid = 0;
        wait (!busy); #1;
        if (cur_freq !== 7_000_000 || status[3:2] !== 2'd1)
            $fatal(1, "host seek up failed: %0d", cur_freq);
        @(negedge clk); host_cmd = 2'd2; host_cmd_valid = 1;
        @(negedge clk); host_cmd_valid = 0;
        repeat (300) @(posedge clk);
        @(negedge clk); host_cmd = 2'd3; host_cmd_valid = 1;
        @(negedge clk); host_cmd_valid = 0;
        wait (!busy); #1;
        if (cur_freq !== 7_000_000 || status[3:2] !== 2'd3)
            $fatal(1, "host cancel failed: %0d", cur_freq);

        // Host write during a seek wins immediately.
        pulse(cmd_seek_down);
        repeat (300) @(posedge clk);
        @(negedge clk); cur_freq = 32'sd4_400_000; host_abort = 1;
        @(negedge clk); host_abort = 0;
        #1;
        if (busy || mute) $fatal(1, "host abort did not stop the seek");
        repeat (200) @(posedge clk);
        if (cur_freq !== 4_400_000) $fatal(1, "seek overwrote the host value");

        // Manual steps clamp at the band edge.
        @(negedge clk); cur_freq = 32'sd9_900_000;
        pulse(cmd_step_up); repeat (2) @(posedge clk);
        if (cur_freq !== 10_000_000) $fatal(1, "step up failed");
        fork
            pulse(cmd_step_up);
            begin @(posedge evt_limit); end
        join
        repeat (2) @(posedge clk);
        if (cur_freq !== 10_000_000 || !status[4]) $fatal(1, "limit not enforced");
        pulse(cmd_step_down); repeat (2) @(posedge clk);
        if (cur_freq !== 9_900_000) $fatal(1, "step down failed");
        pulse(cmd_zero); repeat (2) @(posedge clk);
        if (cur_freq !== 0) $fatal(1, "zero failed");

        // Empty band: one full lap, then back to the start.
        band_on = 0;
        @(negedge clk); cur_freq = 32'sd300_000;
        fork
            seek(1, 300_000, 2'd2);
            begin @(posedge evt_notfound); end
        join

        // No samples at all: the seek times out and restores the start.
        band_on = 1;
        meter_dead = 1;
        @(negedge clk); cur_freq = 32'sd1_200_000;
        pulse(cmd_seek_up);
        wait (!busy); #1;
        if (cur_freq !== 1_200_000 || status[3:2] !== 2'd2 || !status[5])
            $fatal(1, "no-signal timeout wrong: f=%0d status=%b", cur_freq, status);
        $display("no-signal seek -> timeout, status %b", status);
        meter_dead = 0;

        $display("TB_FM_SEEK_PASS");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "fm_seek timeout");
    end
endmodule
