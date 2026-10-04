// Quick debug: print per-bin state transitions
`timescale 1ns/1ps
module tb_dbg;
    localparam FFT_SIZE = 8;
    reg clk=0; always #2 clk=~clk;
    reg rst_n=0;
    reg [15:0] avg_alpha=16'h8000;
    reg peak_hold=1'b1, bypass=1'b0;
    reg [31:0] s_tdata; reg s_tvalid, s_tlast;
    wire n_ready;
    wire [31:0] n_tdata; wire n_tvalid, n_tlast;
    wire [15:0] n_nf; wire n_fd;
    spectrum_engine #(.FFT_SIZE(FFT_SIZE)) dut (
        .clk(clk), .rst_n(rst_n),
        .avg_alpha(avg_alpha), .peak_hold(peak_hold), .bypass(bypass),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(n_ready), .s_tlast(s_tlast),
        .m_tdata(n_tdata), .m_tvalid(n_tvalid), .m_tready(1'b1), .m_tlast(n_tlast),
        .noise_floor(n_nf), .frame_done(n_fd)
    );
    wire [1:0] st = dut.state;
    wire [15:0] bin_cnt = dut.bin_cnt;
    wire [15:0] avg_old = dut.avg_old;
    wire [15:0] avg_rd_addr = dut.avg_rd_addr;
    wire [15:0] avg_wr_addr = dut.avg_wr_addr;
    wire        avg_wr_en = dut.avg_wr_en;
    wire [15:0] raw_pow = dut.raw_power_q;
    wire signed [33:0] avg_prod = dut.avg_product_q;
    wire [15:0] bin_q = dut.bin_q;
    wire [15:0] avg_next = dut.avg_next;
    wire [15:0] power_pipe = dut.power_pipe;

    integer i;
    reg [31:0] rnd = 32'hDEADBEEF;
    reg [31:0] td;
    initial begin
        rst_n=0; s_tvalid=0; s_tlast=0; s_tdata=0;
        #20 rst_n=1; #10;
        $display("time st bin_cnt bin_q rd_addr wr_addr wr_en avg_old avg_prod avg_next pow_pipe n_out");
        for (i=0;i<16;i=i+1) begin
            rnd = rnd ^ (rnd<<13); rnd = rnd ^ (rnd>>17); rnd = rnd ^ (rnd<<5);
            td = {rnd[31:16], rnd[15:0]};
            @(posedge clk);
            s_tdata = td;
            s_tvalid = 1'b1;
            s_tlast = (i % FFT_SIZE == FFT_SIZE-1);
            while (!n_ready) @(posedge clk);
            @(posedge clk);
            s_tvalid = 0;
            // after acceptance, watch 4 cycles of pipeline
            repeat(4) begin
                @(posedge clk);
                $display("%0t st=%1d bin_cnt=%3d bin_q=%3d rd=%3d wr=%3d wren=%1d avg_old=%04h prod=%6d avg_next=%04h raw=%04h ppipe=%04h n_out=%04h",
                    $time, st, bin_cnt, bin_q, avg_rd_addr, avg_wr_addr, avg_wr_en,
                    avg_old, avg_prod, avg_next, raw_pow, power_pipe, n_tdata);
            end
        end
        #200;
        $finish;
    end
endmodule
