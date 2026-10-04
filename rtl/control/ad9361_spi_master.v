// ============================================================================
// Lightning Receiver - AD9361 raw 24-bit SPI master
// ----------------------------------------------------------------------------
// Mode 1 (CPOL=0, CPHA=1), MSB first, matching the official ADI no-OS
// AD9361 driver.  Software supplies the complete 24-bit AD9361 wire
// transaction through the LR register bank, which avoids baking a partial or
// board-specific initialization table into RTL.  CLK_DIV=12 at 225.015 MHz
// produces a 9.376 MHz SPI clock (AD9361 limit: 10 MHz).
// ============================================================================
`timescale 1ns/1ps

module lr_ad9361_spi_controller #(
    parameter integer CLK_DIV = 12
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [23:0] transaction_tx,
    output reg  [23:0] transaction_rx,
    output reg         busy,
    output reg         done,
    output reg         spi_csn,
    output reg         serial_out,
    output reg         spi_mosi,
    input  wire        spi_miso
);

    localparam DIV_W = $clog2(CLK_DIV);
    reg [DIV_W-1:0] div_cnt;
    reg [4:0] bit_cnt;
    reg phase;
    reg [23:0] tx_shift, rx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            transaction_rx <= 24'd0;
            busy <= 1'b0;
            done <= 1'b0;
            spi_csn <= 1'b1;
            serial_out <= 1'b0;
            spi_mosi <= 1'b0;
            div_cnt <= {DIV_W{1'b0}};
            bit_cnt <= 5'd0;
            phase <= 1'b0;
            tx_shift <= 24'd0;
            rx_shift <= 24'd0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                spi_csn <= 1'b1;
                serial_out <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    spi_csn <= 1'b0;
                    // CPHA=1: MOSI is launched on the first rising edge.
                    spi_mosi <= 1'b0;
                    tx_shift <= transaction_tx;
                    rx_shift <= 24'd0;
                    bit_cnt <= 5'd23;
                    phase <= 1'b0;
                    div_cnt <= CLK_DIV-1;
                end
            end else if (div_cnt != 0) begin
                div_cnt <= div_cnt - 1'b1;
            end else begin
                div_cnt <= CLK_DIV-1;
                if (!phase) begin
                    // Leading/rising edge: launch the current MOSI bit.
                    serial_out <= 1'b1;
                    spi_mosi <= tx_shift[23];
                    phase <= 1'b1;
                end else begin
                    // Trailing/falling edge: both ends sample Mode-1 data.
                    serial_out <= 1'b0;
                    phase <= 1'b0;
                    rx_shift <= {rx_shift[22:0], spi_miso};
                    if (bit_cnt == 0) begin
                        spi_csn <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        transaction_rx <= {rx_shift[22:0], spi_miso};
                        spi_mosi <= 1'b0;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                        tx_shift <= {tx_shift[22:0], 1'b0};
                    end
                end
            end
        end
    end
endmodule
