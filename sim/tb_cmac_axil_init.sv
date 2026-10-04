`timescale 1ns/1ps

module tb_cmac_axil_init;
    logic clk = 0;
    logic rstn = 0;
    always #5 clk = ~clk;

    wire [31:0] awaddr, wdata;
    wire [2:0] awprot, arprot;
    wire [3:0] wstrb;
    wire awvalid, wvalid, bready;
    wire [31:0] araddr;
    wire arvalid, rready;
    logic awready = 1, wready = 1;
    logic [1:0] bresp = 0;
    logic bvalid = 0;
    wire init_done, init_error;
    wire [3:0] init_step;

    cmac_axil_init #(.CLK_HZ(100), .CMAC_BASE(32'h44A1_0000)) dut (
        .M_AXI_aclk(clk), .M_AXI_aresetn(rstn),
        .M_AXI_awaddr(awaddr), .M_AXI_awprot(awprot),
        .M_AXI_awvalid(awvalid), .M_AXI_awready(awready),
        .M_AXI_wdata(wdata), .M_AXI_wstrb(wstrb),
        .M_AXI_wvalid(wvalid), .M_AXI_wready(wready),
        .M_AXI_bresp(bresp), .M_AXI_bvalid(bvalid), .M_AXI_bready(bready),
        .M_AXI_araddr(araddr), .M_AXI_arprot(arprot),
        .M_AXI_arvalid(arvalid), .M_AXI_arready(1'b0),
        .M_AXI_rdata(32'd0), .M_AXI_rresp(2'd0),
        .M_AXI_rvalid(1'b0), .M_AXI_rready(rready),
        .init_done(init_done), .init_error(init_error), .init_step(init_step)
    );

    logic [31:0] got_addr [0:6];
    logic [31:0] got_data [0:6];
    logic [31:0] held_addr, held_data;
    logic have_aw, have_w;
    integer count = 0;

    always @(posedge clk) begin
        bvalid <= 0;
        if (awvalid && awready) begin
            held_addr <= awaddr;
            have_aw <= 1;
        end
        if (wvalid && wready) begin
            held_data <= wdata;
            have_w <= 1;
        end
        if (have_aw && have_w && !bvalid) begin
            got_addr[count] <= held_addr;
            got_data[count] <= held_data;
            count <= count + 1;
            bvalid <= 1;
            have_aw <= 0;
            have_w <= 0;
        end
    end

    task check(input integer n, input logic [31:0] a, input logic [31:0] d);
        if (got_addr[n] !== a || got_data[n] !== d)
            $fatal(1, "write[%0d] got %08x=%08x expected %08x=%08x",
                   n, got_addr[n], got_data[n], a, d);
    endtask

    initial begin
        have_aw = 0;
        have_w = 0;
        repeat (4) @(posedge clk);
        rstn <= 1;
        wait (init_done);
        repeat (3) @(posedge clk);
        if (init_error || count != 7)
            $fatal(1, "init_error=%0d write_count=%0d", init_error, count);
        check(0, 32'h44A1_1000, 32'h0000_0007);
        check(1, 32'h44A1_107C, 32'h0000_0003);
        check(2, 32'h44A1_0004, 32'hC000_0000);
        check(3, 32'h44A1_0004, 32'h0000_0000);
        check(4, 32'h44A1_0014, 32'h0000_0001);
        check(5, 32'h44A1_000C, 32'h0000_0010);
        check(6, 32'h44A1_000C, 32'h0000_0001);
        $display("TB_PASS cmac_axil_init");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "timeout step=%0d count=%0d", init_step, count);
    end
endmodule
