// ============================================================================
// Lightning Receiver - Timestamp Counter
// File: timestamp_counter.v
// ----------------------------------------------------------------------------
// 64-bit free-running timestamp at clk_fabric. Stream side-channel source.
// ============================================================================
`timescale 1ns/1ps

module timestamp_counter #(
    parameter WIDTH = 64
)(
    input  wire             clk,
    input  wire             rst_n,        // async reset, active low
    input  wire             clear,        // sync clear
    input  wire             enable,       // run/stop
    output reg  [WIDTH-1:0] timestamp,
    output wire             tick
);

    assign tick = enable && (timestamp[8:0] == 9'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            timestamp <= {WIDTH{1'b0}};
        else if (clear)
            timestamp <= {WIDTH{1'b0}};
        else if (enable)
            timestamp <= timestamp + 1'b1;
    end

endmodule
