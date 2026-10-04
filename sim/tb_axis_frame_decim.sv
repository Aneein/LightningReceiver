`timescale 1ns/1ps

// axis_frame_decim: keeps 1 of N whole frames, never backpressures on
// discarded frames, marks tlast at the frame end, factor <2 -> 4.
module tb_axis_frame_decim;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg [7:0] factor = 0;
    reg [31:0] s_tdata = 0;
    reg s_tvalid = 0;
    wire s_tready;
    wire [31:0] m_tdata;
    wire [15:0] m_tuser;
    wire m_tvalid, m_tlast;
    reg m_tready = 1;

    axis_frame_decim #(.FRAME(16)) dut (
        .clk(clk), .rst_n(rst_n), .factor(factor),
        .s_tdata(s_tdata), .s_tuser(16'h0), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(1'b0),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast));

    integer n_out = 0, n_last = 0, bad = 0;
    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            // payload = global sample index; kept frames start on k*N*16
            if ((m_tdata % 16) != (n_out % 16)) bad = bad + 1;
            if (m_tlast !== ((m_tdata % 16) == 15)) bad = bad + 1;
            n_out = n_out + 1;
            if (m_tlast) n_last = n_last + 1;
        end
    end

    integer idx = 0;
    task automatic stream(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk); s_tdata = idx; s_tvalid = 1;
                do @(posedge clk); while (!s_tready);
                idx = idx + 1;
            end
            @(negedge clk); s_tvalid = 0;
        end
    endtask

    integer first_kept;
    initial begin
        repeat (3) @(posedge clk); rst_n = 1;

        // default N = 4: 8 frames in -> 2 frames out (frames 0 and 4)
        stream(8 * 16);
        if (n_out != 32 || n_last != 2 || bad != 0)
            $fatal(1, "N=4 wrong: out %0d last %0d bad %0d", n_out, n_last, bad);

        // a slow consumer only stalls kept frames; discarded ones flow freely
        @(negedge clk); m_tready = 0;
        fork
            stream(16);                        // frame 8: kept -> stalls
            begin repeat (40) @(posedge clk); @(negedge clk); m_tready = 1; end
        join
        stream(3 * 16);                        // frames 9..11 discarded
        if (n_out != 48 || bad != 0) $fatal(1, "stall handling wrong: %0d", n_out);

        // factor 2 takes effect at the next decimation boundary
        factor = 8'd2;
        n_out = 0; n_last = 0;
        // The cycle 12..15 already runs with N=4 (factor is sampled at the end
        // of frame 11, before it changed), so frames 12, 16 and 18 are kept.
        stream(8 * 16);
        if (n_out != 48 || n_last != 3 || bad != 0)
            $fatal(1, "N=2 wrong: out %0d last %0d bad %0d", n_out, n_last, bad);

        $display("TB_AXIS_FRAME_DECIM_PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "frame decim timeout");
    end
endmodule
