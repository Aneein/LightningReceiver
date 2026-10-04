// ============================================================================
// Lightning Receiver - JTAG (BSCAN USER DR) to AXI4-Lite bridge, core logic
// File: lr_jtag_axi_core.v
// ----------------------------------------------------------------------------
// Open, documented replacement for the Xilinx JTAG-to-AXI core so a host
// program (tools/hw/lr_jtagd) can drive the FPGA through a plain FTDI MPSSE
// JTAG cable without Vivado.  Primitive-free; lr_jtag_axi_bridge.v wraps it
// with BSCANE2 (USER4) + BUFG.
//
// Every USER4 DR scan is DR_W = 72 bits, LSB first.
//   Shifted IN  (command, applied at Update-DR):
//     [1:0]   op      0 = NOP, 1 = WRITE, 2 = READ, 3 = CLEAR (overrun)
//     [3:2]   reserved (0)
//     [35:4]  addr
//     [67:36] wdata
//     [71:68] tag     echoed back with the result
//   Shifted OUT (status, loaded at Capture-DR):
//     [0]     valid   a command was issued and has completed
//     [1]     busy    the last command is still in flight
//     [2]     overrun a command arrived while busy and was DROPPED.  Sticky:
//                     while set, EVERY further WRITE/READ is dropped too,
//                     until a CLEAR command (or Test-Logic-Reset).  So the
//                     commands accepted in a batch are always a prefix and
//                     the first scan whose capture shows overrun identifies
//                     the first dropped command exactly.
//     [4:3]   resp    AXI BRESP/RRESP of the completed command
//     [36:5]  rdata
//     [40:37] tag     of the completed command
//     [43:41] 0
//     [47:44] VERSION
//     [71:48] MAGIC   24'h4C524A ("LRJ") - lets the host detect the bridge
//
// Pipelining: the scan that carries command k+1 returns the result of
// command k.  Host leaves a few Run-Test/Idle clocks between scans; if the
// AXI access is not finished yet the host sees busy (and overrun if it sent a
// new command) and retries.
//
// Clock crossing: toggle handshake.  The command fields are held stable in
// the TCK domain while busy; the result fields are held stable in the AXI
// domain until the next command.  Only the toggles are synchronised.
// ============================================================================
`timescale 1ns/1ps

module lr_jtag_axi_core #(
    parameter [3:0]  VERSION = 4'd1,
    parameter [23:0] MAGIC   = 24'h4C524A
)(
    // ---- TAP side (from BSCANE2) ----
    input  wire        tck,
    input  wire        tdi,
    output wire        tdo,
    input  wire        sel,
    input  wire        capture,
    input  wire        shift,
    input  wire        update,
    input  wire        tlr,          // Test-Logic-Reset
    // ---- AXI4-Lite master (fabric clock) ----
    input  wire        M_AXI_aclk,
    input  wire        M_AXI_aresetn,
    output reg  [31:0] M_AXI_awaddr,
    output wire [2:0]  M_AXI_awprot,
    output reg         M_AXI_awvalid,
    input  wire        M_AXI_awready,
    output reg  [31:0] M_AXI_wdata,
    output wire [3:0]  M_AXI_wstrb,
    output reg         M_AXI_wvalid,
    input  wire        M_AXI_wready,
    input  wire [1:0]  M_AXI_bresp,
    input  wire        M_AXI_bvalid,
    output wire        M_AXI_bready,
    output reg  [31:0] M_AXI_araddr,
    output wire [2:0]  M_AXI_arprot,
    output reg         M_AXI_arvalid,
    input  wire        M_AXI_arready,
    input  wire [31:0] M_AXI_rdata,
    input  wire [1:0]  M_AXI_rresp,
    input  wire        M_AXI_rvalid,
    output wire        M_AXI_rready
);

    localparam integer DR_W = 72;
    localparam [1:0] OP_NOP = 2'd0, OP_WRITE = 2'd1, OP_READ = 2'd2, OP_CLEAR = 2'd3;

    // ======================= TCK domain =======================
    reg [DR_W-1:0] sr = {DR_W{1'b0}};
    reg        cmd_tgl = 1'b0;
    reg [1:0]  cmd_op = 2'd0;
    reg [31:0] cmd_addr = 32'd0;
    reg [31:0] cmd_wdata = 32'd0;
    reg [3:0]  cmd_tag = 4'd0;
    reg        issued = 1'b0;
    reg        overrun = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg res_s1 = 1'b0, res_s2 = 1'b0;

    // results, written in the AXI domain, stable while not busy
    reg        res_tgl = 1'b0;
    reg [1:0]  res_resp = 2'd0;
    reg [31:0] res_rdata = 32'd0;
    reg [3:0]  res_tag = 4'd0;

    wire busy_tck = (cmd_tgl != res_s2);
    wire [DR_W-1:0] status = {MAGIC, VERSION, 3'd0, res_tag, res_rdata, res_resp,
                              overrun, busy_tck, issued & ~busy_tck};

    assign tdo = sr[0];

    always @(posedge tck) begin
        res_s1 <= res_tgl;
        res_s2 <= res_s1;
        if (tlr) begin
            overrun <= 1'b0;
        end else if (sel && capture) begin
            sr <= status;
        end else if (sel && shift) begin
            sr <= {tdi, sr[DR_W-1:1]};
        end else if (sel && update) begin
            if (sr[1:0] == OP_CLEAR) begin
                overrun <= 1'b0;
            end else if (sr[1:0] == OP_WRITE || sr[1:0] == OP_READ) begin
                if (busy_tck || overrun) begin
                    overrun <= 1'b1;          // dropped (sticky); host resends
                end else begin
                    cmd_op    <= sr[1:0];
                    cmd_addr  <= sr[35:4];
                    cmd_wdata <= sr[67:36];
                    cmd_tag   <= sr[71:68];
                    cmd_tgl   <= ~cmd_tgl;
                    issued    <= 1'b1;
                end
            end
        end
    end

    // ======================= AXI domain =======================
    (* ASYNC_REG = "TRUE" *) reg cmd_s1 = 1'b0, cmd_s2 = 1'b0;
    reg cmd_s3 = 1'b0;
    localparam [1:0] A_IDLE = 2'd0, A_WRITE = 2'd1, A_READ = 2'd2;
    reg [1:0] astate = A_IDLE;
    reg aw_done, w_done;

    assign M_AXI_awprot = 3'b000;
    assign M_AXI_arprot = 3'b000;
    assign M_AXI_wstrb  = 4'hF;
    assign M_AXI_bready = (astate == A_WRITE) && aw_done && w_done;
    assign M_AXI_rready = (astate == A_READ) && !M_AXI_arvalid;

    always @(posedge M_AXI_aclk or negedge M_AXI_aresetn) begin
        if (!M_AXI_aresetn) begin
            cmd_s1 <= 1'b0; cmd_s2 <= 1'b0; cmd_s3 <= 1'b0;
            astate <= A_IDLE;
            M_AXI_awaddr <= 32'd0; M_AXI_awvalid <= 1'b0;
            M_AXI_wdata <= 32'd0;  M_AXI_wvalid <= 1'b0;
            M_AXI_araddr <= 32'd0; M_AXI_arvalid <= 1'b0;
            aw_done <= 1'b0; w_done <= 1'b0;
        end else begin
            cmd_s1 <= cmd_tgl;
            cmd_s2 <= cmd_s1;
            case (astate)
                A_IDLE: begin
                    if (cmd_s2 != cmd_s3) begin       // new command
                        cmd_s3 <= cmd_s2;
                        if (cmd_op == OP_WRITE) begin
                            M_AXI_awaddr  <= cmd_addr;
                            M_AXI_wdata   <= cmd_wdata;
                            M_AXI_awvalid <= 1'b1;
                            M_AXI_wvalid  <= 1'b1;
                            aw_done <= 1'b0;
                            w_done  <= 1'b0;
                            astate <= A_WRITE;
                        end else begin
                            M_AXI_araddr  <= cmd_addr;
                            M_AXI_arvalid <= 1'b1;
                            astate <= A_READ;
                        end
                    end
                end
                A_WRITE: begin
                    if (M_AXI_awvalid && M_AXI_awready) begin
                        M_AXI_awvalid <= 1'b0;
                        aw_done <= 1'b1;
                    end
                    if (M_AXI_wvalid && M_AXI_wready) begin
                        M_AXI_wvalid <= 1'b0;
                        w_done <= 1'b1;
                    end
                    if (M_AXI_bready && M_AXI_bvalid) begin
                        res_resp  <= M_AXI_bresp;
                        res_rdata <= 32'd0;
                        res_tag   <= cmd_tag;
                        res_tgl   <= ~res_tgl;
                        astate    <= A_IDLE;
                    end
                end
                A_READ: begin
                    if (M_AXI_arvalid && M_AXI_arready)
                        M_AXI_arvalid <= 1'b0;
                    if (M_AXI_rready && M_AXI_rvalid) begin
                        res_resp  <= M_AXI_rresp;
                        res_rdata <= M_AXI_rdata;
                        res_tag   <= cmd_tag;
                        res_tgl   <= ~res_tgl;
                        astate    <= A_IDLE;
                    end
                end
                default: astate <= A_IDLE;
            endcase
        end
    end

endmodule
