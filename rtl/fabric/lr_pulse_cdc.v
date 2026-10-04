// ============================================================================
// Lightning Receiver - Pulse CDC (single-bit pulse across clock domains)
// File: lr_pulse_cdc.v
// ----------------------------------------------------------------------------
// Standard toggle-based pulse synchronizer: a src_clk pulse toggles a flag;
// the flag is double-synchronized into dst_clk and edge-detected to regenerate
// a single dst_clk pulse.  Safe for src pulses of any width (no missed events,
// no metastability), at the cost of up to ~2 dst_clk cycles of latency.
// Used e.g. for 100 MHz button events counted in the 225 MHz fabric domain.
// ============================================================================
`timescale 1ns/1ps

module lr_pulse_cdc #(
    parameter WIDTH = 1
)(
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire [WIDTH-1:0] pulse_in,
    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output wire [WIDTH-1:0] pulse_out
);

    reg [WIDTH-1:0] toggle_src;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync1, sync2;
    reg [WIDTH-1:0] prev;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            toggle_src <= {WIDTH{1'b0}};
        else
            toggle_src <= toggle_src ^ pulse_in;
    end

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            sync1 <= {WIDTH{1'b0}};
            sync2 <= {WIDTH{1'b0}};
            prev  <= {WIDTH{1'b0}};
        end else begin
            sync1 <= toggle_src;
            sync2 <= sync1;
            prev  <= sync2;
        end
    end

    assign pulse_out = sync2 ^ prev;

endmodule
