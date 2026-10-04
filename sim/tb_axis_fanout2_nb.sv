`timescale 1ns/1ps

// Non-blocking fan-out: a stalled branch must never affect the other one.
module tb_axis_fanout2_nb;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg en0 = 1, en1 = 1, mute = 0;
    reg [31:0] s_tdata = 0;
    reg s_tvalid = 0;
    wire s_tready;
    wire [31:0] m0_tdata, m1_tdata;
    wire [15:0] m0_tuser, m1_tuser;
    wire m0_tvalid, m1_tvalid, m0_tlast, m1_tlast;
    reg m0_tready = 1, m1_tready = 1;
    wire [15:0] drop0_count, drop1_count;
    wire drop0_pulse, drop1_pulse;

    axis_fanout2_nb dut (
        .clk(clk), .rst_n(rst_n), .en0(en0), .en1(en1), .mute(mute),
        .s_tdata(s_tdata), .s_tuser(16'h0042), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(1'b0),
        .m0_tdata(m0_tdata), .m0_tuser(m0_tuser), .m0_tvalid(m0_tvalid),
        .m0_tready(m0_tready), .m0_tlast(m0_tlast),
        .m1_tdata(m1_tdata), .m1_tuser(m1_tuser), .m1_tvalid(m1_tvalid),
        .m1_tready(m1_tready), .m1_tlast(m1_tlast),
        .drop0_count(drop0_count), .drop1_count(drop1_count),
        .drop0_pulse(drop0_pulse), .drop1_pulse(drop1_pulse));

    integer n0 = 0, n1 = 0;
    reg [31:0] last0, last1;
    always @(posedge clk) begin
        if (m0_tvalid && m0_tready) begin n0 <= n0 + 1; last0 <= m0_tdata; end
        if (m1_tvalid && m1_tready) begin n1 <= n1 + 1; last1 <= m1_tdata; end
        if (s_tready !== 1'b1) $fatal(1, "fan-out must never backpressure");
    end

    task send(input [31:0] d);
        begin
            @(negedge clk); s_tdata = d; s_tvalid = 1;
            @(negedge clk); s_tvalid = 0;
            repeat (3) @(posedge clk);
            @(negedge clk);     // all stimulus changes happen on negedges
        end
    endtask

    integer k;
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;

        // Both branches deliver every word.
        for (k = 0; k < 4; k = k + 1) send(32'h1000_0000 + k);
        repeat (2) @(posedge clk);
        if (n0 != 4 || n1 != 4 || last0 != 32'h1000_0003 || last1 != 32'h1000_0003)
            $fatal(1, "broadcast failed n0=%0d n1=%0d", n0, n1);

        // Network branch stalls (CMAC down): DDR branch unaffected.
        @(negedge clk); m1_tready = 0;
        for (k = 0; k < 10; k = k + 1) send(32'h2000_0000 + k);
        repeat (2) @(posedge clk);
        if (n0 != 14 || last0 != 32'h2000_0009)
            $fatal(1, "stalled m1 disturbed m0 (n0=%0d)", n0);
        if (drop1_count != 9 || drop0_count != 0)
            $fatal(1, "drop accounting wrong: d0=%0d d1=%0d", drop0_count, drop1_count);
        if (!m1_tvalid || m1_tdata != 32'h2000_0000)
            $fatal(1, "m1 lost its held word");
        @(negedge clk); m1_tready = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);

        // Disabled branch: silent discard, no error count.
        en1 = 0;
        for (k = 0; k < 3; k = k + 1) send(32'h3000_0000 + k);
        if (drop1_count != 9 || n1 != 5)
            $fatal(1, "disabled branch misbehaved d1=%0d n1=%0d", drop1_count, n1);
        en1 = 1;

        // Mute zeros the data but keeps every sample slot.
        mute = 1;
        send(32'h7FFF_0000);
        repeat (2) @(posedge clk);
        if (last0 !== 32'd0 || last1 !== 32'd0 || n0 != 18 || n1 != 6)
            $fatal(1, "mute failed");
        mute = 0;

        $display("TB_AXIS_FANOUT2_NB_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "fanout timeout");
    end
endmodule
