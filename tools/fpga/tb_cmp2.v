// Probe BOTH versions' avg_mem[0] and output for frame 2 bin 0
`timescale 1ns/1ps
module tb_cmp2;
    localparam FFT_SIZE = 8;
    reg clk=0; always #2 clk=~clk;
    reg rst_n=0;
    reg [15:0] avg_alpha=16'h8000;
    reg peak_hold=1'b1, bypass=1'b0;
    reg [31:0] s_tdata; reg s_tvalid, s_tlast;
    wire n_ready, o_ready;
    wire [31:0] n_tdata; wire n_tvalid, n_tlast;
    wire [15:0] n_nf; wire n_fd;
    wire [31:0] o_tdata; wire o_tvalid, o_tlast;
    wire [15:0] o_nf; wire o_fd;
    spectrum_engine #(.FFT_SIZE(FFT_SIZE)) dnew (
        .clk(clk), .rst_n(rst_n),
        .avg_alpha(avg_alpha), .peak_hold(peak_hold), .bypass(bypass),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(n_ready), .s_tlast(s_tlast),
        .m_tdata(n_tdata), .m_tvalid(n_tvalid), .m_tready(1'b1), .m_tlast(n_tlast),
        .noise_floor(n_nf), .frame_done(n_fd)
    );
    spectrum_engine_orig #(.FFT_SIZE(FFT_SIZE)) dold (
        .clk(clk), .rst_n(rst_n),
        .avg_alpha(avg_alpha), .peak_hold(peak_hold), .bypass(bypass),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(o_ready), .s_tlast(s_tlast),
        .m_tdata(o_tdata), .m_tvalid(o_tvalid), .m_tready(1'b1), .m_tlast(o_tlast),
        .noise_floor(o_nf), .frame_done(o_fd)
    );
    reg [31:0] rnd = 32'hCAFEBABE;
    integer i;
    initial begin
        rst_n=0; s_tvalid=0; s_tlast=0; s_tdata=0;
        #20 rst_n=1; #10;
        for (i=0;i<16;i=i+1) begin
            rnd = rnd ^ (rnd<<13); rnd = rnd ^ (rnd>>17); rnd = rnd ^ (rnd<<5);
            while (!(n_ready && o_ready)) @(negedge clk);
            s_tdata = {rnd[31:16], rnd[15:0]};
            s_tvalid = 1'b1;
            s_tlast = (i % FFT_SIZE == FFT_SIZE-1);
            @(posedge clk);
            @(negedge clk);
            s_tvalid = 1'b0;
            // after this bin, dump both memories and outputs
            repeat(4) @(posedge clk);
            $display("i=%2d n_avg0=%04h o_avg0=%04h n_peak0=%04h o_peak0=%04h n_out=%04h o_out=%04h n_old=%04h o_old=%04h",
                i, dnew.avg_mem[0], dold.avg_mem[0],
                dnew.peak_mem[0], dold.peak_mem[0],
                n_tdata, o_tdata, dnew.avg_old, dold.avg_old);
        end
        #100; $finish;
    end
endmodule
