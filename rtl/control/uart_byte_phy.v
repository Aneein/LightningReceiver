// ============================================================================
// Lightweight 8-N-1 UART byte PHY for the LR text command channel.
// ============================================================================
`timescale 1ns/1ps

module lr_uart_byte_phy #(
    parameter integer CLK_HZ = 225_014_957,
    parameter integer BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       uart_rx,
    output reg        uart_tx,
    output reg        rx_valid,
    output reg [7:0]  rx_data,
    input  wire       tx_load,
    input  wire [7:0] tx_data,
    output reg        tx_busy,
    output reg        framing_error
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer CNT_W = $clog2(CLKS_PER_BIT);

    (* ASYNC_REG = "TRUE" *) reg rx_meta, rx_sync;
    reg [1:0] rx_state;
    localparam RX_IDLE = 2'd0, RX_START = 2'd1,
               RX_DATA = 2'd2, RX_STOP = 2'd3;
    reg [CNT_W-1:0] rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift;

    reg [CNT_W-1:0] tx_count;
    reg [3:0] tx_bit;
    reg [9:0] tx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= uart_rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE;
            rx_count <= {CNT_W{1'b0}};
            rx_bit <= 3'd0;
            rx_shift <= 8'd0;
            rx_valid <= 1'b0;
            rx_data <= 8'd0;
            framing_error <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            framing_error <= 1'b0;
            case (rx_state)
                RX_IDLE: if (!rx_sync) begin
                    rx_count <= CLKS_PER_BIT/2;
                    rx_state <= RX_START;
                end
                RX_START: if (rx_count == 0) begin
                    if (!rx_sync) begin
                        rx_count <= CLKS_PER_BIT-1;
                        rx_bit <= 3'd0;
                        rx_state <= RX_DATA;
                    end else begin
                        rx_state <= RX_IDLE;
                    end
                end else rx_count <= rx_count - 1'b1;
                RX_DATA: if (rx_count == 0) begin
                    rx_shift[rx_bit] <= rx_sync;
                    rx_count <= CLKS_PER_BIT-1;
                    if (rx_bit == 3'd7)
                        rx_state <= RX_STOP;
                    else
                        rx_bit <= rx_bit + 1'b1;
                end else rx_count <= rx_count - 1'b1;
                RX_STOP: if (rx_count == 0) begin
                    if (rx_sync) begin
                        rx_data <= rx_shift;
                        rx_valid <= 1'b1;
                    end else begin
                        framing_error <= 1'b1;
                    end
                    rx_state <= RX_IDLE;
                end else rx_count <= rx_count - 1'b1;
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx <= 1'b1;
            tx_busy <= 1'b0;
            tx_count <= {CNT_W{1'b0}};
            tx_bit <= 4'd0;
            tx_shift <= 10'h3ff;
        end else if (!tx_busy) begin
            uart_tx <= 1'b1;
            if (tx_load) begin
                tx_shift <= {1'b1, tx_data, 1'b0};
                uart_tx <= 1'b0;
                tx_count <= CLKS_PER_BIT-1;
                tx_bit <= 4'd0;
                tx_busy <= 1'b1;
            end
        end else if (tx_count != 0) begin
            tx_count <= tx_count - 1'b1;
        end else if (tx_bit == 4'd9) begin
            uart_tx <= 1'b1;
            tx_busy <= 1'b0;
        end else begin
            tx_bit <= tx_bit + 1'b1;
            uart_tx <= tx_shift[tx_bit + 1'b1];
            tx_count <= CLKS_PER_BIT-1;
        end
    end
endmodule
