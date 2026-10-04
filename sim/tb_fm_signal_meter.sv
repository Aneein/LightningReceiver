`timescale 1ns/1ps

// fm_signal_meter: envelope-flatness station detector + channel power.
module tb_fm_signal_meter;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    localparam real PI = 3.14159265358979;

    reg  [31:0] s_tdata = 0;
    reg  s_tvalid = 0;
    wire s_tready;
    wire [31:0] m_tdata;
    wire [15:0] m_tuser;
    wire m_tvalid, m_tlast;
    reg  m_tready = 1;
    reg  restart = 0;
    reg  [15:0] thr_q8 = 16'h0140;
    reg  [15:0] min_power = 16'd0;
    wire [31:0] power_mean;
    wire [15:0] flat_q8;
    wire station_ok, result_valid;
    wire [7:0] result_count;

    fm_signal_meter #(.LOG2N(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tuser(16'hA5A5), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(1'b1),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast),
        .restart(restart), .thr_q8(thr_q8), .min_power(min_power),
        .power_mean(power_mean), .flat_q8(flat_q8), .station_ok(station_ok),
        .result_valid(result_valid), .result_count(result_count));

    function integer rnd(input real v); rnd = $rtoi(v + ((v < 0.0) ? -0.5 : 0.5)); endfunction

    integer seed = 12345;
    real theta = 0.0;
    // kind 0: FM-like constant envelope; 1: Gaussian noise; 2: FM + noise
    task automatic send(input integer kind, input real amp, input real sigma);
        real i_r, q_r;
        begin
            theta = theta + 2.0 * PI * ($dist_uniform(seed, -400, 400) / 1000.0);
            i_r = 0.0; q_r = 0.0;
            if (kind != 1) begin i_r = amp * $cos(theta); q_r = amp * $sin(theta); end
            if (kind != 0) begin
                i_r = i_r + $dist_normal(seed, 0, $rtoi(sigma));
                q_r = q_r + $dist_normal(seed, 0, $rtoi(sigma));
            end
            @(negedge clk);
            s_tdata = {16'(rnd(i_r)), 16'(rnd(q_r))};
            s_tvalid = 1;
            @(negedge clk);
            // pass-through must be transparent
            s_tvalid = 0;
            repeat (48) @(posedge clk);
        end
    endtask

    // Feed until one fresh block result appears, then return it.
    task automatic measure(input integer kind, input real amp, input real sigma);
        reg [7:0] c0;
        begin
            c0 = result_count;
            while (result_count == c0) send(kind, amp, sigma);
        end
    endtask

    always @(posedge clk) begin
        if (s_tvalid && (m_tdata !== s_tdata || m_tuser !== 16'hA5A5 ||
                         !m_tvalid || !m_tlast))
            $fatal(1, "pass-through altered the stream");
        if (s_tready !== m_tready)
            $fatal(1, "s_tready must follow m_tready");
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;

        // Discard the first (partial-alignment) block.
        measure(0, 1000.0, 0.0);

        // 1) Clean FM: flat ~1.0 (256), power ~ A^2.
        measure(0, 1000.0, 0.0);
        $display("FM clean:  flat=%0d power=%0d ok=%0b", flat_q8, power_mean, station_ok);
        if (flat_q8 > 16'd260 || !station_ok)
            $fatal(1, "clean FM not detected (flat %0d)", flat_q8);
        if (power_mean < 32'd995000 || power_mean > 32'd1005000)
            $fatal(1, "power mean wrong: %0d", power_mean);

        // 2) Gaussian noise: flat ~2.0 (512), never a station.
        measure(1, 0.0, 700.0);
        measure(1, 0.0, 700.0);
        $display("Noise:     flat=%0d power=%0d ok=%0b", flat_q8, power_mean, station_ok);
        if (flat_q8 < 16'd400 || flat_q8 > 16'd650 || station_ok)
            $fatal(1, "noise misclassified (flat %0d)", flat_q8);

        // 3) FM at 10 dB CNR: theory 1.174 (300).
        measure(2, 1000.0, 223.6);
        measure(2, 1000.0, 223.6);
        $display("FM 10 dB:  flat=%0d power=%0d ok=%0b", flat_q8, power_mean, station_ok);
        if (flat_q8 < 16'd270 || flat_q8 > 16'd330 || !station_ok)
            $fatal(1, "10 dB CNR FM wrong (flat %0d)", flat_q8);

        // 4) Minimum-power gate rejects an otherwise clean but weak signal.
        min_power = 16'd100;                      // needs power >= 100*65536
        measure(0, 1000.0, 0.0);
        measure(0, 1000.0, 0.0);
        if (station_ok) $fatal(1, "min_power gate ignored");
        min_power = 16'd0;

        // 5) restart discards the partial block: next result needs N samples.
        send(0, 1000.0, 0.0);
        @(negedge clk); restart = 1; @(negedge clk); restart = 0;
        begin : restart_check
            reg [7:0] c0;
            integer k;
            c0 = result_count;
            for (k = 0; k < 250; k = k + 1) send(0, 1000.0, 0.0);
            if (result_count != c0) $fatal(1, "restart did not reset the block");
            measure(0, 1000.0, 0.0);
        end

        $display("TB_FM_SIGNAL_METER_PASS");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "signal meter timeout");
    end
endmodule
