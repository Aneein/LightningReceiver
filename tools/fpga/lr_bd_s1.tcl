# ============================================================================
# Lightning Receiver - S1 Block Design extension (AD9361 RX + stream fabric)
# File: lr_bd_s1.tcl
# ----------------------------------------------------------------------------
# Extends the S0 "system" BD with:
#   - axi_ad9361 (ADI hdl, LVDS 6-bit, RX-only; TX paths left unconnected)
#   - jtag_axi + axi_interconnect (control plane: uartlite + axi_ad9361 + reg)
#   - raw_iq_router (custom RTL as BD module) - ADC channels -> LR stream 0
#   - timestamp_counter (custom RTL as BD module) for stream side channel
# New top ports: rx_clk_in_p/n, rx_frame_in_p/n, rx_data_in_p/n[5:0],
#                enable, txnrx
# Prerequisite: lr_sources.tcl (ADI repo + custom RTL) then lr_setup.tcl (S0).
# Usage:  source <path>/lr_bd_s1.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}
if {[llength [get_bd_designs -quiet system]] == 0} {
    error "S0 BD 'system' not found - source lr_setup.tcl first."
}
if {[llength [get_bd_cells -quiet raw_iq_router]] == 0} {
    error "Custom RTL modules not in BD catalog - source lr_sources.tcl first."
}

# ---------------------------------------------------------------------------
# 1. AD9361 device IP (RX-only)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv analog.com:user:axi_ad9361:1.0 axi_ad9361_0
set_property -dict [list \
    CONFIG.ID {0} \
    CONFIG.ADC_INIT_DELAY {20} \
    CONFIG.DAC_DDS_TYPE {1} \
] [get_bd_cells axi_ad9361_0]

# ---------------------------------------------------------------------------
# 2. Control plane: JTAG AXI master + interconnect
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_0
set_property -dict [list \
    CONFIG.NUM_MI {3} \
    CONFIG.NUM_SI {1} \
] [get_bd_cells axi_ic_0]

# ---------------------------------------------------------------------------
# 3. Stream fabric custom modules
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference raw_iq_router u_raw_iq
create_bd_cell -type module -reference timestamp_counter u_ts

# ---------------------------------------------------------------------------
# 4. Ports (AD9361 LVDS + control)
# ---------------------------------------------------------------------------
create_bd_port -dir I rx_clk_in_p
create_bd_port -dir I rx_clk_in_n
create_bd_port -dir I rx_frame_in_p
create_bd_port -dir I rx_frame_in_n
create_bd_port -dir I -from 5 -to 0 rx_data_in_p
create_bd_port -dir I -from 5 -to 0 rx_data_in_n
create_bd_port -dir O enable
create_bd_port -dir O txnrx

# ---------------------------------------------------------------------------
# 5. IODELAY reference clock: 200 MHz from clk_wiz_225 (no-buffer chain)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_iodelay
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {225.000} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_iodelay]
connect_bd_net [get_bd_pins clk_wiz_225/clk_out1] [get_bd_pins clk_wiz_iodelay/clk_in1]

# ---------------------------------------------------------------------------
# 6. LVDS / device connections
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_ports rx_clk_in_p]   [get_bd_pins axi_ad9361_0/rx_clk_in_p]
connect_bd_net [get_bd_ports rx_clk_in_n]   [get_bd_pins axi_ad9361_0/rx_clk_in_n]
connect_bd_net [get_bd_ports rx_frame_in_p] [get_bd_pins axi_ad9361_0/rx_frame_in_p]
connect_bd_net [get_bd_ports rx_frame_in_n] [get_bd_pins axi_ad9361_0/rx_frame_in_n]
connect_bd_net [get_bd_ports rx_data_in_p]  [get_bd_pins axi_ad9361_0/rx_data_in_p]
connect_bd_net [get_bd_ports rx_data_in_n]  [get_bd_pins axi_ad9361_0/rx_data_in_n]

connect_bd_net [get_bd_pins axi_ad9361_0/l_clk] [get_bd_pins axi_ad9361_0/clk]
connect_bd_net [get_bd_pins clk_wiz_iodelay/clk_out1] [get_bd_pins axi_ad9361_0/delay_clk]

# RX-only control: enable=1, txnrx=0 (RX); up_enable=1, up_txnrx=0
connect_bd_net [get_bd_ports enable] [get_bd_pins axi_ad9361_0/enable]
connect_bd_net [get_bd_ports txnrx]  [get_bd_pins axi_ad9361_0/txnrx]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn] [get_bd_pins axi_ad9361_0/up_enable]

# ---------------------------------------------------------------------------
# 7. Stream fabric wiring
# ---------------------------------------------------------------------------
# clocks / reset
connect_bd_net [get_bd_pins clk_wiz_225/clk_out1]        [get_bd_pins u_raw_iq/clk]
connect_bd_net [get_bd_pins rst_225/peripheral_aresetn]  [get_bd_pins u_raw_iq/rst_n]
connect_bd_net [get_bd_pins axi_ad9361_0/l_clk]          [get_bd_pins u_raw_iq/l_clk]
connect_bd_net [get_bd_pins rst_225/peripheral_aresetn]  [get_bd_pins u_raw_iq/l_rst_n]
connect_bd_net [get_bd_pins clk_wiz_225/clk_out1]        [get_bd_pins u_ts/clk]
connect_bd_net [get_bd_pins rst_225/peripheral_aresetn]  [get_bd_pins u_ts/rst_n]

# ADC channels -> raw_iq_router
connect_bd_net [get_bd_pins axi_ad9361_0/adc_enable_i0] [get_bd_pins u_raw_iq/adc_enable_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_valid_i0]  [get_bd_pins u_raw_iq/adc_valid_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_data_i0]   [get_bd_pins u_raw_iq/adc_data_i0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_enable_q0] [get_bd_pins u_raw_iq/adc_enable_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_valid_q0]  [get_bd_pins u_raw_iq/adc_valid_q0]
connect_bd_net [get_bd_pins axi_ad9361_0/adc_data_q0]   [get_bd_pins u_raw_iq/adc_data_q0]

# timestamp side channel
connect_bd_net [get_bd_pins u_ts/timestamp]     [get_bd_pins u_raw_iq/timestamp]
connect_bd_net [get_bd_pins u_ts/timestamp]     [get_bd_pins u_raw_iq/sample_count]

# ---------------------------------------------------------------------------
# 8. AXI control plane
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1]        [get_bd_pins jtag_axi_0/aclk]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn]  [get_bd_pins jtag_axi_0/aresetn]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1]        [get_bd_pins axi_ic_0/ACLK]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn]  [get_bd_pins axi_ic_0/ARESETN]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1]        [get_bd_pins axi_ic_0/S00_ACLK]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn]  [get_bd_pins axi_ic_0/S00_ARESETN]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1]        [get_bd_pins axi_ic_0/M00_ACLK]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn]  [get_bd_pins axi_ic_0/M00_ARESETN]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1]        [get_bd_pins axi_ic_0/M01_ACLK]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn]  [get_bd_pins axi_ic_0/M01_ARESETN]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1]        [get_bd_pins axi_ic_0/M02_ACLK]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn]  [get_bd_pins axi_ic_0/M02_ARESETN]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins uartlite_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M01_AXI] [get_bd_intf_pins axi_ad9361_0/up_axi]

# ---------------------------------------------------------------------------
# 9. Address map + validate
# ---------------------------------------------------------------------------
assign_bd_address
validate_bd_design
puts "=== LR S1 BD extension complete (axi_ad9361 + stream fabric) ==="
puts "    Address map:"
report_address_book
