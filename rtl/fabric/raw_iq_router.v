// ============================================================================
// Lightning Receiver - Raw IQ Router (AD9361 ADC channels -> LR stream 0)
// File: raw_iq_router.v
// ----------------------------------------------------------------------------
// Takes axi_ad9361 ADC channel outputs (I0/Q0, l_clk domain, enable/valid/data
// semantics per ADI hdl) and produces LR stream 0 (RAW_IQ_CH0) in the fabric
// domain. I/Q pair assembled on Q-valid and pushed through an internal async
// FIFO; timestamp/sample_index side channel latched at frame head.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module raw_iq_router #(
    parameter IQ_W      = 16,
    parameter FRAME_LEN = 128        // samples per raw frame (tlast period)
)(
    input  wire              clk,           // fabric 225 MHz
    input  wire              rst_n,
    // AD9361 ADC channel inputs (l_clk domain)
    input  wire              l_clk,         // device clock (DATA_CLK)
    input  wire              l_rst_n,
    (* X_INTERFACE_IGNORE = "true" *) input wire adc_enable_i0,
    (* X_INTERFACE_IGNORE = "true" *) input wire adc_valid_i0,
    (* X_INTERFACE_IGNORE = "true" *) input wire [IQ_W-1:0] adc_data_i0,
    (* X_INTERFACE_IGNORE = "true" *) input wire adc_enable_q0,
    (* X_INTERFACE_IGNORE = "true" *) input wire adc_valid_q0,
    (* X_INTERFACE_IGNORE = "true" *) input wire [IQ_W-1:0] adc_data_q0,
    // timestamp side channel (fabric domain)
    input  wire [63:0]       timestamp,
    input  wire [63:0]       sample_count,
    // LR stream 0 out (fabric domain)
    output reg  [`LR_TDATA_W-1:0] m_tdata,
    output reg  [`LR_TUSER_W-1:0] m_tuser,
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast,
    output reg  [63:0]       m_timestamp,
    output reg  [63:0]       m_sample_count,
    (* X_INTERFACE_IGNORE = "true" *) output wire sample_accepted,
    // status
    (* X_INTERFACE_IGNORE = "true" *) output reg fifo_overflow
);

    assign sample_accepted = m_tvalid && m_tready;

    // ------------------------------------------------------------------------
    // Write side (l_clk): pair I/Q from the same ADI sample.  axi_ad9361
    // normally asserts I0 and Q0 valid together; the pending registers also
    // cover a legal skewed-valid case without pairing I(n-1) with Q(n).
    // ------------------------------------------------------------------------
    reg [IQ_W-1:0] i_latch, q_latch;
    reg            i_pending, q_pending;
    reg            overflow_lclk;
    (* ASYNC_REG = "TRUE" *) reg overflow_sync1, overflow_sync2;
    wire fifo_full;
    wire fifo_empty;
    wire [31:0] fifo_dout;
    wire fifo_rd = !fifo_empty && (!m_tvalid || m_tready);
    wire i_now = adc_valid_i0 && adc_enable_i0;
    wire q_now = adc_valid_q0 && adc_enable_q0;
    wire pair_ready = (i_pending || i_now) && (q_pending || q_now);
    wire [IQ_W-1:0] pair_i = i_now ? adc_data_i0 : i_latch;
    wire [IQ_W-1:0] pair_q = q_now ? adc_data_q0 : q_latch;
    wire fifo_wr = pair_ready && !fifo_full;
    wire [31:0] fifo_din = {pair_i, pair_q};

    always @(posedge l_clk or negedge l_rst_n) begin
        if (!l_rst_n) begin
            i_latch <= {IQ_W{1'b0}};
            q_latch <= {IQ_W{1'b0}};
            i_pending <= 1'b0;
            q_pending <= 1'b0;
            overflow_lclk <= 1'b0;
        end else begin
            if (i_now)
                i_latch <= adc_data_i0;
            if (q_now)
                q_latch <= adc_data_q0;

            if (pair_ready) begin
                i_pending <= 1'b0;
                q_pending <= 1'b0;
                if (fifo_full)
                    overflow_lclk <= 1'b1;
            end else begin
                if (i_now)
                    i_pending <= 1'b1;
                if (q_now)
                    q_pending <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // async FIFO (l_clk -> fabric)
    // ------------------------------------------------------------------------
    lr_async_fifo #(.DATA_W(32), .DEPTH(1024)) u_iq_fifo (
        .wr_clk   (l_clk),
        .wr_rst_n (l_rst_n),
        .wr_en    (fifo_wr),
        .din      (fifo_din),
        .full     (fifo_full),
        .rd_clk   (clk),
        .rd_rst_n (rst_n),
        .rd_en    (fifo_rd),
        .dout     (fifo_dout),
        .empty    (fifo_empty)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_overflow <= 1'b0;
            overflow_sync1 <= 1'b0;
            overflow_sync2 <= 1'b0;
        end else begin
            overflow_sync1 <= overflow_lclk;
            overflow_sync2 <= overflow_sync1;
            fifo_overflow  <= overflow_sync2;
        end
    end

    // ------------------------------------------------------------------------
    // Read side (fabric): stream 0 with metadata
    // ------------------------------------------------------------------------
    reg [7:0] frame_cnt;
    reg [63:0] ts_latch, sc_latch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata        <= {`LR_TDATA_W{1'b0}};
            m_tuser        <= {`LR_TUSER_W{1'b0}};
            m_tvalid       <= 1'b0;
            m_tlast        <= 1'b0;
            m_timestamp    <= 64'd0;
            m_sample_count <= 64'd0;
            ts_latch       <= 64'd0;
            sc_latch       <= 64'd0;
            frame_cnt      <= 8'd0;
        end else begin
            if (!m_tvalid || m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast  <= 1'b0;
            end
            if (fifo_rd) begin
                m_tdata  <= fifo_dout;
                m_tuser  <= {frame_cnt, `LR_CH_RX1, 6'd0};
                m_tvalid <= 1'b1;
                if (frame_cnt == 8'd0) begin
                    ts_latch <= timestamp;
                    sc_latch <= sample_count;
                    m_timestamp    <= timestamp;
                    m_sample_count <= sample_count;
                end
                if (frame_cnt == FRAME_LEN-1) begin
                    m_tlast   <= 1'b1;
                    frame_cnt <= 8'd0;
                end else begin
                    frame_cnt <= frame_cnt + 1'b1;
                end
            end
        end
    end

endmodule
