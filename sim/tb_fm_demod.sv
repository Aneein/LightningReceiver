`timescale 1ns/1ps

module tb_fm_demod;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg [31:0] s_tdata = 0;
    reg [15:0] s_tuser = 0;
    reg s_tvalid = 0;
    wire s_tready;
    reg s_tlast = 0;
    wire [31:0] m_tdata;
    wire [15:0] m_tuser;
    wire m_tvalid;
    reg m_tready = 1;
    reg iq_bypass = 0;
    wire m_tlast;

    localparam real PI = 3.14159265358979;

    fm_demod dut (
        .clk(clk), .rst_n(rst_n), .iq_bypass(iq_bypass), .s_tdata(s_tdata), .s_tuser(s_tuser),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast)
    );

    function integer rnd(input real v); rnd = $rtoi(v + ((v < 0.0) ? -0.5 : 0.5)); endfunction

    task automatic send_sample(
        input signed [15:0] iv,
        input signed [15:0] qv,
        input [15:0] userv,
        input lastv
    );
        begin
            @(negedge clk);
            s_tdata = {iv, qv};
            s_tuser = userv;
            s_tlast = lastv;
            s_tvalid = 1;
            do @(posedge clk); while (!s_tready);
            @(negedge clk);
            s_tvalid = 0;
        end
    endtask

    task automatic expect_output(
        input integer expected,
        input integer tol,
        input [15:0] userv,
        input lastv
    );
        integer got;
        begin
            wait (m_tvalid);
            #1;
            got = $signed(m_tdata[31:16]);
            if (got > expected + tol || got < expected - tol ||
                m_tdata[15:0] !== 16'd0 || m_tuser !== userv ||
                m_tlast !== lastv)
                $fatal(1, "FM output mismatch: got %0d expected %0d", got, expected);
            @(posedge clk); #1;
        end
    endtask

    // Phase-step sweep: x[n] = A*e^{j*theta[n]}, theta[n] = theta[n-1] + d.
    real theta = 0.0;
    real prev_amp = 1000.0;
    task automatic step_check(input real amp, input real dphi_deg);
        real d;
        integer expv;
        begin
            d = dphi_deg * PI / 180.0;
            theta = theta + d;
            send_sample(16'(rnd(amp * $cos(theta))), 16'(rnd(amp * $sin(theta))),
                        16'h0, 1'b0);
            expv = rnd(dphi_deg / 180.0 * 32768.0);
            if (expv > 32767) expv = 32767;
            // Input rounding (+/-0.5 LSB per component on two samples) gives
            // up to ~1.4/amp rad = 14600/amp output LSB; CORDIC adds ~2 LSB.
            // The step pairs this sample with the previous one: use the
            // smaller amplitude of the two.
            expect_output(expv, 3 + $rtoi(14600.0 / ((amp < prev_amp) ? amp : prev_amp)),
                          16'h0, 1'b0);
            prev_amp = amp;
        end
    endtask

    integer k;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;

        // First sample has no predecessor energy -> 0.
        send_sample(16'sd1000, 16'sd0, 16'h11, 1'b0);
        expect_output(0, 0, 16'h11, 1'b0);

        // +90 degrees under output backpressure: value/metadata must hold.
        m_tready = 0;
        send_sample(16'sd0, 16'sd1000, 16'h22, 1'b1);
        wait (m_tvalid);
        #1;
        begin : fm_stall_check
            reg [31:0] held_data;
            reg [15:0] held_user;
            reg held_last;
            held_data = m_tdata;
            held_user = m_tuser;
            held_last = m_tlast;
            repeat (4) begin
                @(posedge clk); #1;
                if (!m_tvalid || m_tdata !== held_data ||
                    m_tuser !== held_user || m_tlast !== held_last)
                    $fatal(1, "FM output changed under backpressure");
            end
        end
        if ($signed(m_tdata[31:16]) < 16380 || $signed(m_tdata[31:16]) > 16388 ||
            m_tuser !== 16'h22 || !m_tlast)
            $fatal(1, "+90 deg value mismatch: %0d", $signed(m_tdata[31:16]));
        m_tready = 1;
        @(posedge clk);

        // Linear over the full range, including beyond +/-90 degrees where
        // the old sin() discriminator folded back.  140.6 deg = 75 kHz @192k.
        theta = PI / 2.0;
        step_check(1000.0, 10.0);
        step_check(1000.0, -10.0);
        step_check(1000.0, 45.0);
        step_check(1000.0, 89.0);
        step_check(1000.0, 120.0);
        step_check(1000.0, 140.625);
        step_check(1000.0, 179.0);
        step_check(1000.0, -140.625);
        step_check(1000.0, -179.0);
        step_check(1000.0, 0.0);
        // Large and small input amplitudes (normalisation path).
        for (k = 0; k < 8; k = k + 1) step_check(30000.0, -100.0 + 25.0 * k);
        for (k = 0; k < 8; k = k + 1) step_check(60.0, 100.0 - 25.0 * k);

        // Narrowband IQ mode: samples pass through unchanged, with metadata
        // and backpressure; switching back resumes demodulation.
        iq_bypass = 1;
        send_sample(16'sh1234, -16'sd5, 16'h33, 1'b1);
        wait (m_tvalid); #1;
        if (m_tdata !== {16'sh1234, -16'sd5} || m_tuser !== 16'h33 || !m_tlast)
            $fatal(1, "IQ bypass mismatch: %h", m_tdata);
        @(posedge clk); #1;
        m_tready = 0;
        send_sample(-16'sd32768, 16'sd32767, 16'h44, 1'b0);
        wait (m_tvalid); #1;
        repeat (3) begin
            @(posedge clk); #1;
            if (!m_tvalid || m_tdata !== {-16'sd32768, 16'sd32767})
                $fatal(1, "IQ bypass changed under backpressure");
        end
        m_tready = 1;
        @(posedge clk); #1;
        iq_bypass = 0;
        // last bypassed sample (-32768, 32767) then +90 deg rotation of it
        send_sample(-16'sd32767, -16'sd32768, 16'h0, 1'b0);
        wait (m_tvalid); #1;
        if ($signed(m_tdata[31:16]) < 16380 || $signed(m_tdata[31:16]) > 16388 ||
            m_tdata[15:0] !== 16'd0)
            $fatal(1, "demod after bypass wrong: %0d", $signed(m_tdata[31:16]));
        @(posedge clk);

        $display("TB_FM_DEMOD_PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "FM demod timeout");
    end
endmodule
