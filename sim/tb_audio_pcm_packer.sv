`timescale 1ns/1ps

module tb_audio_pcm_packer;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg enable = 0;
    reg iq_mode = 0;
    reg [31:0] s_tdata = 0;
    reg [15:0] s_tuser = 0;
    reg s_tvalid = 0;
    reg s_tlast = 0;
    wire s_tready;
    wire [31:0] m_tdata;
    wire m_tvalid, m_tlast;
    reg m_tready = 1;
    wire [31:0] drop_count;
    wire word_pulse, drop_pulse;
    integer n_drop_pulse = 0;
    always @(posedge clk) if (drop_pulse) n_drop_pulse <= n_drop_pulse + 1;
    wire rec_active;
    wire rec_iq;
    wire [31:0] rec_start_words;

    audio_pcm_packer dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .iq_mode(iq_mode),
        .s_tdata(s_tdata), .s_tuser(s_tuser), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(s_tlast),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
        .m_tlast(m_tlast), .drop_count(drop_count), .drop_pulse(drop_pulse), .word_pulse(word_pulse),
        .rec_active(rec_active), .rec_iq(rec_iq), .rec_start_words(rec_start_words));

    integer words = 0;
    reg [31:0] got [0:63];
    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            got[words] <= m_tdata;
            words <= words + 1;
        end
        if (s_tready !== 1'b1) $fatal(1, "packer must never backpressure");
    end

    task send(input [15:0] pcm);
        begin
            @(negedge clk);
            s_tdata = {pcm, 16'h0000};
            s_tvalid = 1;
            @(negedge clk);
            s_tvalid = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    task send_iq(input [15:0] i_s, input [15:0] q_s);
        begin
            @(negedge clk);
            s_tdata = {i_s, q_s};
            s_tvalid = 1;
            @(negedge clk);
            s_tvalid = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    integer k;
    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(negedge clk);

        // Idle: samples are accepted and discarded.
        send(16'h1111);
        repeat (2) @(negedge clk);
        if (words != 0 || rec_active) $fatal(1, "idle packer produced output");

        // ---- session 1 ----
        enable = 1;
        repeat (3) @(negedge clk);
        if (!rec_active || rec_start_words != 0) $fatal(1, "session 1 start wrong");
        send(16'h0001); send(16'hFFFE);   // word 0
        send(16'h1234); send(16'h8000);   // word 1
        repeat (4) @(negedge clk);
        if (words != 2) $fatal(1, "expected 2 packed words, got %0d", words);
        if (got[0] != 32'hFFFE_0001) $fatal(1, "word0 order wrong: %h", got[0]);
        if (got[1] != 32'h8000_1234) $fatal(1, "word1 order wrong: %h", got[1]);

        // Ring stalled: the next completed pair is dropped and counted.
        m_tready = 0;
        send(16'h0A0A); send(16'h0B0B);   // held in output register (word 2)
        send(16'h0C0C); send(16'h0D0D);   // dropped
        if (drop_count != 1 || n_drop_pulse != 1)
            $fatal(1, "drop not counted: %0d/%0d", drop_count, n_drop_pulse);
        m_tready = 1;
        repeat (3) @(negedge clk);
        if (words != 3 || got[2] != 32'h0B0B_0A0A)
            $fatal(1, "stalled word lost or corrupted");

        // Stop mid-pair with the ring stalled: odd sample closed with silence,
        // then zero padding to 8 words.  Padding waits, it is never dropped.
        send(16'h5555);
        m_tready = 0;
        enable = 0;
        repeat (20) @(negedge clk);
        if (words != 3 || !rec_active) $fatal(1, "flush must wait for the ring");
        m_tready = 1;
        repeat (20) @(negedge clk);
        if (words != 8) $fatal(1, "session not padded to 8 words: %0d", words);
        if (got[3] != 32'h0000_5555) $fatal(1, "odd sample not closed: %h", got[3]);
        for (k = 4; k < 8; k = k + 1)
            if (got[k] != 32'd0) $fatal(1, "pad word %0d not zero", k);
        if (rec_active) $fatal(1, "session did not close");
        if (drop_count != 1) $fatal(1, "padding was counted as drops");

        // Samples while idle are ignored.
        send(16'h9999); send(16'h9999);
        if (words != 8) $fatal(1, "idle samples recorded");

        // ---- session 2 starts on ring word 1 ----
        enable = 1;
        repeat (3) @(negedge clk);
        if (rec_start_words != 1) $fatal(1, "session 2 start = %0d", rec_start_words);
        send(16'h6666); send(16'h7777);
        repeat (4) @(negedge clk);
        if (words != 9 || got[8] != 32'h7777_6666)
            $fatal(1, "session 2 data wrong: %h", got[8]);

        // Immediate re-enable during a flush finishes the flush first.
        enable = 0;
        @(negedge clk); @(negedge clk);
        enable = 1;
        repeat (20) @(negedge clk);
        if (words != 16 || !rec_active || rec_start_words != 2)
            $fatal(1, "re-enable during flush: words=%0d start=%0d", words, rec_start_words);

        // ---- IQ mode: latched at session start only ----
        if (rec_iq) $fatal(1, "FM session reported as IQ");
        iq_mode = 1;                       // must not affect the running session
        send(16'h0101); send(16'h0202);
        repeat (4) @(negedge clk);
        if (words != 17 || got[16] != 32'h0202_0101 || rec_iq)
            $fatal(1, "mode switch leaked into running FM session");
        enable = 0;
        repeat (20) @(negedge clk);
        if (words != 24 || rec_active) $fatal(1, "FM session 3 flush: %0d", words);

        enable = 1;                        // session 4 starts in IQ format
        repeat (3) @(negedge clk);
        if (!rec_iq || rec_start_words != 3) $fatal(1, "IQ session start wrong");
        send_iq(16'h1111, 16'h2222);
        send_iq(16'h8001, 16'h7FFE);
        repeat (4) @(negedge clk);
        if (words != 26) $fatal(1, "IQ: one word per complex sample, got %0d", words);
        if (got[24] != 32'h2222_1111 || got[25] != 32'h7FFE_8001)
            $fatal(1, "IQ word layout wrong: %h %h", got[24], got[25]);
        // stalled ring: held sample survives, next one is dropped and counted
        m_tready = 0;
        send_iq(16'h0A0A, 16'h0B0B);
        send_iq(16'h0C0C, 16'h0D0D);
        if (drop_count != 2) $fatal(1, "IQ drop not counted: %0d", drop_count);
        m_tready = 1;
        repeat (3) @(negedge clk);
        if (words != 27 || got[26] != 32'h0B0B_0A0A) $fatal(1, "IQ stalled word lost");
        iq_mode = 0;                       // still IQ until the session ends
        send_iq(16'h3333, 16'h4444);
        repeat (4) @(negedge clk);
        if (words != 28 || got[27] != 32'h4444_3333 || !rec_iq)
            $fatal(1, "IQ session changed format mid-session");
        enable = 0;
        repeat (20) @(negedge clk);
        if (words != 32 || rec_active) $fatal(1, "IQ session not padded: %0d", words);
        for (k = 28; k < 32; k = k + 1)
            if (got[k] != 32'd0) $fatal(1, "IQ pad word %0d not zero", k);
        if (!rec_iq) $fatal(1, "rec_iq must describe the last session");

        $display("TB_AUDIO_PCM_PACKER_PASS");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "audio packer timeout");
    end
endmodule
