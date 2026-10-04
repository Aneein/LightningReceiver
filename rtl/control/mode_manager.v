// ============================================================================
// Lightning Receiver - Mode Manager
// File: mode_manager.v
// ----------------------------------------------------------------------------
// Mode state machine (FM / General SDR). mode_changed pulse on transition.
// ============================================================================
`timescale 1ns/1ps

module mode_manager #(
    parameter MODE_W = 2
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [MODE_W-1:0] mode_sel,
    input  wire              mode_load,
    output reg  [MODE_W-1:0] mode_active,
    output reg              mode_changed,
    output wire             mode_valid
);

    localparam [MODE_W-1:0] M_FM = 2'd0, M_GENERAL_SDR = 2'd1;

    assign mode_valid = (mode_active == M_FM) || (mode_active == M_GENERAL_SDR);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_active <= M_FM;
            mode_changed <= 1'b0;
        end else begin
            mode_changed <= 1'b0;
            if (mode_load &&
                ((mode_sel == M_FM) || (mode_sel == M_GENERAL_SDR)) &&
                (mode_sel != mode_active)) begin
                mode_active <= mode_sel;
                mode_changed <= 1'b1;
            end
        end
    end

endmodule
