// ============================================================================
// Lightning Receiver - UART Command Parser
// File: command_parser.v
// ----------------------------------------------------------------------------
// Text command interface (Master Spec Sec 14.2). Line-based <CMD> [<value>].
// Consumes bytes from the physical UART byte PHY in the fabric clock domain,
// drives the register-bank secondary config port, and serializes responses.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module command_parser (
    input  wire          clk,           // fabric clock (225 MHz)
    input  wire          rst_n,
    // UART RX byte stream
    input  wire          rx_valid,
    input  wire [7:0]    rx_data,
    // TX byte stream
    output reg           tx_load,
    output reg  [7:0]    tx_data,
    input  wire          tx_busy,
    // register cfg ports (same domain)
    output reg           cfg_wr_valid,
    output reg  [11:0]   cfg_wr_addr,
    output reg  [31:0]   cfg_wr_data,
    output reg           cfg_rd_valid,
    output reg  [11:0]   cfg_rd_addr,
    input  wire [31:0]   cfg_rd_data,
    // status
    output reg  [31:0]   cmd_count,
    output reg  [31:0]   invalid_count
);

    // ================= line buffer =================
    reg [7:0]  lbuf [0:63];
    reg [5:0]  lbuf_len;
    reg [5:0]  line_len;
    reg        line_done;
    reg [31:0] arg_accum;
    reg [31:0] arg_line;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lbuf_len  <= 6'd0;
            line_len  <= 6'd0;
            line_done <= 1'b0;
            arg_accum <= 32'd0;
            arg_line  <= 32'd0;
        end else begin
            line_done <= 1'b0;
            if (rx_valid) begin
                if (rx_data == 8'h0A || rx_data == 8'h0D) begin
                    if (lbuf_len != 6'd0) begin
                        line_done <= 1'b1;
                        line_len <= lbuf_len;
                        arg_line <= arg_accum;
                    end
                    lbuf_len <= 6'd0;
                    arg_accum <= 32'd0;
                end else if (lbuf_len != 6'd63) begin
                    lbuf[lbuf_len] <= rx_data;
                    lbuf_len <= lbuf_len + 1'b1;
                    if (rx_data >= 8'h30 && rx_data <= 8'h39)
                        arg_accum <= (arg_accum << 3) + (arg_accum << 1) +
                                     (rx_data - 8'h30);
                end
            end
        end
    end

    // ================= token & arg =================
    function [7:0] up;
        input [7:0] c;
        begin
            up = (c >= 8'h61 && c <= 8'h7A) ? (c - 8'h20) : c;
        end
    endfunction

    reg [31:0] tok;
    reg [63:0] tok8;
    always @(*) begin
        tok = { up(lbuf[0]),
                (line_len > 6'd1) ? up(lbuf[1]) : 8'd0,
                (line_len > 6'd2) ? up(lbuf[2]) : 8'd0,
                (line_len > 6'd3) ? up(lbuf[3]) : 8'd0 };
        tok8 = {up(lbuf[0]),
                (line_len > 6'd1) ? up(lbuf[1]) : 8'd0,
                (line_len > 6'd2) ? up(lbuf[2]) : 8'd0,
                (line_len > 6'd3) ? up(lbuf[3]) : 8'd0,
                (line_len > 6'd4) ? up(lbuf[4]) : 8'd0,
                (line_len > 6'd5) ? up(lbuf[5]) : 8'd0,
                (line_len > 6'd6) ? up(lbuf[6]) : 8'd0,
                (line_len > 6'd7) ? up(lbuf[7]) : 8'd0};
    end

    // ================= TX FIFO (256 x 8) =================
    reg [7:0]  txfifo [0:255];
    reg [7:0]  tx_head, tx_tail;
    reg [8:0]  tx_cnt;
    wire       tx_full  = (tx_cnt == 9'd256);
    wire       tx_empty = (tx_cnt == 9'd0);

    reg        push_valid;
    reg [7:0]  push_data;
    wire       tx_push = push_valid && !tx_full;
    wire       tx_pop = !tx_empty && !tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_head <= 8'd0; tx_tail <= 8'd0; tx_cnt <= 9'd0;
            tx_load <= 1'b0; tx_data <= 8'd0;
        end else begin
            tx_load <= 1'b0;
            if (tx_push) begin
                txfifo[tx_tail] <= push_data;
                tx_tail <= tx_tail + 1'b1;
            end
            if (tx_pop) begin
                tx_data <= txfifo[tx_head];
                tx_load <= 1'b1;
                tx_head <= tx_head + 1'b1;
            end
            case ({tx_push, tx_pop})
                2'b10: tx_cnt <= tx_cnt + 1'b1;
                2'b01: tx_cnt <= tx_cnt - 1'b1;
                default: tx_cnt <= tx_cnt;
            endcase
        end
    end

    // ================= response writer =================
    localparam R_IDLE = 3'd0, R_STR = 3'd1, R_HELP = 3'd2, R_HEX = 3'd3,
               R_CR = 3'd4, R_LF = 3'd5;

    localparam [1031:0] HELP_TXT =
        {"VER STATUS MODE RF_SET_FREQ RF_SET_GAIN STREAM_EN DDC_FREQ DECIM FFT_CFG SPEC_CFG DET_CFG AUDIO_CFG DDR_MODE SPI_TX SPI_GO SPI_RX"};
    localparam [7:0] HELP_LEN = 8'd129;

    reg [2:0]  rstate;
    reg [3:0]  ridx;
    reg [7:0]  rhelp_idx;
    reg [63:0] rstr_shift;
    reg [31:0] rhex_latch;
    reg [63:0] resp_str_data;
    reg [31:0] resp_hex_data;
    reg        resp_req_str;
    reg        resp_req_help;
    reg        resp_req_hex;

    function [7:0] hexch;
        input [31:0] v;
        input [2:0]  idx;
        reg [3:0]    nib;
        begin
            nib = v[((7 - idx) * 4) +: 4];
            hexch = (nib < 10) ? (8'h30 + nib) : (8'h37 + nib);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE;
            ridx <= 4'd0; rhelp_idx <= 8'd0;
            rstr_shift <= 64'd0; rhex_latch <= 32'd0;
            push_valid <= 1'b0; push_data <= 8'd0;
        end else begin
            push_valid <= 1'b0;
            case (rstate)
                R_IDLE: begin
                    if (resp_req_str) begin
                        rstr_shift <= resp_str_data;
                        ridx <= 4'd0;
                        rstate <= R_STR;
                    end else if (resp_req_help) begin
                        rhelp_idx <= 8'd0;
                        rstate <= R_HELP;
                    end else if (resp_req_hex) begin
                        rhex_latch <= resp_hex_data;
                        ridx <= 4'd0;
                        rstate <= R_HEX;
                    end
                end
                R_STR: begin
                    if (!tx_full && ridx < 4'd8 &&
                        rstr_shift[63:56] != 8'd0) begin
                        push_valid <= 1'b1;
                        push_data  <= rstr_shift[63:56];
                        rstr_shift <= {rstr_shift[55:0], 8'd0};
                        ridx <= ridx + 1'b1;
                    end else begin
                        rstate <= R_CR;
                    end
                end
                R_HELP: begin
                    if (!tx_full && rhelp_idx < HELP_LEN) begin
                        push_valid <= 1'b1;
                        push_data  <= HELP_TXT[(HELP_LEN - 1'b1 - rhelp_idx)*8 +: 8];
                        rhelp_idx <= rhelp_idx + 1'b1;
                    end else begin
                        rstate <= R_CR;
                    end
                end
                R_HEX: begin
                    if (!tx_full && ridx < 4'd8) begin
                        push_valid <= 1'b1;
                        push_data  <= hexch(rhex_latch, ridx);
                        ridx <= ridx + 1'b1;
                    end else begin
                        rstate <= R_CR;
                    end
                end
                R_CR: begin
                    if (!tx_full) begin
                        push_valid <= 1'b1;
                        push_data  <= 8'h0D;
                        rstate <= R_LF;
                    end
                end
                R_LF: begin
                    if (!tx_full) begin
                        push_valid <= 1'b1;
                        push_data  <= 8'h0A;
                        rstate <= R_IDLE;
                    end
                end
            endcase
        end
    end

    // ================= parser FSM =================
    localparam P_IDLE = 2'd0, P_WAIT_RD0 = 2'd1, P_WAIT_RD1 = 2'd2;
    reg [1:0]  pstate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pstate <= P_IDLE;
            cmd_count <= 32'd0;
            invalid_count <= 32'd0;
            cfg_wr_valid <= 1'b0;
            cfg_wr_addr <= 12'd0;
            cfg_wr_data <= 32'd0;
            cfg_rd_valid <= 1'b0;
            cfg_rd_addr <= 12'd0;
            resp_req_str <= 1'b0;
            resp_req_help <= 1'b0;
            resp_req_hex <= 1'b0;
            resp_str_data <= 64'd0;
            resp_hex_data <= 32'd0;
        end else begin
            cfg_wr_valid <= 1'b0;
            cfg_rd_valid <= 1'b0;
            resp_req_str <= 1'b0;
            resp_req_help <= 1'b0;
            resp_req_hex <= 1'b0;

            case (pstate)
                P_IDLE: begin
                    if (line_done) begin
                        cmd_count <= cmd_count + 1'b1;
                        // The two documented RF_SET_* commands have the same
                        // first four characters; use eight for disambiguation.
                        if (tok8 == 64'h52465F5345545F46) begin // "RF_SET_F"
                            cfg_wr_valid <= 1'b1;
                            cfg_wr_addr  <= `LR_REG_RF_FREQ;
                            cfg_wr_data  <= arg_line;
                            resp_str_data <= 64'h4F4B210000000000;
                            resp_req_str <= 1'b1;
                        end else if (tok8 == 64'h52465F5345545F47) begin // "RF_SET_G"
                            cfg_wr_valid <= 1'b1;
                            cfg_wr_addr  <= `LR_REG_RF_GAIN;
                            cfg_wr_data  <= arg_line;
                            resp_str_data <= 64'h4F4B210000000000;
                            resp_req_str <= 1'b1;
                        end else if (tok8[63:16] == 48'h5350495F5458) begin // "SPI_TX"
                            // Decimal 24-bit wire transaction.  This exposes
                            // the existing register-driven SPI engine over the
                            // board UART so ADI no-OS initialization does not
                            // depend on a live JTAG AXI session.
                            cfg_wr_valid <= 1'b1;
                            cfg_wr_addr  <= `LR_REG_SPI_TX;
                            cfg_wr_data  <= arg_line;
                            resp_str_data <= 64'h4F4B210000000000;
                            resp_req_str <= 1'b1;
                        end else if (tok8[63:16] == 48'h5350495F474F) begin // "SPI_GO"
                            cfg_wr_valid <= 1'b1;
                            cfg_wr_addr  <= `LR_REG_SPI_CONTROL;
                            cfg_wr_data  <= 32'd1;
                            resp_str_data <= 64'h4F4B210000000000;
                            resp_req_str <= 1'b1;
                        end else if (tok8[63:16] == 48'h5350495F5258) begin // "SPI_RX"
                            cfg_rd_valid <= 1'b1;
                            cfg_rd_addr  <= `LR_REG_SPI_RX;
                            pstate <= P_WAIT_RD0;
                        end else case (tok)
                            32'h56455200: begin  // "VER"
                                resp_str_data <= 64'h4C522076302E3121;  // "LR v0.1!"
                                resp_req_str <= 1'b1;
                            end
                            32'h48454C50: begin  // "HELP"
                                resp_req_help <= 1'b1;
                            end
                            32'h53544154: begin  // "STAT"
                                cfg_rd_valid <= 1'b1;
                                cfg_rd_addr  <= `LR_REG_STATUS;
                                pstate <= P_WAIT_RD0;
                            end
                            32'h4D4F4445: begin  // "MODE"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_MODE;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;  // "OK!"
                                resp_req_str <= 1'b1;
                            end
                            32'h53545245: begin  // "STRE"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_STREAM_EN;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h4444435F: begin  // "DDC_"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_DDC_FREQ;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h44454349: begin  // "DECI"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_DECIM;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h4646545F: begin  // "FFT_"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_FFT_CFG;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h53504543: begin  // "SPEC"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_SPEC_CFG;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h4445545F: begin  // "DET_"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_DET_CFG;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h41554449: begin  // "AUDI"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_AUDIO_CFG;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            32'h4444525F: begin  // "DDR_"
                                cfg_wr_valid <= 1'b1;
                                cfg_wr_addr  <= `LR_REG_DDR_MODE;
                                cfg_wr_data  <= arg_line;
                                resp_str_data <= 64'h4F4B210000000000;
                                resp_req_str <= 1'b1;
                            end
                            default: begin
                                invalid_count <= invalid_count + 1'b1;
                                resp_str_data <= 64'h4552522100000000;  // "ERR!"
                                resp_req_str <= 1'b1;
                            end
                        endcase
                    end
                end
                P_WAIT_RD0: begin
                    pstate <= P_WAIT_RD1;
                end
                P_WAIT_RD1: begin
                    resp_hex_data <= cfg_rd_data;
                    resp_req_hex <= 1'b1;
                    pstate <= P_IDLE;
                end
            endcase
        end
    end

endmodule
