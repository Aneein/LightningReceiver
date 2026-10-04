// ============================================================================
// Lightning Receiver - JTAG-to-AXI bridge on BSCANE2 USER4
// File: lr_jtag_axi_bridge.v
// ----------------------------------------------------------------------------
// Instantiates the UltraScale+ BSCANE2 primitive on JTAG_CHAIN 4 (USER4,
// IR = 6'h23 on single-die UltraScale+) and the protocol core
// lr_jtag_axi_core.  The Xilinx debug hub (jtag_axi / MIG debug) stays on
// USER1, so Vivado Hardware Manager keeps working alongside this bridge
// (but only one program can own the FTDI cable at a time).
//
// Timing: TCK (<= 30 MHz from the FT2232H) is constrained as its own clock
// (lr_timing_convergence.xdc) and is asynchronous to the AXI clock; only the
// toggle synchronisers in the core cross between them.
// ============================================================================
`timescale 1ns/1ps

module lr_jtag_axi_bridge (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 M_AXI_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_aclk, ASSOCIATED_BUSIF M_AXI, ASSOCIATED_RESET M_AXI_aresetn, FREQ_HZ 225014957, PHASE 0.0" *)
    input  wire        M_AXI_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 M_AXI_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire        M_AXI_aresetn,
    output wire [31:0] M_AXI_awaddr,
    output wire [2:0]  M_AXI_awprot,
    output wire        M_AXI_awvalid,
    input  wire        M_AXI_awready,
    output wire [31:0] M_AXI_wdata,
    output wire [3:0]  M_AXI_wstrb,
    output wire        M_AXI_wvalid,
    input  wire        M_AXI_wready,
    input  wire [1:0]  M_AXI_bresp,
    input  wire        M_AXI_bvalid,
    output wire        M_AXI_bready,
    output wire [31:0] M_AXI_araddr,
    output wire [2:0]  M_AXI_arprot,
    output wire        M_AXI_arvalid,
    input  wire        M_AXI_arready,
    input  wire [31:0] M_AXI_rdata,
    input  wire [1:0]  M_AXI_rresp,
    input  wire        M_AXI_rvalid,
    output wire        M_AXI_rready
);

    wire tck_raw, tck, tdi, tdo, sel, capture, shift, update, tlr;

    BSCANE2 #(
        .JTAG_CHAIN(4)
    ) u_bscan (
        .CAPTURE (capture),
        .DRCK    (),
        .RESET   (tlr),
        .RUNTEST (),
        .SEL     (sel),
        .SHIFT   (shift),
        .TCK     (tck_raw),
        .TDI     (tdi),
        .TMS     (),
        .UPDATE  (update),
        .TDO     (tdo)
    );

    BUFG u_tck_bufg (.I(tck_raw), .O(tck));

    lr_jtag_axi_core u_core (
        .tck(tck), .tdi(tdi), .tdo(tdo), .sel(sel), .capture(capture),
        .shift(shift), .update(update), .tlr(tlr),
        .M_AXI_aclk(M_AXI_aclk), .M_AXI_aresetn(M_AXI_aresetn),
        .M_AXI_awaddr(M_AXI_awaddr), .M_AXI_awprot(M_AXI_awprot),
        .M_AXI_awvalid(M_AXI_awvalid), .M_AXI_awready(M_AXI_awready),
        .M_AXI_wdata(M_AXI_wdata), .M_AXI_wstrb(M_AXI_wstrb),
        .M_AXI_wvalid(M_AXI_wvalid), .M_AXI_wready(M_AXI_wready),
        .M_AXI_bresp(M_AXI_bresp), .M_AXI_bvalid(M_AXI_bvalid),
        .M_AXI_bready(M_AXI_bready),
        .M_AXI_araddr(M_AXI_araddr), .M_AXI_arprot(M_AXI_arprot),
        .M_AXI_arvalid(M_AXI_arvalid), .M_AXI_arready(M_AXI_arready),
        .M_AXI_rdata(M_AXI_rdata), .M_AXI_rresp(M_AXI_rresp),
        .M_AXI_rvalid(M_AXI_rvalid), .M_AXI_rready(M_AXI_rready));

endmodule
