`timescale 1ns/1ps

module tb_signal_detector;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst_n = 0;
    reg [31:0] sdata = 0;
    reg svalid = 0, slast = 0;
    wire sready;
    wire [63:0] evdata;
    wire evvalid;
    reg evready = 0;
    wire evpulse;
    reg [63:0] held;

    signal_detector dut (
        .clk(clk), .rst_n(rst_n), .threshold(16'd50),
        .min_bin(16'd1), .max_bin(16'd3), .enable(1'b1),
        .ts_in(32'h1234_5678), .s_tdata(sdata), .s_tvalid(svalid),
        .s_tready(sready), .s_tlast(slast), .ev_tdata(evdata),
        .ev_tvalid(evvalid), .ev_tready(evready),
        .ev_count_pulse(evpulse)
    );

    task automatic send_bin(input [15:0] bin, input [15:0] power, input last);
        begin
            @(negedge clk); sdata = {bin, power}; svalid = 1; slast = last;
            do @(posedge clk); while (!sready);
            @(negedge clk); svalid = 0; slast = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        send_bin(0, 10, 0);
        send_bin(1, 70, 0);
        send_bin(2, 100, 0);
        send_bin(3, 80, 1);
        wait (evvalid); #1;
        held = evdata;
        if (evdata !== {16'd2, 16'd100, 32'h1234_5678})
            $fatal(1, "detector chose wrong peak: %h", evdata);
        repeat (4) begin
            @(posedge clk); #1;
            if (!evvalid || evdata !== held || sready)
                $fatal(1, "detector did not hold event under backpressure");
        end
        evready = 1;
        @(posedge clk); #1;
        if (evvalid) $fatal(1, "detector valid did not clear after handshake");
        $display("TB_SIGNAL_DETECTOR_PASS");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "signal detector timeout");
    end
endmodule

