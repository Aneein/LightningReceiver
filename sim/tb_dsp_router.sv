`timescale 1ns/1ps
`include "lr_defines.vh"

module tb_dsp_router;
    reg clk = 0;
    always #2 clk = ~clk;

    reg rst_n = 0;
    reg [31:0] s_tdata = 0;
    reg [15:0] s_tuser = 0;
    reg s_tvalid = 0;
    wire s_tready;
    reg s_tlast = 0;
    reg [3:0] en_mask = 4'b1111;
    reg m0_tready = 0, m1_tready = 0, m2_tready = 0, m3_tready = 0;
    wire [31:0] m0_tdata, m1_tdata, m2_tdata, m3_tdata;
    wire [15:0] m0_tuser, m1_tuser, m2_tuser, m3_tuser;
    wire m0_tvalid, m1_tvalid, m2_tvalid, m3_tvalid;
    wire m0_tlast, m1_tlast, m2_tlast, m3_tlast;
    wire [31:0] drop_count;
    wire drop_event;
    integer c0 = 0, c1 = 0, c2 = 0, c3 = 0;

    dsp_router dut (.*);

    always @(posedge clk) begin
        if (m0_tvalid && m0_tready) c0 <= c0 + 1;
        if (m1_tvalid && m1_tready) c1 <= c1 + 1;
        if (m2_tvalid && m2_tready) c2 <= c2 + 1;
        if (m3_tvalid && m3_tready) c3 <= c3 + 1;
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        s_tdata <= 32'h1234_5678;
        s_tuser <= 16'h55AA;
        s_tlast <= 1;
        s_tvalid <= 1;
        m0_tready <= 1;
        m1_tready <= 0;
        m2_tready <= 0;
        m3_tready <= 0;
        do @(posedge clk); while (!s_tready);
        s_tvalid <= 0;

        // Branch 0 stays ready for several cycles while branches 1/2 stall.
        // It must still consume the transaction exactly once.
        wait (c0 == 1);
        repeat (2) @(posedge clk);
        if (c0 != 1 || c1 != 0 || c2 != 0 || c3 != 0)
            $fatal(1, "early branch duplicated: %0d %0d %0d %0d", c0, c1, c2, c3);
        m1_tready <= 1;
        wait (c1 == 1);
        repeat (2) @(posedge clk);
        if (c0 != 1 || c1 != 1 || c2 != 0 || c3 != 0)
            $fatal(1, "middle branch mismatch: %0d %0d %0d %0d", c0, c1, c2, c3);
        m2_tready <= 1;
        wait (c2 == 1);
        repeat (2) @(posedge clk);
        if (c0 != 1 || c1 != 1 || c2 != 1 || c3 != 0)
            $fatal(1, "third branch mismatch: %0d %0d %0d %0d", c0, c1, c2, c3);
        m3_tready <= 1;
        wait (c3 == 1);
        repeat (2) @(posedge clk);
        if (c0 != 1 || c1 != 1 || c2 != 1 || c3 != 1)
            $fatal(1, "final branch mismatch: %0d %0d %0d %0d", c0, c1, c2, c3);

        // Disabled fanout intentionally drops one accepted input.
        en_mask <= 4'b0000;
        s_tvalid <= 1;
        s_tlast <= 0;
        @(posedge clk);
        s_tvalid <= 0;
        @(posedge clk);
        if (drop_count != 1) $fatal(1, "drop counter mismatch");
        $display("TB_DSP_ROUTER_PASS");
        $finish;
    end
endmodule
