// ============================================================================
// Lightning Receiver - Button Controller
// File: button_controller.v
// ----------------------------------------------------------------------------
// Debounce (10 ms) + press-edge detect for 4 board keys (active low).
// key_level is the debounced *pressed* state (active high) for hold/combo
// detection in the front-panel controller.
// ============================================================================
`timescale 1ns/1ps

module lr_button_controller #(
    parameter NUM_KEYS    = 4,
    parameter CLK_HZ      = 100_000_000,
    parameter DEBOUNCE_MS = 10
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [NUM_KEYS-1:0] key_in,       // active low
    output reg  [NUM_KEYS-1:0] key_press,
    output reg  [NUM_KEYS-1:0] key_toggle,
    output wire [NUM_KEYS-1:0] key_level
);

    localparam DEBOUNCE_CNT = CLK_HZ / 1000 * DEBOUNCE_MS;  // 1e6 @100MHz

    (* ASYNC_REG = "TRUE" *) reg [NUM_KEYS-1:0] key_sync0, key_sync1;
    reg [NUM_KEYS-1:0] key_stable, key_stable_prev;
    reg [NUM_KEYS-1:0] pending;
    reg [19:0]         cnt;
    reg                cnt_running;

    assign key_level = ~key_stable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync0 <= {NUM_KEYS{1'b1}};
            key_sync1 <= {NUM_KEYS{1'b1}};
        end else begin
            key_sync0 <= key_in;
            key_sync1 <= key_sync0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_stable <= {NUM_KEYS{1'b1}};
            key_stable_prev <= {NUM_KEYS{1'b1}};
            key_press <= {NUM_KEYS{1'b0}};
            key_toggle <= {NUM_KEYS{1'b0}};
            cnt <= 20'd0;
            pending <= {NUM_KEYS{1'b1}};
            cnt_running <= 1'b0;
        end else begin
            key_press <= {NUM_KEYS{1'b0}};
            if (key_sync1 != pending) begin
                pending <= key_sync1;
                cnt <= 20'd0;
                cnt_running <= 1'b1;
            end else if (cnt_running) begin
                if (cnt == DEBOUNCE_CNT-1) begin
                    cnt_running <= 1'b0;
                    key_stable <= pending;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
            key_press <= ~key_stable & key_stable_prev;
            key_toggle <= key_toggle ^ (~key_stable & key_stable_prev);
            key_stable_prev <= key_stable;
        end
    end

endmodule
