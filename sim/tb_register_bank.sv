`timescale 1ns/1ps

module tb_register_bank;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;

    reg [11:0] awaddr = 0;
    reg awvalid = 0;
    wire awready;
    reg [31:0] wdata = 0;
    reg wvalid = 0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready = 0;
    reg [11:0] araddr = 0;
    reg arvalid = 0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready = 0;

    wire [31:0] reg_control, reg_rf_freq, reg_rf_gain, reg_rf_bw_rate;
    wire [31:0] reg_ddc_freq, reg_fft_cfg, reg_spec_cfg, reg_det_cfg;
    wire [31:0] reg_audio_cfg, reg_ddr_mode;
    wire [23:0] spi_tx_data;
    wire spi_start;
    wire [1:0] reg_mode;
    wire [5:0] reg_stream_en;
    wire [15:0] reg_decim;
    reg [31:0] status_in = 32'h1234_5678;
    wire [5:0] tele_addr;
    wire wr_strobe;
    reg cfg_wr_valid = 0, cfg_rd_valid = 0;
    reg [11:0] cfg_wr_addr = 0, cfg_rd_addr = 0;
    reg [31:0] cfg_wr_data = 0;
    wire [31:0] cfg_rd_data;
    wire [31:0] reg_seek_cfg, reg_seek_thr;
    wire seek_cmd_valid, ddc_bus_wr, err_clear;
    wire [1:0] seek_cmd;
    reg ui_rec_toggle = 0, ui_net_toggle = 0, int_ddc_valid = 0;
    reg [31:0] int_ddc_data = 0;
    integer n_seek = 0, n_errclr = 0, n_ddcwr = 0;
    reg [1:0] last_seek_cmd = 0;
    always @(posedge clk) begin
        if (seek_cmd_valid) begin n_seek <= n_seek + 1; last_seek_cmd <= seek_cmd; end
        if (err_clear) n_errclr <= n_errclr + 1;
        if (ddc_bus_wr) n_ddcwr <= n_ddcwr + 1;
    end

    register_bank dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready), .reg_control(reg_control), .reg_mode(reg_mode),
        .reg_rf_freq(reg_rf_freq), .reg_rf_gain(reg_rf_gain),
        .reg_rf_bw_rate(reg_rf_bw_rate), .reg_stream_en(reg_stream_en),
        .reg_ddc_freq(reg_ddc_freq), .reg_decim(reg_decim),
        .reg_fft_cfg(reg_fft_cfg), .reg_spec_cfg(reg_spec_cfg),
        .reg_det_cfg(reg_det_cfg), .reg_audio_cfg(reg_audio_cfg),
        .reg_ddr_mode(reg_ddr_mode), .status_in(status_in),
        .spi_tx_data(spi_tx_data), .spi_start(spi_start),
        .spi_rx_data(24'hABCDEF), .spi_busy(1'b0), .spi_done(1'b1),
        .rf_status_in(32'h22), .ddr_status_in(32'h33),
        .net_status_in(32'h44), .err_status_in(32'h55),
        .uptime_in(32'h66), .det_event_in(64'h1122_3344_5566_7788),
        .audio_status_in(32'h89AB_CDEF), .audio_wr_words_in(32'h0001_2345),
        .audio_ring_base_in(32'hFF00_0000), .audio_ring_words_in(32'h0000_8000),
        .audio_rec_start_in(32'h0000_0078), .ui_status_in(32'h0000_007C),
        .seek_status_in(32'h0000_0080), .sig_power_in(32'h0000_0088),
        .sig_quality_in(32'h0000_008C),
        .reg_seek_cfg(reg_seek_cfg), .reg_seek_thr(reg_seek_thr),
        .seek_cmd_valid(seek_cmd_valid), .seek_cmd(seek_cmd),
        .ddc_bus_wr(ddc_bus_wr), .err_clear(err_clear),
        .ui_rec_toggle(ui_rec_toggle), .ui_net_toggle(ui_net_toggle),
        .int_ddc_valid(int_ddc_valid), .int_ddc_data(int_ddc_data),
        .tele_rdata(32'hCAFE_BABE),
        .tele_addr(tele_addr), .wr_strobe(wr_strobe),
        .cfg_wr_valid(cfg_wr_valid), .cfg_wr_addr(cfg_wr_addr),
        .cfg_wr_data(cfg_wr_data), .cfg_rd_valid(cfg_rd_valid),
        .cfg_rd_addr(cfg_rd_addr), .cfg_rd_data(cfg_rd_data)
    );

    task automatic finish_b;
        begin
            wait (bvalid);
            if (bresp != 2'b00) $fatal(1, "bad BRESP");
            @(negedge clk); bready = 1;
            @(negedge clk); bready = 0;
        end
    endtask

    task automatic write_aw_first(input [11:0] addr, input [31:0] data);
        begin
            @(negedge clk); awaddr = addr; awvalid = 1;
            do @(posedge clk); while (!awready);
            @(negedge clk); awvalid = 0;
            repeat (3) @(posedge clk);
            @(negedge clk); wdata = data; wvalid = 1;
            do @(posedge clk); while (!wready);
            @(negedge clk); wvalid = 0;
            finish_b();
        end
    endtask

    task automatic write_w_first(input [11:0] addr, input [31:0] data);
        begin
            @(negedge clk); wdata = data; wvalid = 1;
            do @(posedge clk); while (!wready);
            @(negedge clk); wvalid = 0;
            repeat (2) @(posedge clk);
            @(negedge clk); awaddr = addr; awvalid = 1;
            do @(posedge clk); while (!awready);
            @(negedge clk); awvalid = 0;
            finish_b();
        end
    endtask

    task automatic read_check(input [11:0] addr, input [31:0] expected);
        begin
            @(negedge clk); araddr = addr; arvalid = 1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 0;
            wait (rvalid); #1;
            if (rdata !== expected || rresp != 2'b00)
                $fatal(1, "read %h got %h expected %h", addr, rdata, expected);
            @(negedge clk); rready = 1;
            @(negedge clk); rready = 0;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        #1;
        if (reg_rf_freq != 32'd98_000_000 || reg_decim != 16'd320 ||
            reg_audio_cfg != 32'h0002_7fff || reg_seek_cfg != {16'd10000, 16'd100} ||
            reg_seek_thr != 32'h0000_0140)
            $fatal(1, "register defaults mismatch");

        write_aw_first(12'h024, 32'hFEDC_BA98);
        if (reg_ddc_freq !== 32'hFEDC_BA98)
            $fatal(1, "AW-first write failed");

        write_w_first(12'h038, 32'h0000_4321);
        if (reg_audio_cfg !== 32'h0000_4321)
            $fatal(1, "W-first write failed");

        read_check(12'h000, 32'h4C52_0004);
        read_check(12'h004, 32'h1234_5678);
        read_check(12'h024, 32'hFEDC_BA98);
        read_check(12'h038, 32'h0000_4321);
        write_aw_first(12'h050, 32'h00A5_5A3C);
        if (spi_tx_data !== 24'hA5_5A3C) $fatal(1, "SPI TX write failed");
        read_check(12'h054, 32'h00AB_CDEF);
        read_check(12'h058, 32'h0000_0002);
        read_check(12'h060, 32'h5566_7788);
        read_check(12'h064, 32'h1122_3344);
        read_check(12'h068, 32'h89AB_CDEF);
        read_check(12'h06C, 32'h0001_2345);
        read_check(12'h070, 32'hFF00_0000);
        read_check(12'h074, 32'h0000_8000);

        @(negedge clk);
        cfg_wr_addr = 12'h00c;
        cfg_wr_data = 32'h0000_0002;
        cfg_wr_valid = 1;
        @(negedge clk); cfg_wr_valid = 0;
        if (reg_mode !== 2'd2) $fatal(1, "cfg write failed");

        cfg_rd_addr = 12'h00c;
        cfg_rd_valid = 1;
        @(posedge clk); #1;
        cfg_rd_valid = 0;
        if (cfg_rd_data !== 32'h0000_0002) $fatal(1, "cfg read failed");

        // ---- FM Phase-1 registers ----
        read_check(12'h078, 32'h0000_0078);
        read_check(12'h07C, 32'h0000_007C);
        read_check(12'h080, 32'h0000_0080);
        read_check(12'h084, {16'd10000, 16'd100});
        read_check(12'h088, 32'h0000_0088);
        read_check(12'h08C, 32'h0000_008C);
        read_check(12'h090, 32'h0000_0140);

        // SEEK_CTRL write is a command pulse; 0 is ignored.
        write_aw_first(12'h080, 32'd1);
        write_aw_first(12'h080, 32'd0);
        write_aw_first(12'h080, 32'd3);
        if (n_seek != 2 || last_seek_cmd != 2'd3) $fatal(1, "seek command pulses wrong");

        // CONTROL.ERR_CLEAR self-clears; other bits are kept.
        write_aw_first(12'h008, 32'h0000_0007);
        if (n_errclr != 1 || reg_control !== 32'h0000_0003)
            $fatal(1, "ERR_CLEAR handling wrong: %h", reg_control);

        // Front-panel toggles and internal tuning.
        @(negedge clk); ui_rec_toggle = 1; @(negedge clk); ui_rec_toggle = 0;
        @(negedge clk);
        if (reg_audio_cfg[16] !== 1'b1) $fatal(1, "REC toggle failed");
        @(negedge clk); ui_net_toggle = 1; @(negedge clk); ui_net_toggle = 0;
        @(negedge clk);
        if (reg_audio_cfg[17] !== 1'b1) $fatal(1, "NET toggle failed (W-first value had 0)");
        @(negedge clk); int_ddc_valid = 1; int_ddc_data = 32'd1_200_000;
        @(negedge clk); int_ddc_valid = 0;
        if (reg_ddc_freq !== 32'd1_200_000) $fatal(1, "internal tuning failed");

        // Same-cycle host write to DDC_FREQ beats the internal request.
        @(negedge clk);
        cfg_wr_addr = 12'h024; cfg_wr_data = 32'd7_000_000; cfg_wr_valid = 1;
        int_ddc_valid = 1; int_ddc_data = 32'd5_500_000;
        @(negedge clk); cfg_wr_valid = 0; int_ddc_valid = 0;
        repeat (3) @(negedge clk);
        if (reg_ddc_freq !== 32'd7_000_000) $fatal(1, "host lost to internal tuning");
        // one AXI write (AW-first test) + this UART write
        if (n_ddcwr != 2) $fatal(1, "ddc_bus_wr count wrong (%0d)", n_ddcwr);

        // Same-cycle host write to AUDIO_CFG: toggle applied on top, next cycle.
        @(negedge clk);
        cfg_wr_addr = 12'h038; cfg_wr_data = 32'h0001_1111; cfg_wr_valid = 1;
        ui_rec_toggle = 1;
        @(negedge clk); cfg_wr_valid = 0; ui_rec_toggle = 0;
        @(negedge clk);
        if (reg_audio_cfg !== 32'h0000_1111)
            $fatal(1, "deferred toggle wrong: %h", reg_audio_cfg);

        $display("TB_REGISTER_BANK_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "register bank timeout");
    end
endmodule
