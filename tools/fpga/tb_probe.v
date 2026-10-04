// Direct memory probe
`timescale 1ns/1ps
module tb_probe;
    localparam FFT_SIZE = 4;
    reg clk=0; always #2 clk=~clk;
    reg rst_n=0;
    reg [15:0] avg_alpha=16'h8000;
    reg peak_hold=1'b0, bypass=1'b0;
    reg [31:0] s_tdata=32'h00010001; reg s_tvalid, s_tlast;
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
    integer i;
    initial begin
        rst_n=0; s_tvalid=0; s_tlast=0;
        #20 rst_n=1; #10;
        for (i=0;i<12;i=i+1) begin
            while (!n_ready) @(posedge clk);
            s_tvalid=1'b1; s_tlast=(i%FFT_SIZE==FFT_SIZE-1);
            #1;
            while (n_ready) @(posedge clk);
            #1;
            s_tvalid=1'b0;
            // after this bin's pipeline, dump memory
            repeat(4) @(posedge clk);
            $display("after bin %0d: avg_mem[0]=%04h avg_mem[1]=%04h we=%1d wr=%1d",
                i, dut.avg_mem[0], dut.avg_mem[1], dut.avg_wr_en, dut.avg_wr_addr);
        end
        #100; $finish;
    end
endmodule
