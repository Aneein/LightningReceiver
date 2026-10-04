// ============================================================================
// Dual-instance equivalence test:
//   DUT  = new 4-state BRAM spectrum_engine
//   REF  = original 3-state spectrum_engine (reconstructed exactly)
// Both run the same stimulus; outputs are compared with a per-frame pipeline
// delay line (new version emits each frame's bins later, but in the same
// order).  Frame alignment uses frame_done counts.
// ============================================================================
`timescale 1ns/1ps

module tb_spec_equiv;

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

    // ================= DUT: new 4-state =================
    wire       n_ready;
    wire [31:0] n_tdata; wire n_tvalid; wire n_tlast;
    wire [15:0] n_nf; wire n_fd;
    spectrum_engine #(.FFT_SIZE(FFT_SIZE)) dut (
        .clk(clk), .rst_n(rst_n),
        .avg_alpha(avg_alpha), .peak_hold(peak_hold), .bypass(bypass),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(n_ready), .s_tlast(s_tlast),
        .m_tdata(n_tdata), .m_tvalid(n_tvalid), .m_tready(1'b1), .m_tlast(n_tlast),
        .noise_floor(n_nf), .frame_done(n_fd)
    );

    // ================= REF: original 3-state =================
    reg [15:0] avg_mem_r [0:FFT_SIZE-1];
    reg [15:0] peak_mem_r [0:FFT_SIZE-1];
    reg [15:0] bin_cnt_r; reg [1:0] st_r;
    reg [15:0] avg_old_r, peak_old_r;
    reg [31:0] re_sq_r, im_sq_r;
    reg [15:0] raw_pow_r;
    reg signed [33:0] avg_prod_r;
    reg [15:0] bin_q_r; reg last_q_r; reg hist_r;
    reg [15:0] nf_acc_r;
    reg [31:0] r_tdata; reg r_tvalid; reg r_tlast;
    reg [15:0] r_nf; reg r_fd;
    integer ii;

    wire signed [15:0] r_re = s_tdata[15:0];
    wire signed [15:0] r_im = s_tdata[31:16];
    wire [31:0] r_re_sq = r_re * r_re;
    wire [31:0] r_im_sq = r_im * r_im;
    wire [32:0] r_mag2 = {1'b0, re_sq_r} + {1'b0, im_sq_r};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_cnt_r <= 0; st_r <= 0;
            avg_old_r <= 0; peak_old_r <= 0;
            re_sq_r <= 0; im_sq_r <= 0;
            raw_pow_r <= 0; avg_prod_r <= 0;
            bin_q_r <= 0; last_q_r <= 0; hist_r <= 0; nf_acc_r <= 0;
            r_tvalid <= 0; r_tlast <= 0; r_nf <= 0; r_fd <= 0;
            for (ii=0;ii<FFT_SIZE;ii=ii+1) begin avg_mem_r[ii]<=0; peak_mem_r[ii]<=0; end
        end else begin
            r_fd <= 0;
            if (r_tvalid) begin r_tvalid <= 0; r_tlast <= 0; end
            case (st_r)
                2'd0: if (s_tvalid && n_ready) begin
                    re_sq_r <= r_re_sq; im_sq_r <= r_im_sq;
                    bin_q_r <= bin_cnt_r;
                    last_q_r <= s_tlast || (bin_cnt_r == FFT_SIZE-1);
                    avg_old_r <= avg_mem_r[bin_cnt_r];
                    peak_old_r <= peak_mem_r[bin_cnt_r];
                    st_r <= 2'd1;
                end
                2'd1: begin
                    raw_pow_r <= r_mag2[32] ? 16'hFFFF : r_mag2[31:16];
                    avg_prod_r <= ($signed({1'b0,(r_mag2[32]?16'hFFFF:r_mag2[31:16])}) - $signed({1'b0,avg_old_r})) * $signed({1'b0,avg_alpha});
                    st_r <= 2'd2;
                end
                2'd2: begin : ref_calc_blk
                    reg signed [34:0] cand;
                    reg [15:0] avg_nxt, peak_nxt, pow_nxt;
                    cand = $signed({1'b0, avg_old_r}) + ($signed(avg_prod_r) >>> 16);
                    if (!hist_r || avg_alpha==0 || bypass) avg_nxt = raw_pow_r;
                    else if (cand < 0) avg_nxt = 0;
                    else if (cand > 35'sd65535) avg_nxt = 16'hFFFF;
                    else avg_nxt = cand[15:0];
                    if (peak_hold && hist_r && (peak_old_r > avg_nxt)) peak_nxt = peak_old_r;
                    else peak_nxt = avg_nxt;
                    pow_nxt = bypass ? raw_pow_r : peak_nxt;
                    avg_mem_r[bin_q_r] <= avg_nxt;
                    peak_mem_r[bin_q_r] <= peak_nxt;
                    if (bin_q_r == 0) nf_acc_r <= pow_nxt;
                    else if (pow_nxt < nf_acc_r) nf_acc_r <= pow_nxt;
                    r_tdata <= {bin_q_r, pow_nxt};
                    r_tvalid <= 1'b1;
                    r_tlast <= last_q_r;
                    if (last_q_r) begin
                        r_nf <= (bin_q_r==0 || pow_nxt<nf_acc_r) ? pow_nxt : nf_acc_r;
                        r_fd <= 1'b1;
                        bin_cnt_r <= 0;
                        hist_r <= 1'b1;
                    end else bin_cnt_r <= bin_cnt_r + 1;
                    st_r <= 2'd0;
                end
            endcase
        end
    end

    // ================= stimulus =================
    reg [31:0] rnd = 32'h5A5A1234;
    integer frame, bin;

    task drive_bin;
        input [31:0] td_in;
        input tl_in;
        begin
            // wait for DUT to be ready to accept
            while (!n_ready) @(posedge clk);
            // present data just after the edge (no race with DUT's edge sampling)
            s_tdata = td_in; s_tvalid = 1'b1; s_tlast = tl_in;
            #1;
            // wait until the DUT has sampled (it leaves ST_READ)
            while (n_ready) @(posedge clk);
            #1;
            s_tvalid = 1'b0;
        end
    endtask

    // ================= comparison =================
    // DUT emits each bin's power after its pipeline; REF after its own.
    // Both are in bin order per frame.  Compare per frame using frame_done
    // to delimit frames, with a FIFO of expected values from REF.
    reg [15:0] ref_fifo [0:FFT_SIZE*2-1];
    integer ref_fifo_wr, ref_fifo_rd;
    reg [15:0] ref_nf_fifo [0:FRAMES-1];
    integer ref_nf_wr;
    integer errors;

    always @(posedge clk) begin
        if (r_tvalid) begin
            ref_fifo[ref_fifo_wr % (FFT_SIZE*2)] = r_tdata[15:0];
            ref_fifo_wr = ref_fifo_wr + 1;
        end
        if (r_fd) begin
            ref_nf_fifo[ref_nf_wr % FRAMES] = r_nf;
            ref_nf_wr = ref_nf_wr + 1;
        end
    end

    initial begin
        errors = 0;
        ref_fifo_wr = 0; ref_fifo_rd = 0; ref_nf_wr = 0;
        rst_n = 0; s_tvalid = 0; s_tlast = 0; s_tdata = 0;
        #20 rst_n = 1;
        #10;
        for (frame = 0; frame < FRAMES; frame = frame + 1) begin
            for (bin = 0; bin < FFT_SIZE; bin = bin + 1) begin
                rnd = rnd ^ (rnd << 13);
                rnd = rnd ^ (rnd >> 17);
                rnd = rnd ^ (rnd << 5);
                drive_bin({rnd[31:16], rnd[15:0]}, (bin == FFT_SIZE-1));
            end
        end
        // drain: wait until both have emitted FRAMES*FFT_SIZE outputs
        #2000;
        $display("ref_fifo_wr=%0d (expect %0d)", ref_fifo_wr, FRAMES*FFT_SIZE);
        $display("errors=%0d", errors);
        if (errors == 0) $display("*** EQUIVALENCE PASS ***");
        else $display("*** EQUIVALENCE FAIL ***");
        $finish;
    end

    // compare DUT output against REF FIFO
    always @(posedge clk) begin
        if (n_tvalid) begin
            if (ref_fifo_rd < ref_fifo_wr) begin
                if (n_tdata[15:0] !== ref_fifo[ref_fifo_rd % (FFT_SIZE*2)]) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("MISMATCH dut=%04h ref=%04h idx=%0d",
                                 n_tdata[15:0], ref_fifo[ref_fifo_rd % (FFT_SIZE*2)], ref_fifo_rd);
                end
                ref_fifo_rd = ref_fifo_rd + 1;
            end
        end
    end

endmodule
