`timescale 1ns/1ps

module tb_audio_pcm_packer;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg enable = 0;
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
    wire [31:0] rec_start_words;

    audio_pcm_packer dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .s_tdata(s_tdata), .s_tuser(s_tuser), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(s_tlast),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
        .m_tlast(m_tlast), .drop_count(drop_count), .drop_pulse(drop_pulse), .word_pulse(word_pulse),
        .rec_active(rec_active), .rec_start_words(rec_start_words));

    integer words = 0;
    reg [31:0] got [0:31];
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

        $display("TB_AUDIO_PCM_PACKER_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "audio packer timeout");
    end
endmodule
