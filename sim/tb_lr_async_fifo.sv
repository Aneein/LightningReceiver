`timescale 1ns/1ps

module tb_lr_async_fifo;
    reg wr_clk = 0, rd_clk = 0;
    always #3 wr_clk = ~wr_clk;
    always #5 rd_clk = ~rd_clk;

    reg wr_rst_n = 0, rd_rst_n = 0;
    reg wr_en = 0, rd_en = 0;
    reg [7:0] din = 0;
    wire [7:0] dout;
    wire full, empty;
    integer i;

    lr_async_fifo #(.DATA_W(8), .DEPTH(8)) dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wr_en),
        .din(din), .full(full), .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .rd_en(rd_en), .dout(dout), .empty(empty)
    );

    task automatic write_byte(input [7:0] value);
        begin
            @(negedge wr_clk);
            while (full) @(negedge wr_clk);
            din = value;
            wr_en = 1;
            @(negedge wr_clk);
            wr_en = 0;
        end
    endtask

    task automatic read_byte(input [7:0] expected);
        begin
            @(negedge rd_clk);
            while (empty) @(negedge rd_clk);
            if (dout !== expected)
                $fatal(1, "FIFO order mismatch: got %h expected %h", dout, expected);
            rd_en = 1;
            @(negedge rd_clk);
            rd_en = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge wr_clk);
        wr_rst_n = 1;
        rd_rst_n = 1;

        for (i = 0; i < 8; i = i + 1)
            write_byte(8'h40 + i);
        @(negedge wr_clk);
        if (!full) $fatal(1, "FIFO did not assert full at DEPTH entries");

        for (i = 0; i < 8; i = i + 1)
            read_byte(8'h40 + i);
        @(negedge rd_clk);
        if (!empty) $fatal(1, "FIFO did not assert empty after all reads");

        // Verify wrap-bit logic by crossing the address boundary again.
        for (i = 0; i < 8; i = i + 1)
            write_byte(8'h80 + i);
        for (i = 0; i < 8; i = i + 1)
            read_byte(8'h80 + i);

        $display("TB_ASYNC_FIFO_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "async FIFO timeout");
    end
endmodule

