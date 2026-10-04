// Decisive equivalence test: original vs new spectrum_engine.
// Both instances are driven with the SAME bin sequence (the driver waits for
// BOTH to be ready before presenting each bin, so per-instance sampling is
// guaranteed identical).  Outputs are compared in order.
`timescale 1ns/1ps

module tb_dec;

    localparam FFT_SIZE = 128;
    localparam FRAMES   = 16;

    reg clk = 0;
    reg rst_n = 0;
    always #2 clk = ~clk;

    reg [15:0] avg_alpha = 16'h6000;
    reg        peak_hold = 1'b1;
    reg        bypass    = 1'b0;

    reg [31:0] s_tdata;
    reg        s_tvalid;
    reg        s_tlast;

    // ---- new DUT ----
    wire n_ready, o_ready;
    wire [31:0] n_tdata; wire n_tvalid, n_tlast;
    wire [15:0] n_nf; wire n_fd;
    spectrum_engine #(.FFT_SIZE(FFT_SIZE)) dut_n (
        .clk(clk), .rst_n(rst_n),
        .avg_alpha(avg_alpha), .peak_hold(peak_hold), .bypass(bypass),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(n_ready), .s_tlast(s_tlast),
        .m_tdata(n_tdata), .m_tvalid(n_tvalid), .m_tready(1'b1), .m_tlast(n_tlast),
        .noise_floor(n_nf), .frame_done(n_fd)
    );

    // ---- original DUT ----
    wire [31:0] o_tdata; wire o_tvalid, o_tlast;
    wire [15:0] o_nf; wire o_fd;
    spectrum_engine_orig #(.FFT_SIZE(FFT_SIZE)) dut_o (
        .clk(clk), .rst_n(rst_n),
        .avg_alpha(avg_alpha), .peak_hold(peak_hold), .bypass(bypass),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(o_ready), .s_tlast(s_tlast),
        .m_tdata(o_tdata), .m_tvalid(o_tvalid), .m_tready(1'b1), .m_tlast(o_tlast),
        .noise_floor(o_nf), .frame_done(o_fd)
    );

    // ---- stimulus: drive only when BOTH ready ----
    reg [31:0] rnd = 32'h5A5A1234;
    integer frame, bin;
    integer errors;
    integer n_out, o_out;

    task drive_bin;
        input [31:0] td_in;
        input tl_in;
        begin
            // wait until both instances are ready (poll at negedge, then
            // present data so it is stable before the next posedge)
            while (!(n_ready && o_ready)) @(negedge clk);
            s_tdata = td_in; s_tvalid = 1'b1; s_tlast = tl_in;
            // hold through the posedge where both sample, then deassert
            @(posedge clk);   // both sample here
            @(negedge clk);
            s_tvalid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (n_tvalid) n_out = n_out + 1;
        if (o_tvalid) o_out = o_out + 1;
    end

    // compare: new output must equal original output (same order)
    reg [31:0] o_fifo [0:FFT_SIZE*FRAMES*4-1];
    integer o_wr, o_rd;
    always @(posedge clk) begin
        if (o_tvalid) begin
            o_fifo[o_wr] = o_tdata;
            o_wr = o_wr + 1;
        end
    end

    always @(posedge clk) begin
        if (n_tvalid) begin
            if (o_rd < o_wr) begin
                if (n_tdata !== o_fifo[o_rd]) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("MISMATCH new=%04h orig=%04h out#%0d", n_tdata, o_fifo[o_rd], o_rd);
                end
                o_rd = o_rd + 1;
            end
        end
    end

    initial begin
        errors = 0; n_out = 0; o_out = 0; o_wr = 0; o_rd = 0;
        rst_n = 0; s_tvalid = 0; s_tlast = 0; s_tdata = 0;
        #20 rst_n = 1;
        #10;
        // config sweep: peak_hold / bypass / avg_alpha combinations
        // (run 4 configs; reset between to clear history)
        begin : cfg_sweep
            integer cfg;
            for (cfg = 0; cfg < 4; cfg = cfg + 1) begin
                case (cfg)
                    0: begin peak_hold=1'b1; bypass=1'b0; avg_alpha=16'h6000; end
                    1: begin peak_hold=1'b0; bypass=1'b0; avg_alpha=16'h6000; end
                    2: begin peak_hold=1'b1; bypass=1'b1; avg_alpha=16'h6000; end
                    3: begin peak_hold=1'b1; bypass=1'b0; avg_alpha=16'd0;   end
                endcase
                // reset both engines to clear history for this config
                rst_n = 0;
                #10;
                rst_n = 1;
                #10;
                for (frame = 0; frame < FRAMES; frame = frame + 1) begin
                    for (bin = 0; bin < FFT_SIZE; bin = bin + 1) begin
                        rnd = rnd ^ (rnd << 13);
                        rnd = rnd ^ (rnd >> 17);
                        rnd = rnd ^ (rnd << 5);
                        drive_bin({rnd[31:16], rnd[15:0]}, (bin == FFT_SIZE-1));
                    end
                end
                #500;
                $display("config %0d: n_out=%0d o_out=%0d errors=%0d (cumulative)",
                         cfg, n_out, o_out, errors);
            end
        end
        #3000;
        $display("n_out=%0d o_out=%0d errors=%0d", n_out, o_out, errors);
        if (errors == 0 && n_out == o_out && n_out == FRAMES*FFT_SIZE*4)
            $display("*** DECISIVE EQUIVALENCE PASS (all configs) ***");
        else
            $display("*** EQUIVALENCE FAIL ***");
        $finish;
    end

endmodule
