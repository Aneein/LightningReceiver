`timescale 1ns/1ps

module tb_lr_packetizer;
    reg clk = 0;
    always #2 clk = ~clk;

    reg rst_n = 0;
    reg [1:0] flow_sel = 2'd3;
    reg tx_enable = 1;
    reg [31:0] s_tdata = 0;
    reg [15:0] s_tuser = 0;
    reg s_tvalid = 0;
    wire s_tready;
    reg s_tlast = 0;
    reg [63:0] timestamp = 64'h0123_4567_89AB_CDEF;
    reg [63:0] sample_count = 0;
    wire [511:0] m_tdata;
    wire [63:0] m_tkeep;
    wire m_tvalid;
    reg m_tready = 0;
    wire m_tlast;
    wire [31:0] pkt_count;
    wire pkt_count_pulse;
    wire idle;

    reg [511:0] beats [0:1];
    reg [63:0] keeps [0:1];
    reg lasts [0:1];
    integer beat_count = 0;
    integer i;
    integer sum;

    lr_packetizer #(.FRAME_SAMPLES(2)) dut (
        .clk(clk), .rst_n(rst_n), .flow_sel(flow_sel),
        .tx_enable(tx_enable), .s_tdata(s_tdata), .s_tuser(s_tuser),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
        .timestamp(timestamp), .sample_count(sample_count),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast),
        .pkt_count(pkt_count), .pkt_count_pulse(pkt_count_pulse), .idle(idle)
    );

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            if (beat_count > 1) $fatal(1, "too many output beats");
            beats[beat_count] <= m_tdata;
            keeps[beat_count] <= m_tkeep;
            lasts[beat_count] <= m_tlast;
            beat_count <= beat_count + 1;
        end
    end

    function automatic [7:0] pkt_byte(input integer index);
        if (index < 64)
            pkt_byte = beats[0][index*8 +: 8];
        else
            pkt_byte = beats[1][(index-64)*8 +: 8];
    endfunction

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        fork
            begin : source_driver
                s_tdata = 32'h1122_3344;
                s_tvalid = 1;

                // First sample is held while the header is serialized.
                do @(posedge clk); while (!s_tready);
                #1 s_tdata = 32'hA1B2_C3D4;
                do @(posedge clk); while (!s_tready);
                #1 s_tvalid = 0;
            end
            begin : sink_backpressure
                // Deliberately stall the first CMAC beat and require perfect
                // holding while the source independently waits for TREADY.
                wait (m_tvalid);
                #1;
                begin : stall_check
                    reg [511:0] held_data;
                    reg [63:0] held_keep;
                    reg held_last;
                    held_data = m_tdata;
                    held_keep = m_tkeep;
                    held_last = m_tlast;
                    repeat (3) begin
                        @(posedge clk); #1;
                        if (!m_tvalid || m_tdata !== held_data ||
                            m_tkeep !== held_keep || m_tlast !== held_last)
                            $fatal(1, "packetizer changed output under backpressure");
                    end
                end
                m_tready = 1;
            end
        join

        wait (beat_count == 2);
        @(posedge clk); #1;

        if (keeps[0] !== 64'hFFFF_FFFF_FFFF_FFFF || lasts[0] !== 1'b0)
            $fatal(1, "first beat keep/last is wrong");
        if (keeps[1] !== 64'h0000_0000_0003_FFFF || lasts[1] !== 1'b1)
            $fatal(1, "last beat keep/last is wrong: keep=%h", keeps[1]);

        if (pkt_byte(0) != 8'hff || pkt_byte(5) != 8'hff ||
            pkt_byte(12) != 8'h08 || pkt_byte(13) != 8'h00)
            $fatal(1, "Ethernet header mismatch");
        if (pkt_byte(42) != 8'h4c || pkt_byte(43) != 8'h52 ||
            pkt_byte(48) != 8'h03)
            $fatal(1, "LR header mismatch");
        if (pkt_byte(54) != 8'h01 || pkt_byte(61) != 8'hef ||
            pkt_byte(62) != 8'h00 || pkt_byte(63) != 8'h08)
            $fatal(1, "timestamp or payload length mismatch");

        // Payload is little-endian per input word.
        if (pkt_byte(74) != 8'h44 || pkt_byte(75) != 8'h33 ||
            pkt_byte(76) != 8'h22 || pkt_byte(77) != 8'h11 ||
            pkt_byte(78) != 8'hd4 || pkt_byte(79) != 8'hc3 ||
            pkt_byte(80) != 8'hb2 || pkt_byte(81) != 8'ha1)
            $fatal(1, "payload serialization mismatch");

        // A valid IPv4 header has an all-ones one's-complement sum.
        sum = 0;
        for (i = 14; i < 34; i = i + 2)
            sum = sum + {pkt_byte(i), pkt_byte(i+1)};
        sum = (sum & 16'hffff) + (sum >> 16);
        sum = (sum & 16'hffff) + (sum >> 16);
        if ((sum & 16'hffff) != 16'hffff)
            $fatal(1, "IPv4 checksum mismatch: %h", sum);
        if (pkt_count != 1)
            $fatal(1, "packet count mismatch");

        $display("TB_PACKETIZER_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "packetizer timeout");
    end
endmodule
