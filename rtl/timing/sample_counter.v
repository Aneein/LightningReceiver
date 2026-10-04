// ============================================================================
// Lightning Receiver - Sample Counter
// File: sample_counter.v
// ----------------------------------------------------------------------------
// 64-bit sample counter, incremented per valid IQ sample (AD9361 domain).
// ============================================================================
`timescale 1ns/1ps

module sample_counter #(
    parameter WIDTH = 64
)(
    input  wire             clk,          // AD9361 data clock domain
    input  wire             rst_n,
    input  wire             clear,
    input  wire             enable,
    input  wire             count_enable,
    output reg [WIDTH-1:0]  count_value,
    output wire             carry
);

    assign carry = (count_value == {WIDTH{1'b1}}) && count_enable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count_value <= {WIDTH{1'b0}};
        else if (clear)
            count_value <= {WIDTH{1'b0}};
        else if (enable && count_enable)
            count_value <= count_value + 1'b1;
    end

endmodule
