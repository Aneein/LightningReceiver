// ============================================================================
// Lightning Receiver - Spectrum Engine (PSD stream)
// File: spectrum_engine.v
// ----------------------------------------------------------------------------
// Consumes complex FFT bins (AXIS TDATA={imag[15:0], real[15:0]}, tvalid per
// bin, tlast at frame end) and produces per-bin power:
//   |X|^2 -> scale -> exponential average -> peak hold -> 16-bit PSD stream
// Bin counter marks bin index in TUSER upper bits; tlast ends each frame.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module spectrum_engine #(
    parameter FFT_SIZE    = 4096
)(
    input  wire              clk,
    input  wire              rst_n,
    // config
    input  wire [15:0]       avg_alpha,    // 0 = no averaging
    input  wire              peak_hold,    // 1 = max-hold
    input  wire              bypass,       // 1 = raw |X|^2 out
    // FFT bin stream in
    input  wire [31:0]       s_tdata,      // {imag[15:0], real[15:0]}
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    // PSD stream out
    output reg  [31:0]       m_tdata,      // {bin[15:0], power[15:0]}
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast,
    output reg  [15:0]       noise_floor,  // averaged min-bin power (estimate)
    output reg               frame_done    // pulse at frame end
);

    localparam ST_READ = 2'd0, ST_MAG = 2'd1, ST_CALC = 2'd2, ST_WR = 2'd3;
    reg [1:0] state;
    assign s_tready = (state == ST_READ) && (!m_tvalid || m_tready);

    reg [15:0] bin_cnt;
    // Average and peak histories are per FFT bin.  The former implementation
    // used one accumulator for the whole stream, blending adjacent frequency
    // bins instead of successive frames of the same bin.
    // Separate single-port synchronous RAM processes (one per memory) so that
    // Vivado reliably infers BRAM: a read and a write to *different* addresses
    // in the same cycle cannot be expressed in one always block.  The state
    // machine below reads the current bin during ST_READ and writes the
    // updated value during ST_CALC, one cycle apart - a legal SDP pattern.
    (* ram_style = "block" *) reg [15:0] avg_mem  [0:FFT_SIZE-1];
    (* ram_style = "block" *) reg [15:0] peak_mem [0:FFT_SIZE-1];
    reg [15:0] avg_old, peak_old;
    reg [15:0] avg_wr_data, peak_wr_data;
    reg [15:0] avg_rd_addr, peak_rd_addr;
    reg [15:0] avg_wr_addr, peak_wr_addr;
    reg        avg_wr_en, peak_wr_en;
    reg [31:0] re_sq_q, im_sq_q;
    reg [15:0] raw_power_q;
    reg signed [33:0] avg_product_q;
    reg [15:0] bin_q;
    reg last_q;
    reg history_valid;
    reg [15:0] nf_acc;

    // ---- avg_mem: single write port, synchronous read port (read-first) ----
    always @(posedge clk) begin
        if (avg_wr_en)
            avg_mem[avg_wr_addr] <= avg_wr_data;
        avg_old <= avg_mem[avg_rd_addr];
    end
    // ---- peak_mem: same pattern ----
    always @(posedge clk) begin
        if (peak_wr_en)
            peak_mem[peak_wr_addr] <= peak_wr_data;
        peak_old <= peak_mem[peak_rd_addr];
    end

    wire signed [15:0] re = s_tdata[15:0];
    wire signed [15:0] im = s_tdata[31:16];
    wire [31:0] re_sq = re * re;
    wire [31:0] im_sq = im * im;
    wire [32:0] mag2_sum = {1'b0, re_sq_q} + {1'b0, im_sq_q};

    reg [15:0] avg_next, peak_next;
    reg [15:0] power_next;
    reg signed [34:0] avg_candidate;
    always @(*) begin
        avg_candidate = $signed({1'b0, avg_old}) +
                        ($signed(avg_product_q) >>> 16);
        if (!history_valid || avg_alpha == 16'd0 || bypass)
            avg_next = raw_power_q;
        else if (avg_candidate < 0)
            avg_next = 16'd0;
        else if (avg_candidate > 35'sd65535)
            avg_next = 16'hFFFF;
        else
            avg_next = avg_candidate[15:0];

        if (peak_hold && history_valid && (peak_old > avg_next))
            peak_next = peak_old;
        else
            peak_next = avg_next;

        power_next = bypass ? raw_power_q : peak_next;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_cnt <= 16'd0;
            state <= ST_READ;
            re_sq_q <= 32'd0;
            im_sq_q <= 32'd0;
            raw_power_q <= 16'd0;
            avg_product_q <= 34'sd0;
            bin_q <= 16'd0;
            last_q <= 1'b0;
            history_valid <= 1'b0;
            nf_acc <= 16'd0;
            noise_floor <= 16'd0;
            frame_done <= 1'b0;
            m_tdata <= 32'd0;
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
            avg_rd_addr <= 16'd0; peak_rd_addr <= 16'd0;
            avg_wr_addr <= 16'd0; peak_wr_addr <= 16'd0;
            avg_wr_en <= 1'b0;    peak_wr_en <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            avg_wr_en <= 1'b0; peak_wr_en <= 1'b0;
            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast <= 1'b0;
            end

            case (state)
                ST_READ: begin
                    if (s_tvalid && s_tready) begin
                        // Register both DSP multipliers before the 33-bit sum.
                        re_sq_q <= re_sq;
                        im_sq_q <= im_sq;
                        bin_q <= bin_cnt;
                        last_q <= s_tlast || (bin_cnt == FFT_SIZE-1);
                        // Issue the synchronous RAM reads for this bin.  The
                        // BRAM output (avg_old/peak_old) is valid one cycle
                        // after this address is presented.
                        avg_rd_addr <= bin_cnt;
                        peak_rd_addr <= bin_cnt;
                        state <= ST_MAG;
                    end
                end

                ST_MAG: begin
                    raw_power_q <= mag2_sum[32] ? 16'hFFFF
                                                  : mag2_sum[31:16];
                    // avg_old/peak_old settle here (address was presented in
                    // ST_READ); the multiply runs in ST_CALC once they are
                    // stable.  This stage only registers the |X|^2 power.
                    state <= ST_CALC;
                end

                ST_CALC: begin
                    // avg_old/peak_old (from ST_READ's address) and raw_power_q
                    // (from ST_MAG) are all settled now.  Q0.16 alpha:
                    //   avg += (new - old) * alpha
                    avg_product_q <=
                        ($signed({1'b0, raw_power_q}) -
                         $signed({1'b0, avg_old})) *
                        $signed({1'b0, avg_alpha});
                    state <= ST_WR;
                end

                ST_WR: begin
                    // avg_product_q settled in ST_CALC, so avg_next/peak_next/
                    // power_next are stable combinational functions here.

                    // Write the updated history for this bin (read during
                    // ST_READ of the *next* frame, i.e. one FFT period later).
                    avg_wr_addr <= bin_q;
                    avg_wr_data <= avg_next;
                    avg_wr_en   <= 1'b1;
                    peak_wr_addr <= bin_q;
                    peak_wr_data <= peak_next;
                    peak_wr_en   <= 1'b1;

                    // nf_acc tracks the min *instantaneous* power: raw_power_q
                    // is a registered FF output (ST_MAG), so this compare never
                    // sits behind the BRAM-read -> avg/peak combinational path.
                    // (Noise-floor estimate uses instantaneous power, which is
                    // the standard definition and avoids peak-hold inflation.)
                    if (bin_q == 16'd0)
                        nf_acc <= raw_power_q;
                    else if (raw_power_q < nf_acc)
                        nf_acc <= raw_power_q;

                    m_tdata <= {bin_q, power_next};
                    m_tvalid <= 1'b1;
                    m_tlast <= last_q;

                    if (last_q) begin
                        noise_floor <= (bin_q == 16'd0 || raw_power_q < nf_acc)
                                       ? raw_power_q : nf_acc;
                        frame_done <= 1'b1;
                        bin_cnt <= 16'd0;
                        history_valid <= 1'b1;
                    end else begin
                        bin_cnt <= bin_cnt + 1'b1;
                    end
                    state <= ST_READ;
                end
            endcase
        end
    end

endmodule
