`timescale 1ns/1ps

module tb_button_controller;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [2:0] key_in = 3'b111;
    wire [2:0] key_press, key_toggle, key_level;
    integer pulses = 0;

    lr_button_controller #(
        .NUM_KEYS(3), .CLK_HZ(1000), .DEBOUNCE_MS(2)
    ) dut (.*);

    always @(posedge clk)
        if (key_press[0]) pulses <= pulses + 1;

    initial begin
        repeat (3) @(posedge clk); rst_n <= 1;
        key_in[0] <= 0;
        repeat (8) @(posedge clk); #1;
        if (pulses != 1 || key_toggle[0] != 1)
            $fatal(1, "first debounced press failed");
        if (key_level !== 3'b001) $fatal(1, "held key level wrong: %b", key_level);
        key_in[0] <= 1;
        repeat (8) @(posedge clk); #1;
        if (pulses != 1 || key_toggle[0] != 1)
            $fatal(1, "release generated a press");
        if (key_level !== 3'b000) $fatal(1, "released key level wrong: %b", key_level);
        key_in[0] <= 0;
        repeat (8) @(posedge clk); #1;
        if (pulses != 2 || key_toggle[0] != 0)
            $fatal(1, "second debounced press failed");
        $display("TB_BUTTON_CONTROLLER_PASS");
        $finish;
    end
endmodule
