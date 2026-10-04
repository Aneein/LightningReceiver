`timescale 1ns/1ps

module tb_raw_iq_router;
    reg clk = 0, l_clk = 0;
    always #2 clk = ~clk;
    always #3 l_clk = ~l_clk;

    reg rst_n = 0, l_rst_n = 0;
    reg adc_enable_i0 = 1, adc_valid_i0 = 0;
    reg adc_enable_q0 = 1, adc_valid_q0 = 0;
    reg [15:0] adc_data_i0 = 0, adc_data_q0 = 0;
    wire [31:0] m_tdata;
    wire [15:0] m_tuser;
    wire m_tvalid, m_tlast, sample_accepted, fifo_overflow;
    reg m_tready = 1;
    wire [63:0] m_timestamp, m_sample_count;
    integer seen = 0;
    reg [31:0] expected [0:3];

    raw_iq_router #(.FRAME_LEN(4)) dut (
        .clk(clk), .rst_n(rst_n), .l_clk(l_clk), .l_rst_n(l_rst_n),
        .adc_enable_i0(adc_enable_i0), .adc_valid_i0(adc_valid_i0),
        .adc_data_i0(adc_data_i0), .adc_enable_q0(adc_enable_q0),
        .adc_valid_q0(adc_valid_q0), .adc_data_q0(adc_data_q0),
        .timestamp(64'h1234), .sample_count(64'h5678),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast),
        .m_timestamp(m_timestamp), .m_sample_count(m_sample_count),
        .sample_accepted(sample_accepted), .fifo_overflow(fifo_overflow)
    );

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            if (m_tdata !== expected[seen])
                $fatal(1, "IQ pair %0d got %h expected %h", seen, m_tdata, expected[seen]);
            if (m_tlast !== (seen == 3))
                $fatal(1, "TLAST mismatch at pair %0d", seen);
            seen <= seen + 1;
        end
    end

    task automatic send_pair(input [15:0] i, input [15:0] q);
        begin
            @(negedge l_clk);
            adc_data_i0 = i; adc_data_q0 = q;
            adc_valid_i0 = 1; adc_valid_q0 = 1;
            @(negedge l_clk);
            adc_valid_i0 = 0; adc_valid_q0 = 0;
        end
    endtask

    initial begin
        expected[0] = 32'h1001_2001;
        expected[1] = 32'h1002_2002;
        expected[2] = 32'h1003_2003;
        expected[3] = 32'h1004_2004;
        repeat (5) @(posedge clk);
        rst_n = 1; l_rst_n = 1;
        send_pair(16'h1001, 16'h2001);
        send_pair(16'h1002, 16'h2002);
        send_pair(16'h1003, 16'h2003);
        send_pair(16'h1004, 16'h2004);
        wait (seen == 4);
        if (fifo_overflow) $fatal(1, "unexpected FIFO overflow");
        $display("TB_RAW_IQ_ROUTER_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "raw IQ router timeout");
    end
endmodule
