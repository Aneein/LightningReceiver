// ============================================================================
// Lightning Receiver - Stream Metadata Injector
// File: stream_metadata.v
// ----------------------------------------------------------------------------
// Inserts timestamp/sample side-channel at frame head; TUSER passthrough.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module stream_metadata #(
    parameter TS_W = 64
)(
    input  wire              clk,
    input  wire              rst_n,
    // stream in
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    // timestamp side channel
    input  wire [TS_W-1:0]   timestamp,
    input  wire [TS_W-1:0]   sample_count,
    // stream out
    output reg  [`LR_TDATA_W-1:0] m_tdata,
    output reg  [`LR_TUSER_W-1:0] m_tuser,
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast,
    output reg  [TS_W-1:0]   m_timestamp,
    output reg  [TS_W-1:0]   m_sample_count
);

    assign s_tready = !m_tvalid || m_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata  <= {`LR_TDATA_W{1'b0}};
            m_tuser  <= {`LR_TUSER_W{1'b0}};
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
            m_timestamp   <= {TS_W{1'b0}};
            m_sample_count <= {TS_W{1'b0}};
        end else if (s_tready) begin
            if (s_tvalid) begin
                m_tdata  <= s_tdata;
                m_tuser  <= s_tuser;
                m_tvalid <= 1'b1;
                m_tlast  <= s_tlast;
                if (s_tlast) begin
                    m_timestamp   <= timestamp;
                    m_sample_count <= sample_count;
                end
            end else begin
                m_tvalid <= 1'b0;
            end
        end
    end

endmodule
