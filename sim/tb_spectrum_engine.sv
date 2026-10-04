`timescale 1ns/1ps

module tb_spectrum_engine;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg [31:0] sdata = 0;
    reg svalid = 0, slast = 0;
    wire sready;
    wire [31:0] mdata;
    wire mvalid, mlast;
    wire [15:0] noise_floor;
    wire frame_done;
    reg [15:0] avg_alpha = 16'd0;
    reg peak_hold = 1'b1;
    integer k;

    spectrum_engine #(.FFT_SIZE(4)) dut (
        .clk(clk), .rst_n(rst_n), .avg_alpha(avg_alpha),
        .peak_hold(peak_hold), .bypass(1'b0), .s_tdata(sdata),
        .s_tvalid(svalid), .s_tready(sready), .s_tlast(slast),
        .m_tdata(mdata), .m_tvalid(mvalid), .m_tready(1'b1),
        .m_tlast(mlast), .noise_floor(noise_floor), .frame_done(frame_done)
    );

    task automatic send_check(
        input signed [15:0] re,
        input last,
        input [15:0] expected_bin,
        input [15:0] expected_power
    );
        begin
            @(negedge clk); sdata = {16'sd0, re}; svalid = 1; slast = last;
            do @(posedge clk); while (!sready);
            @(negedge clk); svalid = 0; slast = 0;
            wait (mvalid); #1;
            if (mdata !== {expected_bin, expected_power} || mlast !== last)
                $fatal(1, "PSD mismatch got=%h last=%b", mdata, mlast);
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        // powers are exactly k^2 because (256*k)^2 >> 16 == k^2.
        for (k = 1; k <= 4; k = k + 1)
            send_check(256*k, k == 4, k-1, k*k);
        // Peak hold must retrieve each bin's own prior-frame history.
        for (k = 1; k <= 4; k = k + 1)
            send_check(16'sd256, k == 4, k-1, k*k);
        // Q0.16 alpha=0.5 averages the stored power 1 with new power 9.
        peak_hold = 1'b0;
        avg_alpha = 16'h8000;
        for (k = 1; k <= 4; k = k + 1)
            send_check(16'sd768, k == 4, k-1, 16'd5);
        // Noise floor is the min *instantaneous* |X|^2 of the frame (raw 9),
        // not the averaged/peak-held output (5) - see spectrum_engine ST_WR.
        if (noise_floor != 16'd9)
            $fatal(1, "noise floor mismatch: %0d", noise_floor);
        $display("TB_SPECTRUM_ENGINE_PASS");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "spectrum engine timeout");
    end
endmodule
