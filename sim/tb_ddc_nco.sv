`timescale 1ns/1ps

// nco_phase_control + ddc_mixer: the NCO must advance once per *sample*,
// independent of arrival jitter and output backpressure, and a positive
// tuning word must bring a tone at +f down to 0 Hz.
module tb_ddc_nco;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    localparam real FS = 61.44e6;
    localparam real PI = 3.14159265358979;

    reg  signed [31:0] freq_hz = 0;
    wire [31:0] pinc;
    wire pinc_valid;
    reg  [31:0] s_tdata = 0;
    reg  s_tvalid = 0;
    wire s_tready;
    wire [31:0] m_tdata;
    wire m_tvalid, m_tlast;
    wire [15:0] m_tuser;
    reg  m_tready = 1;

    nco_phase_control #(.SAMPLE_HZ(61_440_000)) u_nco (
        .clk(clk), .rst_n(rst_n), .freq_hz(freq_hz),
        .cfg_tdata(pinc), .cfg_tvalid(pinc_valid), .cfg_tready(1'b1));

    ddc_mixer dut (
        .clk(clk), .rst_n(rst_n),
        .pinc_tdata(pinc), .pinc_tvalid(pinc_valid),
        .s_tdata(s_tdata), .s_tuser(16'd0), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(1'b0),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast));

    // Random output stalls.
    always @(posedge clk) m_tready <= ($urandom % 4) != 0;

    integer n_out = 0;
    integer errors = 0;
    integer mode = 0;   // 0: tone at +f with NCO +f -> DC; 1: drain; 2: frozen phase
    function real rabs(input real v); rabs = (v < 0.0) ? -v : v; endfunction
    function integer rnd(input real v); rnd = $rtoi(v + ((v < 0.0) ? -0.5 : 0.5)); endfunction
    real err_i, err_q, sum_sq = 0.0;
    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            if (mode == 0) begin
                err_i = $signed(m_tdata[31:16]) - 16000.0;
                err_q = $signed(m_tdata[15:0]);
                sum_sq = sum_sq + err_i*err_i + err_q*err_q;
            end
            // 12-bit phase: +/-12.3 LSB at 16000; input rounding x8: +/-4.
            if (mode == 0 && (rabs(err_i) > 24.0 || rabs(err_q) > 24.0)) begin
                errors = errors + 1;
                if (errors < 5)
                    $display("mismatch n=%0d got (%0d,%0d)", n_out,
                             $signed(m_tdata[31:16]), $signed(m_tdata[15:0]));
            end
            n_out = n_out + 1;
        end
    end

    task automatic send(input real i_r, input real q_r);
        begin
            @(negedge clk);
            s_tdata = {16'(rnd(i_r)), 16'(rnd(q_r))};
            s_tvalid = 1;
            do @(posedge clk); while (!s_tready);
            @(negedge clk);
            s_tvalid = 0;
            // Irregular arrival: 0..6 idle clocks between samples.
            repeat ($urandom % 7) @(posedge clk);
        end
    endtask

    integer k;
    real ph;
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;

        // ---- tone at +1.234567 MHz, NCO same -> constant 8*A = 16000 ----
        freq_hz = 32'sd1_234_567;   // incommensurate with FS (1.5 MHz = 25/1024 FS would sit on bin edges)
        repeat (100) @(posedge clk);          // iterative PINC conversion
        for (k = 0; k < 3000; k = k + 1) begin
            ph = 2.0 * PI * 1.234567e6 * k / FS;
            send(2000.0 * $cos(ph), 2000.0 * $sin(ph));
        end
        wait (n_out == 3000);
        if (errors != 0) $fatal(1, "tone not mixed to DC: %0d errors", errors);
        // Quantisation-limited: rms error must stay well below the +/-24 bound.
        if ($sqrt(sum_sq / 3000.0) > 12.0)
            $fatal(1, "mixer rms error too high: %f", $sqrt(sum_sq / 3000.0));
        $display("mixer rms error %0.2f LSB (of 16000)", $sqrt(sum_sq / 3000.0));

        // ---- DC input, NCO 0 -> output = 8*x (phase reset not needed: 0 Hz)
        mode = 1;
        freq_hz = 32'sd0;
        repeat (100) @(posedge clk);
        // Drain any samples mixed with the old tuning word, then re-arm.
        @(negedge clk); n_out = 0; errors = 0;
        for (k = 0; k < 50; k = k + 1) send(0.0, 0.0);
        wait (n_out == 50);
        @(negedge clk); n_out = 0; errors = 0;
        // Current phase is constant now (pinc 0); compensate by measuring it.
        // With pinc = 0 the rotation is a fixed angle; check magnitude only.
        mode = 2;
        for (k = 0; k < 64; k = k + 1) send(1000.0, -500.0);
        wait (n_out == 64);

        $display("TB_DDC_NCO_PASS");
        $finish;
    end

    // mode 2: constant input with frozen phase -> constant |y| = 8*|x|
    always @(posedge clk) begin
        if (mode == 2 && m_tvalid && m_tready) begin
            if (rabs($sqrt(1.0*$signed(m_tdata[31:16])*$signed(m_tdata[31:16]) +
                           1.0*$signed(m_tdata[15:0])*$signed(m_tdata[15:0]))
                     - 8.0 * $sqrt(1000.0*1000.0 + 500.0*500.0)) > 16.0)
                $fatal(1, "frozen-phase magnitude wrong: (%0d,%0d)",
                       $signed(m_tdata[31:16]), $signed(m_tdata[15:0]));
        end
    end

    initial begin
        #2_000_000;
        $fatal(1, "ddc nco timeout");
    end
endmodule
