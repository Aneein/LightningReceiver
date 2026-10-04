`timescale 1ns/1ps

module tb_ad9361_spi_master;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg start = 0;
    reg [23:0] transaction_tx = 24'hA5_3C_96;
    wire [23:0] transaction_rx;
    wire busy, done, spi_csn, serial_out, spi_mosi;
    reg spi_miso = 0;
    localparam [23:0] RESPONSE = 24'h5A_C3_69;
    reg [23:0] captured_tx = 0;
    integer rises = 0;
    integer falls = 0;
    integer bit_index = 23;

    lr_ad9361_spi_controller #(.CLK_DIV(3)) dut (.*);

    // Independent CPOL=0/CPHA=1 slave model.  It changes MISO on each rising
    // edge and samples MOSI on each falling edge, so a Mode-0 master cannot
    // pass merely because both sides share the same mistaken edge convention.
    always @(posedge serial_out) begin
        if (rst_n) begin
            spi_miso = RESPONSE[bit_index];
            rises = rises + 1;
        end
    end

    always @(negedge serial_out) begin
        if (rst_n && falls < 24) begin
            captured_tx[bit_index] = spi_mosi;
            falls = falls + 1;
            if (bit_index > 0)
                bit_index = bit_index - 1;
        end
    end

    always @(posedge clk) begin
        if (busy && spi_csn) $fatal(1, "CS deasserted while busy");
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;
        wait (done);
        #1;
        if (rises != 24) $fatal(1, "expected 24 clocks, got %0d", rises);
        if (falls != 24) $fatal(1, "expected 24 samples, got %0d", falls);
        if (captured_tx !== transaction_tx)
            $fatal(1, "mode-1 MOSI mismatch: %h != %h", captured_tx, transaction_tx);
        if (transaction_rx !== RESPONSE)
            $fatal(1, "mode-1 MISO mismatch: %h != %h", transaction_rx, RESPONSE);
        if (!spi_csn || serial_out) $fatal(1, "SPI did not return idle");
        $display("TB_AD9361_SPI_MASTER_PASS");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "SPI timeout");
    end
endmodule
