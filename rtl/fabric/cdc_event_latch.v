// Sticky source-domain event capture followed by a two-flop destination sync.
// Events cannot be missed even when the destination clock is slower.
`timescale 1ns/1ps
module lr_cdc_event_latch #(parameter WIDTH = 1) (
    input  wire             src_clk,
    input  wire             clear_i,
    input  wire [WIDTH-1:0] event_in,
    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output wire [WIDTH-1:0] event_seen
);
    reg [WIDTH-1:0] sticky_src;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync1, sync2;
    always @(posedge src_clk) begin
        if (clear_i)
            sticky_src <= {WIDTH{1'b0}};
        else
            sticky_src <= sticky_src | event_in;
    end
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            sync1 <= {WIDTH{1'b0}};
            sync2 <= {WIDTH{1'b0}};
        end else begin
            sync1 <= sticky_src;
            sync2 <= sync1;
        end
    end
    assign event_seen = sync2;
endmodule
