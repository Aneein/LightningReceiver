// Multi-bit level synchronizer.  Each bit must be an independent status level;
// this is not a coherent data-bus transfer primitive.
`timescale 1ns/1ps
module cdc_level_sync #(parameter WIDTH = 1) (
    input  wire             dst_clk,
    input  wire             dst_rst_n,
    input  wire [WIDTH-1:0] level_in,
    output wire [WIDTH-1:0] level_out
);
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync1, sync2;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            sync1 <= {WIDTH{1'b0}};
            sync2 <= {WIDTH{1'b0}};
        end else begin
            sync1 <= level_in;
            sync2 <= sync1;
        end
    end
    assign level_out = sync2;
endmodule
