// ============================================================================
// Lightning Receiver - Generic Asynchronous FIFO (gray-code)
// File: lr_async_fifo.v
// ----------------------------------------------------------------------------
// Parameterized async FIFO for stream CDC (AD9361 l_clk <-> fabric 225 MHz).
// Standard gray-code pointer sync; full/empty flags.
// ============================================================================
`timescale 1ns/1ps

module lr_async_fifo #(
    parameter DATA_W = 32,
    parameter DEPTH  = 1024          // power of 2
)(
    input  wire              wr_clk,
    input  wire              wr_rst_n,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] din,
    output wire              full,
    input  wire              rd_clk,
    input  wire              rd_rst_n,
    input  wire              rd_en,
    output wire [DATA_W-1:0] dout,
    output wire              empty
);

    localparam AW = $clog2(DEPTH);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [AW:0]       wr_ptr_bin, rd_ptr_bin;
    reg [AW:0]       wr_ptr_gray, rd_ptr_gray;
    (* ASYNC_REG = "TRUE" *)
    reg [AW:0]       wr_ptr_gray_r1, wr_ptr_gray_r2;
    (* ASYNC_REG = "TRUE" *)
    reg [AW:0]       rd_ptr_gray_r1, rd_ptr_gray_r2;
    reg              full_q, empty_q;
    reg [DATA_W-1:0] dout_q;

    // ---------------- write side ----------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= {(AW+1){1'b0}};
            wr_ptr_gray <= {(AW+1){1'b0}};
            full_q      <= 1'b0;
        end else begin
            if (wr_en && !full_q) begin
                wr_ptr_bin  <= wr_ptr_bin + 1'b1;
                wr_ptr_gray <= (wr_ptr_bin + 1'b1) ^ ((wr_ptr_bin + 1'b1) >> 1);
            end
            if (wr_en && !full_q)
                full_q <= (((wr_ptr_bin + 1'b1) ^ ((wr_ptr_bin + 1'b1) >> 1)) ==
                           {~rd_ptr_gray_r2[AW:AW-1], rd_ptr_gray_r2[AW-2:0]});
            else
                full_q <= (wr_ptr_gray ==
                           {~rd_ptr_gray_r2[AW:AW-1], rd_ptr_gray_r2[AW-2:0]});
        end
    end

    // Keep the RAM write port out of the asynchronously-reset process above.
    // Vivado otherwise treats the entire memory as async-reset-sensitive even
    // though the reset branch does not assign mem, which blocks BRAM inference.
    always @(posedge wr_clk) begin
        if (wr_en && !full_q)
            mem[wr_ptr_bin[AW-1:0]] <= din;
    end

    // ---------------- read side ----------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= {(AW+1){1'b0}};
            rd_ptr_gray <= {(AW+1){1'b0}};
            empty_q     <= 1'b1;
        end else begin
            if (rd_en && !empty_q) begin
                rd_ptr_bin  <= rd_ptr_bin + 1'b1;
                rd_ptr_gray <= (rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1);
            end
            if (rd_en && !empty_q)
                empty_q <= (((rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1)) ==
                            wr_ptr_gray_r2);
            else
                empty_q <= (rd_ptr_gray == wr_ptr_gray_r2);
        end
    end

    // Synchronous show-ahead read.  Keep exactly one unconditional memory
    // reference in this clocked process: Vivado's dual-clock simple-dual-port
    // BRAM inference does not accept separate conditional reads using the
    // current and next addresses.  The address mux is combinational and selects
    // the next word only for an accepted read; while empty/currently stalled it
    // continuously prefetches the current head address.  dout is irrelevant
    // whenever empty is asserted, so neither the RAM nor dout needs reset.
    wire [AW-1:0] rd_mem_addr = rd_ptr_bin[AW-1:0] +
                                {{(AW-1){1'b0}}, (rd_en && !empty_q)};
    always @(posedge rd_clk)
        dout_q <= mem[rd_mem_addr];

    // ---------------- pointer sync ----------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_r1 <= {(AW+1){1'b0}};
            wr_ptr_gray_r2 <= {(AW+1){1'b0}};
        end else begin
            wr_ptr_gray_r1 <= wr_ptr_gray;
            wr_ptr_gray_r2 <= wr_ptr_gray_r1;
        end
    end
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_r1 <= {(AW+1){1'b0}};
            rd_ptr_gray_r2 <= {(AW+1){1'b0}};
        end else begin
            rd_ptr_gray_r1 <= rd_ptr_gray;
            rd_ptr_gray_r2 <= rd_ptr_gray_r1;
        end
    end

    assign dout  = dout_q;
    assign full  = full_q;
    assign empty = empty_q;

endmodule
