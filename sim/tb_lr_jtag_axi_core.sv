`timescale 1ns/1ps

// lr_jtag_axi_core: BSCAN DR protocol <-> AXI4-Lite, asynchronous clocks.
module tb_lr_jtag_axi_core;
    // TCK 15 MHz, AXI 225 MHz (asynchronous)
    reg tck = 0;  always #33.3 tck = ~tck;
    reg aclk = 0; always #2.222 aclk = ~aclk;
    reg aresetn = 0;
    reg tdi = 0, sel = 0, capture = 0, shift = 0, update = 0, tlr = 0;
    wire tdo;

    wire [31:0] awaddr, wdata, araddr;
    wire [2:0] awprot, arprot;
    wire [3:0] wstrb;
    wire awvalid, wvalid, bready, arvalid, rready;
    reg  awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0;
    reg  [1:0] bresp = 0, rresp = 0;
    reg  [31:0] rdata = 0;

    lr_jtag_axi_core dut (
        .tck(tck), .tdi(tdi), .tdo(tdo), .sel(sel), .capture(capture),
        .shift(shift), .update(update), .tlr(tlr),
        .M_AXI_aclk(aclk), .M_AXI_aresetn(aresetn),
        .M_AXI_awaddr(awaddr), .M_AXI_awprot(awprot), .M_AXI_awvalid(awvalid),
        .M_AXI_awready(awready), .M_AXI_wdata(wdata), .M_AXI_wstrb(wstrb),
        .M_AXI_wvalid(wvalid), .M_AXI_wready(wready), .M_AXI_bresp(bresp),
        .M_AXI_bvalid(bvalid), .M_AXI_bready(bready),
        .M_AXI_araddr(araddr), .M_AXI_arprot(arprot), .M_AXI_arvalid(arvalid),
        .M_AXI_arready(arready), .M_AXI_rdata(rdata), .M_AXI_rresp(rresp),
        .M_AXI_rvalid(rvalid), .M_AXI_rready(rready));

    // ---------------- AXI4-Lite slave model ----------------
    // 256-word memory at 0x1000_0000; 0xDEAD_xxxx reads respond after 20 us.
    reg [31:0] mem [0:255];
    integer i;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 32'hA5A5_0000 + i;
    reg [31:0] wa;
    always @(posedge aclk) begin
        // write: random ready delays
        if (awvalid && !awready && ($urandom % 3 == 0)) begin awready <= 1; wa <= awaddr; end
        else awready <= 0;
        if (wvalid && !wready && ($urandom % 3 == 0)) wready <= 1; else wready <= 0;
    end
    reg aw_seen = 0, w_seen = 0;
    reg [31:0] wd;
    always @(posedge aclk) begin
        if (awvalid && awready) aw_seen <= 1;
        if (wvalid && wready) begin w_seen <= 1; wd <= wdata; end
        if (aw_seen && w_seen && !bvalid) begin
            mem[wa[9:2]] <= wd;
            bvalid <= 1; bresp <= (wa[31:28] == 4'h1) ? 2'b00 : 2'b11;
            aw_seen <= 0; w_seen <= 0;
        end else if (bvalid && bready) bvalid <= 0;
    end
    reg [31:0] ra;
    reg rpend = 0;
    integer rdelay = 0;
    always @(posedge aclk) begin
        arready <= 0;
        if (arvalid && !arready && !rpend && ($urandom % 2 == 0)) begin
            arready <= 1; ra <= araddr; rpend <= 1;
            rdelay <= (araddr[31:16] == 16'hDEAD) ? 4500 : ($urandom % 6);
        end
        if (rpend && !rvalid) begin
            if (rdelay == 0) begin
                rvalid <= 1; rresp <= 2'b00;
                rdata <= (ra[31:16] == 16'hDEAD) ? 32'h5106_5106 : mem[ra[9:2]];
            end else rdelay <= rdelay - 1;
        end else if (rvalid && rready) begin rvalid <= 0; rpend <= 0; end
    end

    // ---------------- JTAG DR scan model ----------------
    // Capture-DR, 72 x Shift-DR, Update-DR, then 'idle' TCKs in Run-Test/Idle.
    task automatic scan(input [71:0] din, input integer idle, output [71:0] dout);
        integer k;
        begin
            @(negedge tck); sel = 1; capture = 1;
            @(negedge tck); capture = 0; shift = 1;
            for (k = 0; k < 72; k = k + 1) begin
                dout[k] = tdo;          // TDO valid before the shifting edge
                tdi = din[k];
                @(negedge tck);
            end
            shift = 0; update = 1;
            @(negedge tck); update = 0; sel = 0;
            repeat (idle) @(negedge tck);
        end
    endtask

    function [71:0] cmd(input [1:0] op, input [31:0] addr, input [31:0] wd, input [3:0] tag);
        cmd = {tag, wd, addr, 2'b00, op};
    endfunction

    reg [71:0] st;
    task automatic check_magic(input [71:0] s);
        if (s[71:48] !== 24'h4C524A || s[47:44] !== 4'd1)
            $fatal(1, "bad magic/version: %h", s[71:44]);
    endtask

    integer n, errors = 0;
    reg [31:0] exp_val;
    initial begin
        repeat (5) @(posedge aclk); aresetn = 1;

        // 1) idle bridge: magic, nothing issued
        scan(72'd0, 4, st);
        check_magic(st);
        if (st[0] !== 1'b0 || st[1] !== 1'b0) $fatal(1, "fresh bridge not idle: %b", st[2:0]);

        // 2) write then read back
        scan(cmd(2'd1, 32'h1000_0010, 32'hCAFE_F00D, 4'd1), 16, st);
        scan(cmd(2'd2, 32'h1000_0010, 32'd0, 4'd2), 16, st);       // result of write
        if (!st[0] || st[1] || st[4:3] !== 2'b00 || st[40:37] !== 4'd1)
            $fatal(1, "write result wrong: %h", st[40:0]);
        scan(72'd0, 16, st);                                        // result of read
        if (!st[0] || st[36:5] !== 32'hCAFE_F00D || st[40:37] !== 4'd2)
            $fatal(1, "read back wrong: data %h tag %0d", st[36:5], st[40:37]);

        // 3) pipelined reads: each scan returns the previous read
        scan(cmd(2'd2, 32'h1000_0000, 32'd0, 4'd0), 16, st);
        for (n = 1; n <= 16; n = n + 1) begin
            scan(cmd(2'd2, 32'h1000_0000 + 4 * n, 32'd0, n[3:0]), 16, st);
            exp_val = (n - 1 == 4) ? 32'hCAFE_F00D : 32'hA5A5_0000 + (n - 1);
            if (!st[0] || st[36:5] !== exp_val || st[40:37] !== (n - 1) % 16) begin
                errors = errors + 1;
                $display("pipelined read %0d: got %h tag %0d", n - 1, st[36:5], st[40:37]);
            end
        end
        scan(72'd0, 16, st);
        if (errors) $fatal(1, "%0d pipelined read errors", errors);

        // 4) slow slave: next command arrives while busy -> busy + overrun,
        //    the command is dropped; overrun is sticky, so a later command is
        //    dropped too even after the slow read completed, until CLEAR.
        scan(cmd(2'd2, 32'hDEAD_0000, 32'd0, 4'd7), 2, st);
        scan(cmd(2'd1, 32'h1000_0020, 32'h1234_5678, 4'd8), 2, st);    // dropped
        if (!st[1] || st[0]) $fatal(1, "busy not reported: %b", st[2:0]);
        scan(72'd0, 2, st);
        if (!st[2]) $fatal(1, "overrun not reported");
        // wait for the slow read (20 us)
        repeat (400) @(negedge tck);
        scan(cmd(2'd1, 32'h1000_0024, 32'hBAD0_BAD0, 4'd9), 16, st);   // dropped (sticky)
        if (!st[0] || st[36:5] !== 32'h5106_5106 || st[40:37] !== 4'd7 || !st[2])
            $fatal(1, "slow read result wrong: %h tag %0d st %b", st[36:5], st[40:37], st[2:0]);
        scan(cmd(2'd3, 32'd0, 32'd0, 4'd0), 4, st);                    // CLEAR
        scan(72'd0, 4, st);
        if (st[2] || st[40:37] !== 4'd7) $fatal(1, "CLEAR failed or sticky drop executed: %b tag %0d", st[2:0], st[40:37]);
        if (dut.cmd_addr == 32'h1000_0024) $fatal(1, "write issued while overrun");
        scan(cmd(2'd1, 32'h1000_0020, 32'h1234_5678, 4'd8), 16, st);    // resend
        scan(cmd(2'd2, 32'h1000_0020, 32'd0, 4'd9), 16, st);
        if (!st[0] || st[40:37] !== 4'd8) $fatal(1, "resent write not executed");
        scan(72'd0, 16, st);
        if (st[36:5] !== 32'h1234_5678) $fatal(1, "resent write data wrong: %h", st[36:5]);

        // 5) error response is reported (address outside the slave)
        scan(cmd(2'd1, 32'h2000_0000, 32'd1, 4'd3), 16, st);
        scan(72'd0, 16, st);
        if (st[4:3] !== 2'b11) $fatal(1, "error response lost: %b", st[4:3]);

        $display("TB_LR_JTAG_AXI_CORE_PASS");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "jtag axi core timeout");
    end
endmodule
