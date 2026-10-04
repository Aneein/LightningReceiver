`timescale 1ns/1ps

module tb_uart_byte_phy;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    wire uart_line;
    wire rx_valid;
    wire [7:0] rx_data;
    reg tx_load = 0;
    reg [7:0] tx_data = 0;
    wire tx_busy, framing_error;

    lr_uart_byte_phy #(.CLK_HZ(1000), .BAUD(100)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_line),
        .uart_tx(uart_line), .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_load(tx_load), .tx_data(tx_data), .tx_busy(tx_busy),
        .framing_error(framing_error));

    initial begin
        repeat (4) @(posedge clk); rst_n <= 1;
        @(posedge clk); tx_data <= 8'hA6; tx_load <= 1;
        @(posedge clk); tx_load <= 0;
        wait (rx_valid); #1;
        if (rx_data != 8'hA6 || framing_error)
            $fatal(1, "UART loopback failed: %h", rx_data);
        wait (!tx_busy);
        $display("TB_UART_BYTE_PHY_PASS");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "UART PHY timeout");
    end
endmodule
