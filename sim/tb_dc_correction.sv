`timescale 1ns/1ps

// dc_correction must (a) remove a static DC offset, (b) NOT invent one from
// zero-mean full-scale noise (the hardware failure of the integer estimator),
// (c) pass data untouched in bypass.
module tb_dc_correction;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg bypass = 0;
    reg [31:0] s_tdata = 0;
    reg s_tvalid = 0;
    wire s_tready;
    wire [31:0] m_tdata;
    wire [15:0] m_tuser;
    wire m_tvalid, m_tlast;

    dc_correction #(.ALPHA_SHIFT(12)) dut (
        .clk(clk), .rst_n(rst_n), .bypass(bypass),
        .s_tdata(s_tdata), .s_tuser(16'h0), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(1'b0),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(1'b1), .m_tlast(m_tlast));

    integer seed = 7;
    real sum_i, sum_q;
    integer n;

    // Feed N samples (one per clock) of uniform noise in +/-amp plus an offset
    // and return the mean of the last half of the outputs.
    task automatic run(input integer N, input integer amp, input integer off_i,
                       input integer off_q, output real mi, output real mq);
        integer k, vi, vq;
        begin
            sum_i = 0; sum_q = 0; n = 0;
            for (k = 0; k < N; k = k + 1) begin
                @(negedge clk);
                vi = $dist_uniform(seed, -amp, amp) + off_i;
                vq = $dist_uniform(seed, -amp, amp) + off_q;
                s_tdata = {16'(vi), 16'(vq)};
                s_tvalid = 1;
                @(posedge clk); #1;
                if (k >= N / 2 && m_tvalid) begin
                    sum_i = sum_i + $signed(m_tdata[31:16]);
                    sum_q = sum_q + $signed(m_tdata[15:0]);
                    n = n + 1;
                end
            end
            @(negedge clk); s_tvalid = 0;
            mi = sum_i / n; mq = sum_q / n;
        end
    endtask

    real mi, mq;
    initial begin
        repeat (3) @(posedge clk); rst_n = 1;

        // (b) zero-mean 12-bit full-scale noise: output mean must stay ~0.
        run(60000, 2047, 0, 0, mi, mq);
        $display("zero-mean noise   -> output mean I %0.2f Q %0.2f", mi, mq);
        if (mi > 8.0 || mi < -8.0 || mq > 8.0 || mq < -8.0)
            $fatal(1, "DC estimator drifted on zero-mean input");

        // (a) static offset (+300, -1200) on top of noise is removed.
        run(80000, 1500, 300, -1200, mi, mq);
        $display("offset +300/-1200 -> output mean I %0.2f Q %0.2f", mi, mq);
        if (mi > 8.0 || mi < -8.0 || mq > 8.0 || mq < -8.0)
            $fatal(1, "static DC not removed");

        // (c) bypass passes data unchanged.
        bypass = 1;
        @(negedge clk); s_tdata = 32'h1234_ABCD; s_tvalid = 1;
        @(posedge clk); #1;
        if (m_tdata !== 32'h1234_ABCD) $fatal(1, "bypass altered data");
        @(negedge clk); s_tvalid = 0;

        $display("TB_DC_CORRECTION_PASS");
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "dc_correction timeout");
    end
endmodule
