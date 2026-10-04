// Original 3-state spectrum_engine (reconstructed from the pre-modification
// source) - used as the golden reference for equivalence testing.
`timescale 1ns/1ps

module spectrum_engine_orig #(
    parameter FFT_SIZE    = 4096
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [15:0]       avg_alpha,
    input  wire              peak_hold,
    input  wire              bypass,
    input  wire [31:0]       s_tdata,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    output reg  [31:0]       m_tdata,
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast,
    output reg  [15:0]       noise_floor,
    output reg               frame_done
);

    localparam ST_READ = 2'd0, ST_MAG = 2'd1, ST_CALC = 2'd2;
    reg [1:0] state;
    assign s_tready = (state == ST_READ) && (!m_tvalid || m_tready);

    reg [15:0] bin_cnt;
    reg [15:0] avg_mem  [0:FFT_SIZE-1];
    reg [15:0] peak_mem [0:FFT_SIZE-1];
    reg [15:0] avg_old, peak_old;
    reg [31:0] re_sq_q, im_sq_q;
    reg [15:0] raw_power_q;
    reg signed [33:0] avg_product_q;
    reg [15:0] bin_q;
    reg last_q;
    reg history_valid;
    reg [15:0] nf_acc;

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
            avg_old <= 32'd0;
            peak_old <= 32'd0;
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
        end else begin
            frame_done <= 1'b0;
            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast <= 1'b0;
            end

            case (state)
                ST_READ: begin
                    if (s_tvalid && s_tready) begin
                        re_sq_q <= re_sq;
                        im_sq_q <= im_sq;
                        bin_q <= bin_cnt;
                        last_q <= s_tlast || (bin_cnt == FFT_SIZE-1);
                        avg_old <= avg_mem[bin_cnt];
                        peak_old <= peak_mem[bin_cnt];
                        state <= ST_MAG;
                    end
                end

                ST_MAG: begin
                    raw_power_q <= mag2_sum[32] ? 16'hFFFF
                                                  : mag2_sum[31:16];
                    avg_product_q <=
                        ($signed({1'b0, (mag2_sum[32] ? 16'hFFFF
                                                       : mag2_sum[31:16])}) -
                         $signed({1'b0, avg_old})) *
                        $signed({1'b0, avg_alpha});
                    state <= ST_CALC;
                end

                ST_CALC: begin
                    avg_mem[bin_q] <= avg_next;
                    peak_mem[bin_q] <= peak_next;

                    if (bin_q == 16'd0)
                        nf_acc <= power_next;
                    else if (power_next < nf_acc)
                        nf_acc <= power_next;

                    m_tdata <= {bin_q, power_next};
                    m_tvalid <= 1'b1;
                    m_tlast <= last_q;

                    if (last_q) begin
                        noise_floor <= (bin_q == 16'd0 || power_next < nf_acc)
                                       ? power_next : nf_acc;
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
