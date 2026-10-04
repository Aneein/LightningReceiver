`timescale 1ns/1ps

module tb_mode_and_mux;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg [1:0] mode_sel = 0;
    reg mode_load = 0;
    wire [1:0] mode_active;
    wire mode_changed, mode_valid;

    reg audio_enable = 1;
    reg raw_enable = 1;
    reg [31:0] s0_tdata = 32'hAAAA_0001;
    reg [15:0] s0_tuser = 16'h0011;
    reg s0_tvalid = 1;
    wire s0_tready;
    reg s0_tlast = 0;
    reg [31:0] s1_tdata = 32'hBBBB_0002;
    reg [15:0] s1_tuser = 16'h0022;
    reg s1_tvalid = 1;
    wire s1_tready;
    reg s1_tlast = 1;
    wire [31:0] m_tdata;
    wire [15:0] m_tuser;
    wire m_tvalid, m_tlast;
    reg m_tready = 0;
    wire [1:0] flow_sel;
    wire tx_enable;

    mode_manager u_mode (
        .clk(clk), .rst_n(rst_n), .mode_sel(mode_sel), .mode_load(mode_load),
        .mode_active(mode_active), .mode_changed(mode_changed),
        .mode_valid(mode_valid));

    lr_axis_stream_mux2 u_mux (
        .clk(clk), .rst_n(rst_n), .select_raw(mode_active[0]),
        .audio_enable(audio_enable), .raw_enable(raw_enable),
        .s0_tdata(s0_tdata), .s0_tuser(s0_tuser), .s0_tvalid(s0_tvalid),
        .s0_tready(s0_tready), .s0_tlast(s0_tlast),
        .s1_tdata(s1_tdata), .s1_tuser(s1_tuser), .s1_tvalid(s1_tvalid),
        .s1_tready(s1_tready), .s1_tlast(s1_tlast),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast), .flow_sel(flow_sel),
        .tx_enable(tx_enable));

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        repeat (2) @(posedge clk); #1;
        if (!mode_valid || flow_sel != 2'd3 || m_tdata != s0_tdata ||
            s0_tready || !s1_tready || !tx_enable)
            $fatal(1, "FM/audio selection failed");

        // Invalid modes are rejected.
        mode_sel <= 2'd2; mode_load <= 1;
        @(posedge clk); mode_load <= 0;
        @(posedge clk); #1;
        if (mode_active != 2'd0) $fatal(1, "invalid mode was accepted");

        // Valid mode changes at a load boundary and the registered mux control
        // follows on the next fabric clock.
        mode_sel <= 2'd1; mode_load <= 1;
        @(posedge clk); mode_load <= 0;
        repeat (2) @(posedge clk); #1;
        if (mode_active != 2'd1 || flow_sel != 2'd0 ||
            m_tdata != s1_tdata || !s0_tready || s1_tready || !m_tlast)
            $fatal(1, "General-SDR/raw selection failed");

        m_tready <= 1;
        @(posedge clk); #1;
        if (!s1_tready || !m_tvalid) $fatal(1, "raw handshake failed");

        raw_enable <= 0;
        @(posedge clk); #1;
        if (tx_enable) $fatal(1, "stream enable did not gate TX");
        $display("TB_MODE_AND_MUX_PASS");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "mode/mux timeout");
    end
endmodule
