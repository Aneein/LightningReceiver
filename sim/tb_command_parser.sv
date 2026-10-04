`timescale 1ns/1ps
`include "lr_defines.vh"

module tb_command_parser;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg rx_valid = 0;
    reg [7:0] rx_data = 0;
    wire tx_load;
    wire [7:0] tx_data;
    reg tx_busy = 0;
    wire cfg_wr_valid;
    wire [11:0] cfg_wr_addr;
    wire [31:0] cfg_wr_data;
    wire cfg_rd_valid;
    wire [11:0] cfg_rd_addr;
    reg [31:0] cfg_rd_data = 32'h1234_5678;
    wire [31:0] cmd_count, invalid_count;
    reg capture_tx = 0;
    reg [7:0] response [0:9];
    integer response_count = 0;

    command_parser dut (.*);

    task send_char(input [7:0] ch);
        begin
            @(posedge clk); rx_data <= ch; rx_valid <= 1;
            @(posedge clk); rx_valid <= 0;
        end
    endtask

    always @(posedge clk) begin
        if (capture_tx && tx_load && response_count < 10) begin
            response[response_count] = tx_data;
            response_count = response_count + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        send_char("M"); send_char("O"); send_char("D"); send_char("E");
        send_char(" "); send_char("1"); send_char(8'h0d);
        wait (cfg_wr_valid); #1;
        if (cfg_wr_addr != `LR_REG_MODE || cfg_wr_data != 32'd1)
            $fatal(1, "MODE command decode failed: %h %h",
                   cfg_wr_addr, cfg_wr_data);
        wait (cmd_count == 1);

        send_char("R"); send_char("F"); send_char("_"); send_char("S");
        send_char("E"); send_char("T"); send_char("_"); send_char("F");
        send_char("R"); send_char("E"); send_char("Q"); send_char(" ");
        send_char("9"); send_char("8"); send_char("0"); send_char("0");
        send_char("0"); send_char("0"); send_char("0"); send_char("0");
        send_char(8'h0d);
        wait (cfg_wr_valid); #1;
        if (cfg_wr_addr != `LR_REG_RF_FREQ || cfg_wr_data != 32'd98_000_000)
            $fatal(1, "RF_SET_FREQ decode failed: %h %0d",
                   cfg_wr_addr, cfg_wr_data);

        send_char("R"); send_char("F"); send_char("_"); send_char("S");
        send_char("E"); send_char("T"); send_char("_"); send_char("G");
        send_char("A"); send_char("I"); send_char("N"); send_char(" ");
        send_char("4"); send_char("2"); send_char(8'h0d);
        wait (cfg_wr_valid); #1;
        if (cfg_wr_addr != `LR_REG_RF_GAIN || cfg_wr_data != 32'd42)
            $fatal(1, "RF_SET_GAIN decode failed: %h %0d",
                   cfg_wr_addr, cfg_wr_data);

        repeat (20) @(posedge clk);
        response_count = 0;
        capture_tx = 1;
        send_char("S"); send_char("T"); send_char("A"); send_char("T");
        send_char("U"); send_char("S"); send_char(8'h0d);
        wait (response_count == 10);
        capture_tx = 0;
        if (response[0] != "1" || response[1] != "2" ||
            response[2] != "3" || response[3] != "4" ||
            response[4] != "5" || response[5] != "6" ||
            response[6] != "7" || response[7] != "8" ||
            response[8] != 8'h0d || response[9] != 8'h0a)
            $fatal(1, "STATUS response formatting failed");

        send_char("S"); send_char("P"); send_char("I"); send_char("_");
        send_char("T"); send_char("X"); send_char(" ");
        send_char("1"); send_char("1"); send_char("9"); send_char("3");
        send_char("0"); send_char("4"); send_char("6"); send_char(" ");
        send_char(8'h0d);
        wait (cfg_wr_valid); #1;
        if (cfg_wr_addr != `LR_REG_SPI_TX || cfg_wr_data != 32'd1193046)
            $fatal(1, "SPI_TX command decode failed: %h %0d",
                   cfg_wr_addr, cfg_wr_data);
        $display("SPI_TX decoded");

        send_char("S"); send_char("P"); send_char("I"); send_char("_");
        send_char("G"); send_char("O"); send_char(8'h0d);
        wait (cfg_wr_valid); #1;
        if (cfg_wr_addr != `LR_REG_SPI_CONTROL || cfg_wr_data != 32'd1)
            $fatal(1, "SPI_GO command decode failed: %h %0d",
                   cfg_wr_addr, cfg_wr_data);
        $display("SPI_GO decoded");

        cfg_rd_data = 32'h00AB_CDEF;
        send_char("S"); send_char("P"); send_char("I"); send_char("_");
        send_char("R"); send_char("X"); send_char(8'h0d);
        wait (cfg_rd_valid); #1;
        if (cfg_rd_addr != `LR_REG_SPI_RX)
            $fatal(1, "SPI_RX command decode failed: %h", cfg_rd_addr);
        $display("SPI_RX decoded");

        send_char("B"); send_char("A"); send_char("D"); send_char(8'h0d);
        wait (invalid_count == 1);
        if (cmd_count != 8) $fatal(1, "command counters failed: %0d", cmd_count);
        $display("TB_COMMAND_PARSER_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "command parser timeout count=%0d invalid=%0d pstate=%0d line_done=%0d",
               cmd_count, invalid_count, dut.pstate, dut.line_done);
    end
endmodule
