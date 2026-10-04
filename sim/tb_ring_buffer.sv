`timescale 1ns/1ps

module tb_ring_buffer;
    reg aclk = 0, sclk = 0;
    always #3 aclk = ~aclk;
    always #2 sclk = ~sclk;
    reg arst_n = 0, srst_n = 0;
    reg awready = 0, wready = 0, bvalid = 0;
    wire [31:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awvalid;
    wire [255:0] wdata;
    wire [31:0] wstrb;
    wire wlast, wvalid, bready;
    reg [31:0] sdata = 0;
    reg svalid = 0;
    wire sready;
    wire [31:0] wr_words, overflow_cnt;
    wire ring_full;
    wire axi_write_error;
    wire [25:0] rd_ptr;
    integer i, txn, j;
    reg [255:0] expected;
    reg [31:0] held_awaddr;
    reg [255:0] held_wdata;

    ring_buffer dut (
        .M_AXI_aclk(aclk), .M_AXI_aresetn(arst_n),
        .M_AXI_awid(), .M_AXI_awaddr(awaddr), .M_AXI_awlen(awlen),
        .M_AXI_awsize(awsize), .M_AXI_awburst(awburst), .M_AXI_awlock(),
        .M_AXI_awcache(), .M_AXI_awprot(), .M_AXI_awqos(),
        .M_AXI_awvalid(awvalid), .M_AXI_awready(awready),
        .M_AXI_wdata(wdata), .M_AXI_wstrb(wstrb), .M_AXI_wlast(wlast),
        .M_AXI_wvalid(wvalid), .M_AXI_wready(wready),
        .M_AXI_bresp(2'b00), .M_AXI_bvalid(bvalid), .M_AXI_bready(bready),
        .M_AXI_arid(), .M_AXI_araddr(), .M_AXI_arlen(), .M_AXI_arsize(),
        .M_AXI_arburst(), .M_AXI_arlock(), .M_AXI_arcache(),
        .M_AXI_arprot(), .M_AXI_arqos(), .M_AXI_arvalid(),
        .M_AXI_arready(1'b0), .M_AXI_rdata(256'd0), .M_AXI_rresp(2'b00),
        .M_AXI_rvalid(1'b0), .M_AXI_rready(),
        .s_clk(sclk), .rst_n(srst_n), .rec_enable(1'b1),
        .base_addr(32'h8000_0000), .ring_size(26'd2),
        .s_tdata(sdata), .s_tvalid(svalid), .s_tready(sready),
        .s_tlast(1'b0), .wr_words(wr_words), .overflow_cnt(overflow_cnt),
        .ring_full(ring_full), .axi_write_error(axi_write_error), .rd_ptr(rd_ptr)
    );

    initial begin : source
        repeat (5) @(posedge sclk);
        srst_n = 1;
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge sclk);
            sdata = 32'h1000_0000 + i;
            svalid = 1;
            do @(posedge sclk); while (!sready);
            @(negedge sclk); svalid = 0;
        end
    end

    initial begin : axi_slave
        repeat (5) @(posedge aclk);
        arst_n = 1;
        for (txn = 0; txn < 2; txn = txn + 1) begin
            wait (awvalid); #1;
            held_awaddr = awaddr;
            if (awaddr !== (32'h8000_0000 + txn*32) || awlen != 0 ||
                awsize != 3'b101 || awburst != 2'b01)
                $fatal(1, "bad AW transaction %0d addr=%h", txn, awaddr);
            repeat (3) begin
                @(posedge aclk); #1;
                if (!awvalid || awaddr !== held_awaddr)
                    $fatal(1, "AW changed while stalled");
            end
            @(negedge aclk); awready = 1;
            @(negedge aclk); awready = 0;

            wait (wvalid); #1;
            expected = 256'd0;
            for (j = 0; j < 8; j = j + 1)
                expected[j*32 +: 32] = 32'h1000_0000 + txn*8 + j;
            held_wdata = wdata;
            if (wdata !== expected || wstrb !== 32'hffff_ffff || !wlast)
                $fatal(1, "bad W transaction %0d data=%h", txn, wdata);
            repeat (2) begin
                @(posedge aclk); #1;
                if (!wvalid || wdata !== held_wdata || !wlast)
                    $fatal(1, "W changed while stalled");
            end
            @(negedge aclk); wready = 1;
            @(negedge aclk); wready = 0;
            repeat (2) @(posedge aclk);
            @(negedge aclk); bvalid = 1;
            @(negedge aclk); bvalid = 0;
        end

        repeat (8) @(posedge sclk); #1;
        if (wr_words !== 32'd2 || rd_ptr !== 26'd0 || overflow_cnt != 0)
            $fatal(1, "ring status mismatch words=%0d ptr=%0d ovf=%0d",
                   wr_words, rd_ptr, overflow_cnt);
        $display("TB_RING_BUFFER_PASS");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "ring buffer timeout");
    end
endmodule
