// ============================================================================
// Lightning Receiver - Signal Detector
// File: signal_detector.v
// ----------------------------------------------------------------------------
// Consumes the PSD stream (TDATA={bin[15:0], power[15:0]}) and emits
// DETECT_EVENTS: the strongest peak above threshold within the scan window
// is reported once per frame as {freq_bin[15:0], power[15:0], ts[31:0]}.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module signal_detector (
    input  wire              clk,
    input  wire              rst_n,
    // config
    input  wire [15:0]       threshold,
    input  wire [15:0]       min_bin,
    input  wire [15:0]       max_bin,
    input  wire              enable,
    // timestamp side channel (latched at frame start)
    input  wire [31:0]       ts_in,
    // PSD stream in
    input  wire [31:0]       s_tdata,       // {bin[15:0], power[15:0]}
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    // event out
    output reg  [63:0]       ev_tdata,      // {freq_bin[15:0], power[15:0], ts[31:0]}
    output reg               ev_tvalid,
    input  wire              ev_tready,
    output reg               ev_count_pulse
);

    // Detection output is independent of ordinary PSD consumption.  Stall only
    // while a completed event is waiting for its consumer.
    assign s_tready = !ev_tvalid || ev_tready;

    reg [15:0] best_bin, best_power;
    reg        in_scan;
    reg [31:0] ts_latch;
    wire current_in_window = (s_tdata[31:16] >= min_bin) &&
                             (s_tdata[31:16] <= max_bin);
    wire current_is_better = current_in_window &&
                             (s_tdata[15:0] > best_power);
    wire [15:0] final_power = current_is_better ? s_tdata[15:0]
                                                  : best_power;
    wire [15:0] final_bin = current_is_better ? s_tdata[31:16]
                                               : best_bin;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            best_bin <= 16'd0;
            best_power <= 16'd0;
            in_scan <= 1'b0;
            ts_latch <= 32'd0;
            ev_tdata <= 64'd0;
            ev_tvalid <= 1'b0;
            ev_count_pulse <= 1'b0;
        end else begin
            // Hold the event payload/valid until the downstream accepts it.
            if (ev_tvalid && ev_tready)
                ev_tvalid <= 1'b0;
            ev_count_pulse <= 1'b0;

            if (s_tvalid && s_tready) begin
                if (s_tlast) begin
                    // frame end: report best peak if above threshold
                    if ((in_scan || current_in_window) && enable &&
                        (final_power >= threshold)) begin
                        ev_tdata <= {final_bin, final_power, ts_latch};
                        ev_tvalid <= 1'b1;
                        ev_count_pulse <= 1'b1;
                    end
                    in_scan <= 1'b0;
                    best_bin <= 16'd0;
                    best_power <= 16'd0;
                end else begin
                    if (s_tdata[31:16] == 16'd0)
                        ts_latch <= ts_in;   // frame head (bin 0)
                    if (current_in_window) begin
                        if (s_tdata[15:0] > best_power) begin
                            best_power <= s_tdata[15:0];
                            best_bin <= s_tdata[31:16];
                        end
                        in_scan <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
