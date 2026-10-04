// ============================================================================
// Lightning Receiver - Telemetry Aggregator
// File: telemetry.v
// ----------------------------------------------------------------------------
// Counter bank + error aggregation (Master Spec Sec 23). Saturation at
// 0xFFFF_FFFF; clear_all resets; uptime driven by 1 Hz strobe on inc[15].
// ============================================================================
`timescale 1ns/1ps

module telemetry #(
    parameter NUM_COUNTERS = 16,
    parameter CLK_HZ       = 225_000_000
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire [NUM_COUNTERS-1:0] inc,
    input  wire [7:0]          err_strobe,
    input  wire [5:0]          addr,        // read address (offset/4)
    output reg  [31:0]         rdata,
    input  wire                clear_all,
    output reg  [31:0]         err_status,
    output reg                 err_pulse,
    output reg  [31:0]         uptime_sec
);

    reg [31:0] cnt [0:NUM_COUNTERS-1];
    reg [31:0] sec_div;
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_COUNTERS; i = i + 1)
                cnt[i] <= 32'd0;
            uptime_sec <= 32'd0;
            sec_div <= 32'd0;
            err_status <= 32'd0;
            err_pulse <= 1'b0;
        end else begin
            err_pulse <= 1'b0;
            if (sec_div == CLK_HZ-1) begin
                sec_div <= 32'd0;
                uptime_sec <= uptime_sec + 1'b1;
            end else begin
                sec_div <= sec_div + 1'b1;
            end

            for (i = 0; i < NUM_COUNTERS; i = i + 1) begin
                if (clear_all)
                    cnt[i] <= 32'd0;
                else if (inc[i] && (cnt[i] != 32'hFFFF_FFFF))
                    cnt[i] <= cnt[i] + 1'b1;
            end

            if (clear_all)
                err_status <= 32'd0;
            else if (err_strobe != 8'd0) begin
                if ((err_status[7:0] & err_strobe) != err_strobe) begin
                    err_status[7:0] <= err_status[7:0] | err_strobe;
                    err_pulse <= 1'b1;
                end
            end

        end
    end

    // Combinational read matches AXI-Lite's registered address/response timing
    // in register_bank; a registered read here returned the previous counter.
    always @(*) begin
        if (addr < NUM_COUNTERS)
            rdata = cnt[addr];
        else
            rdata = 32'd0;
    end

endmodule
