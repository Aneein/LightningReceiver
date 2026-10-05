`timescale 1ns/1ps

// audio_pipeline: de-emphasis (50/75 us) + 191-tap anti-alias FIR + 4:1.
// Measures the actual frequency response against the digital de-emphasis
// model, the stop band (pilot / alias), gain, metadata and backpressure.
module tb_audio_pipeline;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg [31:0] sdata = 0;
    reg [15:0] suser = 0;
    reg svalid = 0, slast = 0;
    wire sready;
    wire [31:0] mdata;
    wire [15:0] muser;
    wire mvalid, mlast;
    reg mready = 1;
    reg [15:0] gain = 16'h7FFF;
    reg deemph_75us = 0;
    reg iq_mode = 0;

    localparam real PI = 3.14159265358979;
    localparam real FS = 192000.0;

    audio_pipeline dut (
        .clk(clk), .rst_n(rst_n), .gain(gain), .deemph_75us(deemph_75us),
        .iq_mode(iq_mode),
        .s_tdata(sdata), .s_tuser(suser), .s_tvalid(svalid),
        .s_tready(sready), .s_tlast(slast), .m_tdata(mdata),
        .m_tuser(muser), .m_tvalid(mvalid), .m_tready(mready),
        .m_tlast(mlast)
    );

    function integer rnd(input real v); rnd = $rtoi(v + ((v < 0.0) ? -0.5 : 0.5)); endfunction
    function real rabs(input real v); rabs = (v < 0.0) ? -v : v; endfunction

    // output capture
    integer n_out = 0;
    real out_buf [0:4095];
    real outq_buf [0:4095];
    always @(posedge clk)
        if (mvalid && mready) begin
            if (n_out < 4096) begin
                out_buf[n_out]  = $signed(mdata[31:16]);
                outq_buf[n_out] = $signed(mdata[15:0]);
            end
            n_out = n_out + 1;
        end

    task automatic send(input integer v, input [15:0] userv, input lastv);
        begin
            @(negedge clk);
            sdata = {16'(v), 16'd0}; suser = userv; slast = lastv; svalid = 1;
            do @(posedge clk); while (!sready);
            @(negedge clk); svalid = 0; slast = 0;
        end
    endtask

    // Drive N input samples of A*sin(2*pi*f*n/FS) + dc and return the
    // output amplitude at f (correlation over the settled part).
    task automatic tone(input real f, input real amp, input integer dc,
                        input integer n_in, output real a_out, output real mean_out);
        integer k, first, cnt;
        real si, co, ph, sum;
        begin
            n_out = 0;
            for (k = 0; k < n_in; k = k + 1)
                send(rnd(amp * $sin(2.0 * PI * f * k / FS)) + dc, 16'h0, 1'b0);
            repeat (400) @(posedge clk);
            first = 120;                      // FIR + de-emphasis settled
            cnt = n_out - first;
            si = 0; co = 0; sum = 0;
            for (k = first; k < n_out; k = k + 1) begin
                ph = 2.0 * PI * f * (4.0 * k) / FS;   // output k <-> input 4k+3
                si = si + out_buf[k] * $sin(ph);
                co = co + out_buf[k] * $cos(ph);
                sum = sum + out_buf[k];
            end
            a_out = 2.0 * $sqrt(si * si + co * co) / cnt;
            mean_out = sum / cnt;
        end
    endtask

    task automatic send_iq(input integer vi, input integer vq);
        begin
            @(negedge clk);
            sdata = {16'(vi), 16'(vq)}; suser = 0; slast = 0; svalid = 1;
            do @(posedge clk); while (!sready);
            @(negedge clk); svalid = 0;
        end
    endtask

    // IQ mode: complex tone A*exp(j*2*pi*f*n/FS) (f may be negative).
    // Returns the output amplitude at +f and at the image -f.
    task automatic ctone(input real f, input real amp, input integer n_in,
                         output real a_out, output real a_img);
        integer k, first, cnt;
        real ph, re, im, ire, iim;
        begin
            n_out = 0;
            for (k = 0; k < n_in; k = k + 1)
                send_iq(rnd(amp * $cos(2.0 * PI * f * k / FS)),
                        rnd(amp * $sin(2.0 * PI * f * k / FS)));
            repeat (400) @(posedge clk);
            first = 120;
            cnt = n_out - first;
            re = 0; im = 0; ire = 0; iim = 0;
            for (k = first; k < n_out; k = k + 1) begin
                ph = 2.0 * PI * f * (4.0 * k) / FS;
                // z * exp(-j ph) and z * exp(+j ph)
                re  = re  + out_buf[k] * $cos(ph) + outq_buf[k] * $sin(ph);
                im  = im  + outq_buf[k] * $cos(ph) - out_buf[k] * $sin(ph);
                ire = ire + out_buf[k] * $cos(ph) - outq_buf[k] * $sin(ph);
                iim = iim + outq_buf[k] * $cos(ph) + out_buf[k] * $sin(ph);
            end
            a_out = $sqrt(re * re + im * im) / cnt;
            a_img = $sqrt(ire * ire + iim * iim) / cnt;
        end
    endtask

    task automatic check_iq(input real f, input real amp, input integer is_stop);
        real a_o, a_i;
        begin
            ctone(f, amp, 2400, a_o, a_i);
            $display("IQ %7.0f Hz: out %8.2f  image %6.2f", f, a_o, a_i);
            if (is_stop) begin
                if (a_o > amp * 1.06e-3 || a_i > amp * 1.06e-3)   // spec: >= 59.5 dB
                    $fatal(1, "IQ stop band leak at %0.0f Hz", f);
            end else begin
                if (rabs(a_o - amp) > 0.01 * amp + 2.0) $fatal(1, "IQ pass band wrong at %0.0f Hz", f);
                if (a_i > 3.0) $fatal(1, "IQ image at %0.0f Hz: %0.2f", f, a_i);
            end
        end
    endtask

    function real deem_mag(input real f, input real a);
        real w;
        begin
            w = 2.0 * PI * f / FS;
            deem_mag = (1.0 - a) / $sqrt(1.0 - 2.0 * a * $cos(w) + a * a);
        end
    endfunction

    task automatic check_pass(input real f, input real a_coef);
        real a_out, m, exp_a;
        begin
            tone(f, 8000.0, 0, 2400, a_out, m);
            exp_a = 8000.0 * deem_mag(f, a_coef);
            $display("%6.0f Hz: out %8.1f  expected %8.1f  (%s)", f, a_out, exp_a,
                     deemph_75us ? "75us" : "50us");
            if (rabs(a_out - exp_a) > 0.02 * exp_a + 2.0)
                $fatal(1, "pass-band response wrong at %0.0f Hz", f);
        end
    endtask

    task automatic check_stop(input real f);
        real a_out, m;
        begin
            tone(f, 8000.0, 0, 2400, a_out, m);
            $display("%6.0f Hz: out %8.2f LSB (stop band)", f, a_out);
            if (a_out > 3.0) $fatal(1, "stop band leak at %0.0f Hz", f);
        end
    endtask

    real a_out, m;
    integer k;
    reg [31:0] held_data;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;

        // DC gain = 1 (gain 0x7FFF ~ 0.99997)
        tone(1000.0, 0.0, 1000, 1200, a_out, m);
        $display("DC 1000 -> mean %0.2f", m);
        if (rabs(m - 1000.0) > 1.5) $fatal(1, "DC gain wrong: %0.2f", m);
        // 4:1 decimation
        if (n_out != 300) $fatal(1, "4:1 rate wrong: %0d outputs for 1200 inputs", n_out);

        // pass band, 50 us (China) and 75 us
        check_pass(1000.0, 29526.0 / 32768.0);
        check_pass(10000.0, 29526.0 / 32768.0);
        deemph_75us = 1;
        check_pass(1000.0, 30569.0 / 32768.0);
        deemph_75us = 0;

        // stop band: stereo pilot and a tone that would alias to 8 kHz
        check_stop(19000.0);
        check_stop(40000.0);

        // gain 0.5
        gain = 16'h4000;
        tone(1000.0, 0.0, 1000, 1200, a_out, m);
        if (rabs(m - 500.0) > 1.5) $fatal(1, "gain scaling wrong: %0.2f", m);
        gain = 16'h7FFF;

        // metadata of the 4th sample, OR of tlast over the group, backpressure
        n_out = 0;
        send(1000, 16'h1, 0);
        send(1000, 16'h2, 1);
        send(1000, 16'h3, 0);
        mready = 0;
        send(1000, 16'h4, 0);
        wait (mvalid); #1;
        held_data = mdata;
        if (mdata[15:0] != 0 || muser != 16'h4 || !mlast)
            $fatal(1, "audio output/metadata mismatch: %h user %h last %b", mdata, muser, mlast);
        repeat (4) begin
            @(posedge clk); #1;
            if (!mvalid || mdata !== held_data)
                $fatal(1, "audio output changed under backpressure");
        end
        mready = 1;
        @(posedge clk); #1;
        if (mvalid) $fatal(1, "audio valid did not clear");

        // FM mode ignores the Q input: m_tdata[15:0] stays 0
        n_out = 0;
        repeat (8) send_iq(1000, 1234);
        repeat (400) @(posedge clk);
        if (n_out != 2 || outq_buf[0] != 0.0 || outq_buf[1] != 0.0)
            $fatal(1, "FM mode leaked Q to the output");

        // ---------------- narrowband IQ mode ----------------
        iq_mode = 1;
        // DC on I and Q passes with unity gain, no de-emphasis
        n_out = 0;
        for (k = 0; k < 1200; k = k + 1) send_iq(1000, -500);
        repeat (400) @(posedge clk);
        if (n_out != 300) $fatal(1, "IQ 4:1 rate wrong: %0d", n_out);
        if (rabs(out_buf[299] - 1000.0) > 1.5 || rabs(outq_buf[299] + 500.0) > 1.5)
            $fatal(1, "IQ DC wrong: I %0.2f Q %0.2f", out_buf[299], outq_buf[299]);
        // positive / negative offsets keep their sign (no image), flat to 10 kHz
        check_iq(5000.0, 8000.0, 0);
        check_iq(-5000.0, 8000.0, 0);
        check_iq(10000.0, 8000.0, 0);
        check_iq(-1200.0, 8000.0, 0);
        // stop band and alias protection at the 48 kS/s complex rate
        check_iq(20000.0, 8000.0, 1);
        check_iq(-40000.0, 8000.0, 1);
        iq_mode = 0;

        $display("TB_AUDIO_PIPELINE_PASS");
        $finish;
    end

    initial begin
        #50_000_000;
        $fatal(1, "audio pipeline timeout");
    end
endmodule
