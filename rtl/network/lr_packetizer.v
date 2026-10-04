// ============================================================================
// Lightning Receiver - LR Packetizer (stream -> LR frames -> UDP/IP/Eth)
// File: lr_packetizer.v
// ----------------------------------------------------------------------------
// Packs LR streams (flow-tagged AXIS, 32-bit) into LR frames, wraps them in
// UDP/IPv4/Ethernet headers, and outputs 512-bit AXIS for the CMAC (CAUI4).
// Layout per LR FPGA Full Design Spec Sec 5.7 (LR header) + standard
// Ethernet/IP/UDP headers. Single-stream TX for S3 (flow select + frame len).
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module lr_packetizer #(
    parameter FRAME_SAMPLES = 128,     // IQ samples per LR payload
    // Bring-up default is broadcast so an otherwise healthy 100G stream is
    // visible before the ConnectX-4 port MAC/IP are frozen.  Integrators can
    // override these module parameters in the BD for normal unicast service.
    parameter MAC_DST = 48'hFF_FF_FF_FF_FF_FF,
    parameter MAC_SRC = 48'h02_00_00_00_00_01,
    parameter IP_DST  = 32'hFF_FF_FF_FF,   // limited broadcast (bring-up)
    parameter IP_SRC  = 32'hC0_A8_01_0A,   // 192.168.1.10 (FPGA)
    parameter UDP_DST = 16'h1F90,          // 8080
    parameter UDP_SRC = 16'h1F90
)(
    input  wire              clk,           // fabric 225 MHz
    input  wire              rst_n,
    input  wire [1:0]        flow_sel,      // stream to pack (0=raw_iq,3=audio)
    input  wire              tx_enable,
    // stream in (LR stream, 32-bit)
    input  wire [`LR_TDATA_W-1:0] s_tdata,
    input  wire [`LR_TUSER_W-1:0] s_tuser,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,
    // timestamp / counters
    input  wire [63:0]       timestamp,
    input  wire [63:0]       sample_count,
    // 512-bit AXIS out to CMAC
    output reg  [511:0]      m_tdata,
    output reg  [63:0]       m_tkeep,
    output reg               m_tvalid,
    input  wire              m_tready,
    output reg               m_tlast,
    // stats
    output reg  [31:0]       pkt_count,
    output reg               pkt_count_pulse,
    output wire              idle
);

    // ------------------------------------------------------------------------
    // LR header (32 bytes) + Eth(14) + IP(20) + UDP(8) = 74 bytes preamble
    // Payload: FRAME_SAMPLES * 4 bytes IQ
    // ------------------------------------------------------------------------
    localparam PREAMBLE_BYTES = 74;
    localparam PAYLOAD_BYTES  = FRAME_SAMPLES * 4;
    localparam TOTAL_BYTES    = PREAMBLE_BYTES + PAYLOAD_BYTES;
    localparam LAST_BYTES     = TOTAL_BYTES % 64;
    localparam [63:0] LAST_KEEP = (LAST_BYTES == 0) ?
                                   64'hFFFF_FFFF_FFFF_FFFF :
                                   (64'hFFFF_FFFF_FFFF_FFFF >> (64-LAST_BYTES));

    reg [7:0]  samp_cnt;
    reg [6:0]  head_idx;
    reg [31:0] sample_buf;
    reg [1:0]  sample_byte_idx;
    reg        sample_loaded;
    reg [63:0] timestamp_q;
    reg [63:0] sample_count_q;
    reg [1:0]  flow_q;

    // A packet is serialized two bytes per fabric cycle.  One byte/cycle is
    // insufficient for 61.44 Msps raw IQ once Ethernet overhead is included.
    // The 16-bit lane write also avoids a 512-bit read/modify/write mux.
    reg [5:0]   beat_len;
    wire        byte_ready = !m_tvalid || m_tready;

    // ------------------------------------------------------------------------
    // Preamble ROM content builder (Ethernet+IP+UDP+LR header)
    // byte 0..13 eth, 14..33 ip, 34..41 udp, 42..73 LR header
    // ------------------------------------------------------------------------
    function [15:0] ipv4_checksum;
        input [15:0] ip_total_len;
        reg [31:0] sum;
        begin
            sum = 32'h0000_4500 + ip_total_len + 16'h0000 + 16'h0000 +
                  16'h4011 + IP_SRC[31:16] + IP_SRC[15:0] +
                  IP_DST[31:16] + IP_DST[15:0];
            sum = {16'd0, sum[15:0]} + sum[31:16];
            sum = {16'd0, sum[15:0]} + sum[31:16];
            ipv4_checksum = ~sum[15:0];
        end
    endfunction

    function [7:0] preamble_byte;
        input [6:0] i;          // byte index 0..73
        input [31:0] seq;
        input [1:0] flow;
        input [63:0] ts;
        input [63:0] first_sample;
        reg [15:0] total_len;
        reg [15:0] udp_len;
        reg [15:0] ip_csum;
        begin
            total_len = TOTAL_BYTES - 14;         // IP total length
            udp_len   = TOTAL_BYTES - 34;         // UDP length
            ip_csum   = ipv4_checksum(total_len);
            case (i)
                7'd0: preamble_byte = MAC_DST[47:40];
                7'd1: preamble_byte = MAC_DST[39:32];
                7'd2: preamble_byte = MAC_DST[31:24];
                7'd3: preamble_byte = MAC_DST[23:16];
                7'd4: preamble_byte = MAC_DST[15:8];
                7'd5: preamble_byte = MAC_DST[7:0];
                7'd6: preamble_byte = MAC_SRC[47:40];
                7'd7: preamble_byte = MAC_SRC[39:32];
                7'd8: preamble_byte = MAC_SRC[31:24];
                7'd9: preamble_byte = MAC_SRC[23:16];
                7'd10: preamble_byte = MAC_SRC[15:8];
                7'd11: preamble_byte = MAC_SRC[7:0];
                7'd12: preamble_byte = 8'h08;
                7'd13: preamble_byte = 8'h00;     // EtherType IPv4
                7'd14: preamble_byte = 8'h45;     // IP ver/IHL
                7'd15: preamble_byte = 8'h00;
                7'd16: preamble_byte = total_len[15:8];
                7'd17: preamble_byte = total_len[7:0];
                7'd18: preamble_byte = 8'h00;     // ID
                7'd19: preamble_byte = 8'h00;
                7'd20: preamble_byte = 8'h00;     // flags/frag
                7'd21: preamble_byte = 8'h00;
                7'd22: preamble_byte = 8'h40;     // TTL
                7'd23: preamble_byte = 8'h11;     // UDP
                7'd24: preamble_byte = ip_csum[15:8];
                7'd25: preamble_byte = ip_csum[7:0];
                7'd26: preamble_byte = IP_SRC[31:24];
                7'd27: preamble_byte = IP_SRC[23:16];
                7'd28: preamble_byte = IP_SRC[15:8];
                7'd29: preamble_byte = IP_SRC[7:0];
                7'd30: preamble_byte = IP_DST[31:24];
                7'd31: preamble_byte = IP_DST[23:16];
                7'd32: preamble_byte = IP_DST[15:8];
                7'd33: preamble_byte = IP_DST[7:0];
                7'd34: preamble_byte = UDP_SRC[15:8];
                7'd35: preamble_byte = UDP_SRC[7:0];
                7'd36: preamble_byte = UDP_DST[15:8];
                7'd37: preamble_byte = UDP_DST[7:0];
                7'd38: preamble_byte = udp_len[15:8];
                7'd39: preamble_byte = udp_len[7:0];
                7'd40: preamble_byte = 8'h00;     // checksum
                7'd41: preamble_byte = 8'h00;
                // ---- LR header ----
                7'd42: preamble_byte = 8'h4C;     // "LR"
                7'd43: preamble_byte = 8'h52;
                7'd44: preamble_byte = 8'h00;     // protocol ver
                7'd45: preamble_byte = 8'h01;
                7'd46: preamble_byte = 8'h00;     // header len
                7'd47: preamble_byte = 8'h20;
                7'd48: preamble_byte = {6'd0, flow};
                7'd49: preamble_byte = 8'h00;     // channel
                7'd50: preamble_byte = seq[31:24];
                7'd51: preamble_byte = seq[23:16];
                7'd52: preamble_byte = seq[15:8];
                7'd53: preamble_byte = seq[7:0];
                7'd54: preamble_byte = ts[63:56];
                7'd55: preamble_byte = ts[55:48];
                7'd56: preamble_byte = ts[47:40];
                7'd57: preamble_byte = ts[39:32];
                7'd58: preamble_byte = ts[31:24];
                7'd59: preamble_byte = ts[23:16];
                7'd60: preamble_byte = ts[15:8];
                7'd61: preamble_byte = ts[7:0];
                7'd62: preamble_byte = PAYLOAD_BYTES[15:8];
                7'd63: preamble_byte = PAYLOAD_BYTES[7:0];
                7'd64: preamble_byte = 8'h00;     // payload format
                7'd65: preamble_byte = 8'h01;
                // First sample index.  The protocol header is still a 32-byte
                // compact form; this field is required for host continuity
                // checking and is more useful than reserved zero bytes.
                7'd66: preamble_byte = first_sample[63:56];
                7'd67: preamble_byte = first_sample[55:48];
                7'd68: preamble_byte = first_sample[47:40];
                7'd69: preamble_byte = first_sample[39:32];
                7'd70: preamble_byte = first_sample[31:24];
                7'd71: preamble_byte = first_sample[23:16];
                7'd72: preamble_byte = first_sample[15:8];
                7'd73: preamble_byte = first_sample[7:0];
                default: preamble_byte = 8'h00;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------------
    // TX FSM
    // ------------------------------------------------------------------------
    reg [1:0]  fstate;
    localparam F_IDLE = 2'd0, F_HEAD = 2'd1, F_PAYLOAD = 2'd2;
    assign idle = (fstate == F_IDLE) && !m_tvalid;

    task push_pair;
        input [15:0] pair_value;
        input       packet_last;
        begin
            m_tdata[beat_len*8 +: 16] <= pair_value;
            if (beat_len == 6'd62) begin
                m_tkeep  <= 64'hFFFF_FFFF_FFFF_FFFF;
                m_tvalid <= 1'b1;
                m_tlast  <= packet_last;
                beat_len <= 6'd0;
            end else if (packet_last) begin
                m_tkeep  <= LAST_KEEP;
                m_tvalid <= 1'b1;
                m_tlast  <= 1'b1;
                beat_len <= 6'd0;
            end else begin
                beat_len <= beat_len + 2'd2;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate <= F_IDLE;
            samp_cnt <= 8'd0;
            head_idx <= 7'd0;
            sample_buf <= 32'd0;
            sample_byte_idx <= 2'd0;
            sample_loaded <= 1'b0;
            timestamp_q <= 64'd0;
            sample_count_q <= 64'd0;
            flow_q <= 2'd0;
            beat_len <= 6'd0;
            m_tdata <= 512'd0;
            m_tkeep <= 64'd0;
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
            pkt_count <= 32'd0;
            pkt_count_pulse <= 1'b0;
        end else begin
            pkt_count_pulse <= 1'b0;
            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast <= 1'b0;
            end
            case (fstate)
                F_IDLE: begin
                    // Do not consume the first sample until all 74 header bytes
                    // are queued.  AXI-stream guarantees it remains stable.
                    if (tx_enable && s_tvalid && byte_ready) begin
                        fstate <= F_HEAD;
                        head_idx <= 7'd0;
                        samp_cnt <= 8'd0;
                        sample_loaded <= 1'b0;
                        timestamp_q <= timestamp;
                        sample_count_q <= sample_count;
                        flow_q <= flow_sel;
                    end
                end
                F_HEAD: begin
                    if (byte_ready) begin
                        push_pair({preamble_byte(head_idx + 1'b1, pkt_count,
                                                 flow_q, timestamp_q,
                                                 sample_count_q),
                                   preamble_byte(head_idx, pkt_count, flow_q,
                                                 timestamp_q,
                                                 sample_count_q)}, 1'b0);
                        if (head_idx == PREAMBLE_BYTES-2) begin
                            fstate <= F_PAYLOAD;
                            sample_byte_idx <= 2'd0;
                        end else begin
                            head_idx <= head_idx + 2'd2;
                        end
                    end
                end
                F_PAYLOAD: begin
                    if (!sample_loaded) begin
                        if (s_tvalid && s_tready) begin
                            sample_buf <= s_tdata;
                            sample_byte_idx <= 2'd0;
                            sample_loaded <= 1'b1;
                        end
                    end else if (byte_ready) begin
                        push_pair(sample_buf[sample_byte_idx*8 +: 16],
                                  (samp_cnt == FRAME_SAMPLES-1) &&
                                  (sample_byte_idx == 2'd2));
                        if (sample_byte_idx == 2'd2) begin
                            sample_loaded <= 1'b0;
                            if (samp_cnt == FRAME_SAMPLES-1) begin
                                fstate <= F_IDLE;
                                pkt_count <= pkt_count + 1'b1;
                                pkt_count_pulse <= 1'b1;
                            end else begin
                                samp_cnt <= samp_cnt + 1'b1;
                            end
                        end else begin
                            sample_byte_idx <= 2'd2;
                        end
                    end
                end
                default: fstate <= F_IDLE;
            endcase
        end
    end

    assign s_tready = (fstate == F_PAYLOAD) && !sample_loaded;

endmodule
