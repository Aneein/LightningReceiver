// Minimal functional check: constant input, 3 frames, verify avg converges
`timescale 1ns/1ps
module tb_min;
    localparam FFT_SIZE = 4;
    reg clk=0; always #2 clk=~clk;
    reg rst_n=0;
    reg [15:0] avg_alpha=16'h8000;
    reg peak_hold=1'b0, bypass=1'b0;
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
    wire [15:0] avg_wr_addr = dut.avg_wr_addr;
    wire        avg_wr_en = dut.avg_wr_en;
    wire [15:0] avg_wr_data = dut.avg_wr_data;
    wire [15:0] raw_pow = dut.raw_power_q;
    wire [15:0] avg_next = dut.avg_next;
    wire [15:0] hist = dut.history_valid;

    integer i;
    initial begin
        rst_n=0; s_tvalid=0; s_tlast=0; s_tdata=32'h00010001; // re=1, im=1 -> power 2
        #20 rst_n=1; #10;
        $display("time st bin hist rd wr wren old raw avg_next nout");
        for (i=0;i<12;i=i+1) begin  // 3 frames of 4
            while (!n_ready) @(posedge clk);
            s_tvalid = 1'b1; s_tlast = (i % FFT_SIZE == FFT_SIZE-1);
            #1;
            while (n_ready) @(posedge clk);
            #1;
            s_tvalid = 1'b0;
            repeat(4) begin
                @(posedge clk);
                $display("%0t st=%1d bin=%1d h=%1d rd=%1d wr=%1d we=%1d old=%04h raw=%04h an=%04h out=%04h",
                    $time, st, bin_cnt, hist, dut.avg_rd_addr, avg_wr_addr, avg_wr_en,
                    avg_old, raw_pow, avg_next, n_tdata);
            end
        end
        #200; $finish;
    end
endmodule
