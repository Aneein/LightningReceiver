// Probe: dump new-version internals during frame 2 bin 0
`timescale 1ns/1ps
module tb_probe2;
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
    wire [15:0] rd = dut.avg_rd_addr;
    wire [15:0] wr = dut.avg_wr_addr;
    wire we = dut.avg_wr_en;
    wire [15:0] raw = dut.raw_power_q;
    wire signed [33:0] prod = dut.avg_product_q;
    wire [15:0] an = dut.avg_next;
    wire [15:0] pp = dut.power_pipe;
    wire [15:0] h = dut.history_valid;
    wire [15:0] bin_q = dut.bin_q;
    wire [15:0] peak_old = dut.peak_old;

    reg [31:0] rnd = 32'hCAFEBABE;
    integer i;
    initial begin
        rst_n=0; s_tvalid=0; s_tlast=0; s_tdata=0;
        #20 rst_n=1; #10;
        for (i=0;i<16;i=i+1) begin
            rnd = rnd ^ (rnd<<13); rnd = rnd ^ (rnd>>17); rnd = rnd ^ (rnd<<5);
            while (!n_ready) @(posedge clk);
            s_tdata = {rnd[31:16], rnd[15:0]};
            s_tvalid = 1'b1;
            s_tlast = (i % FFT_SIZE == FFT_SIZE-1);
            #1;
            while (n_ready) @(posedge clk);
            #1;
            s_tvalid = 1'b0;
            // dump each pipeline stage
            repeat(4) begin
                @(posedge clk);
                $display("i=%2d t=%0t st=%1d bc=%2d bq=%2d rd=%2d wr=%2d we=%1d h=%1d old=%04h peak=%04h raw=%04h prod=%8d an=%04h pp=%04h",
                    i, $time, st, bin_cnt, bin_q, rd, wr, we, h,
                    avg_old, peak_old, raw, prod, an, pp);
            end
        end
        #100; $finish;
    end
endmodule
