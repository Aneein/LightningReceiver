# ============================================================================
# Lightning Receiver - S2 Block Design (full assembly: MIG + CMAC + clocks)
# File: lr_bd_s2.tcl
# ----------------------------------------------------------------------------
# REGENERATES the whole "system" BD with the proven F_SMART KU5P clocking:
#   c0_sys_clk (200M diff, T24) -> ddr4_0 (MIG, DDR4-2666, 32-bit, 2GB)
#   ddr4_0/c0_ddr4_ui_clk (333.25M) -> clk_fabric (225M + 100M dual output)
#   cmac_0 (cmac_usplus 3.1, CAUI4, refclk 156.25M via QSFP28)
#   axi_ad9361_0 (RX-only) + u_raw_iq (stream 0) + u_ts
#   UART text commands + jtag_axi_0 + axi_ic_0 (control plane)
# Supersedes lr_bd_s0.tcl / lr_bd_s1.tcl for the full build.
# Prerequisite: lr_sources.tcl (ADI repo + custom RTL).
# Usage:  source <path>/lr_bd_s2.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}
# make custom RTL resolvable as BD modules
update_compile_order -fileset sources_1

# --- helper: connect two pins/ports by name, warn and continue if missing ---
# Accepts BD pins (cell/pin) and top-level BD ports (name). For vector pins
# use whole-bus names only - bit-select [N] is NOT resolvable via get_bd_pins.
proc lr_connect {src dst} {
    set s [get_bd_pins -quiet $src]
    if {$s eq ""} { set s [get_bd_ports -quiet $src] }
    set d [get_bd_pins -quiet $dst]
    if {$d eq ""} { set d [get_bd_ports -quiet $dst] }
    if {$s ne "" && $d ne ""} {
        connect_bd_net $s $d
    } else {
        puts "WARNING: skip connect $src -> $dst (pin/port missing)"
    }
}

# --- remove existing BD (regenerate; robust when BD not open, e.g. batch) ---
if {[llength [get_bd_designs -quiet system]] > 0} {
    puts "INFO: closing BD 'system' for full regeneration"
    catch { close_bd_design [get_bd_designs system] }
}
set bd_files [get_files -quiet system.bd]
if {[llength $bd_files] > 0} {
    puts "INFO: removing BD file from sources"
    remove_files -fileset sources_1 $bd_files
}
# belt-and-braces: delete the .bd file from disk if still present
set bd_disk [file join [get_property DIRECTORY [current_project]] \
    [get_property NAME [current_project]].srcs sources_1 bd system system.bd]
if {[file exists $bd_disk]} {
    puts "INFO: deleting BD file on disk: $bd_disk"
    file delete -force $bd_disk
}
create_bd_design "system"

# ===========================================================================
# 1. Ports
# ===========================================================================
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 c0_sys_clk
set_property -dict [list CONFIG.FREQ_HZ {200000000}] [get_bd_intf_ports c0_sys_clk]

create_bd_port -dir I uart_rx
create_bd_port -dir O uart_tx

create_bd_port -dir I qsfp_refclk_p
create_bd_port -dir I qsfp_refclk_n
create_bd_port -dir O qsfp_resetl
create_bd_port -dir O qsfp_lpmode
create_bd_port -dir O qsfp_modsell

# AD9361 RX LVDS (S1)
create_bd_port -dir I rx_clk_in_p
create_bd_port -dir I rx_clk_in_n
create_bd_port -dir I rx_frame_in_p
create_bd_port -dir I rx_frame_in_n
create_bd_port -dir I -from 5 -to 0 rx_data_in_p
create_bd_port -dir I -from 5 -to 0 rx_data_in_n
create_bd_port -dir O enable
create_bd_port -dir O txnrx
create_bd_port -dir O spi_csn
create_bd_port -dir O spi_sclk
create_bd_port -dir O spi_mosi
create_bd_port -dir I spi_miso

# All four board keys remain available to the control plane.  Fabric resets are
# derived from the proven MIG UI reset sequence, as in the working F_SMART
# baseline, so an external key cannot accidentally hold the whole design down.
create_bd_port -dir I -from 3 -to 0 key_in
create_bd_port -dir O -from 3 -to 0 led

# DDR4 physical interface (wrapper pins: c0_ddr4_*)
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddr4_rtl:1.0 c0_ddr4

# ===========================================================================
# 2. Memory: ddr4 MIG (proven F_SMART config)
# ===========================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_0
set_property -dict [list \
    CONFIG.C0.DDR4_MemoryPart {MT40A512M16HA-075E} \
    CONFIG.C0.DDR4_DataWidth {32} \
    CONFIG.C0.DDR4_TimePeriod {750} \
    CONFIG.C0.DDR4_CasLatency {19} \
    CONFIG.C0.DDR4_CasWriteLatency {14} \
    CONFIG.C0.DDR4_BurstLength {8} \
    CONFIG.C0.DDR4_MemoryType {Components} \
    CONFIG.C0.DDR4_InputClockPeriod {5000} \
] [get_bd_cells ddr4_0]

# ===========================================================================
# 3. Clocks (single MMCM, dual output - F_SMART proven config:
#    333.25M -> 225M (fabric) + 100M (control); no MMCM cascade)
# ===========================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_fabric
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {333.250} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {225.000} \
    CONFIG.CLKOUT2_USED {1} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_RESET {false} \
] [get_bd_cells clk_fabric]

# IODELAY reference for axi_ad9361: UltraScale IDELAYCTRL requires a reference
# period no greater than 3.333 ns.  The former 200 MHz setting produced the
# exact WPWS=-1.666 ns failure; use 300 MHz from the 225 MHz fabric clock.
# CLOCK_DEDICATED_ROUTE BACKBONE override is added in constraints.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_iodelay
# clk_fabric realizes 225 MHz as 225.014957 MHz from the MIG UI clock.
# Match that propagated value exactly so BD clock metadata remains coherent.
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {225.014957} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {300.000} \
    CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_iodelay]

# ===========================================================================
# 4. Resets
# ===========================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_mig_ui
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_fabric
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_cmac_100
# Reset polarity is propagated by IPI from the connected active-low sources;
# C_EXT_RESET_HIGH is read-only in proc_sys_reset 5.0 and must not be forced.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 util_inv_mig_rst
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells util_inv_mig_rst]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 util_inv_ad9361_rst
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells util_inv_ad9361_rst]

# ===========================================================================
# 5. CMAC 100G (CAUI4)
# ===========================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:cmac_usplus:3.1 cmac_0
set_property -dict [list \
    CONFIG.CMAC_CAUI4_MODE {1} \
    CONFIG.GT_GROUP_SELECT {X0Y4~X0Y7} \
    CONFIG.NUM_LANES {4x25} \
    CONFIG.OPERATING_MODE {Duplex} \
    CONFIG.GT_REF_CLK_FREQ {156.25} \
    CONFIG.USER_INTERFACE {AXIS} \
    CONFIG.ENABLE_AXI_INTERFACE {1} \
    CONFIG.ENABLE_PIPELINE_REG {1} \
    CONFIG.INCLUDE_RS_FEC {1} \
    CONFIG.INCLUDE_SHARED_LOGIC {2} \
    CONFIG.INCLUDE_STATISTICS_COUNTERS {1} \
    CONFIG.RX_FLOW_CONTROL {0} \
    CONFIG.TX_FLOW_CONTROL {0} \
] [get_bd_cells cmac_0]

set gtp_vlnv [get_property VLNV [get_bd_intf_pins cmac_0/gt_serial_port]]
create_bd_intf_port -mode Master -vlnv $gtp_vlnv gt_serial_port

create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 fifo_cmac_rx_cdc
set_property -dict [list \
    CONFIG.FIFO_DEPTH {4096} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.HAS_TKEEP {true} \
    CONFIG.HAS_TLAST {true} \
    CONFIG.TDATA_NUM_BYTES {64} \
] [get_bd_cells fifo_cmac_rx_cdc]

# ===========================================================================
# 6. RF: AD9361 + stream fabric
# ===========================================================================
create_bd_cell -type ip -vlnv analog.com:user:axi_ad9361:1.0 axi_ad9361_0
set_property -dict [list \
    CONFIG.ID {0} \
    CONFIG.ADC_INIT_DELAY {20} \
    CONFIG.DAC_DDS_TYPE {1} \
] [get_bd_cells axi_ad9361_0]

create_bd_cell -type module -reference raw_iq_router u_raw_iq
create_bd_cell -type module -reference timestamp_counter u_ts
create_bd_cell -type module -reference sample_counter u_sc

# ===========================================================================
# 7. Control plane
# ===========================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_0
create_bd_cell -type module -reference cmac_axil_init u_cmac_init
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_0
# S00 jtag_axi, S01 raw-IQ ring, S02 CMAC init, S03 audio ring,
# S04 lr_jtag_axi_bridge (open BSCAN USER4 bridge for tools/hw/lr_jtagd)
set_property -dict [list CONFIG.NUM_MI {4} CONFIG.NUM_SI {5}] [get_bd_cells axi_ic_0]

# ===========================================================================
# 8. Clock / reset connections
# ===========================================================================
connect_bd_intf_net [get_bd_intf_ports c0_sys_clk] [get_bd_intf_pins ddr4_0/C0_SYS_CLK]
connect_bd_intf_net [get_bd_intf_ports c0_ddr4] [get_bd_intf_pins ddr4_0/C0_DDR4]
lr_connect ddr4_0/c0_ddr4_ui_clk clk_fabric/clk_in1
lr_connect clk_fabric/clk_out1 clk_wiz_iodelay/clk_in1

lr_connect ddr4_0/c0_ddr4_ui_clk_sync_rst util_inv_mig_rst/Op1
lr_connect util_inv_mig_rst/Res rst_mig_ui/ext_reset_in
lr_connect ddr4_0/c0_ddr4_ui_clk rst_mig_ui/slowest_sync_clk

lr_connect clk_fabric/clk_out1 rst_fabric/slowest_sync_clk
lr_connect clk_fabric/locked rst_fabric/dcm_locked
# ext_reset_in is active-LOW (C_EXT_RESET_HIGH=0); MIG ui_clk_sync_rst is
# active-HIGH, so feed the inverted signal (same pattern as rst_mig_ui).
lr_connect util_inv_mig_rst/Res rst_fabric/ext_reset_in

lr_connect clk_fabric/clk_out2 rst_cmac_100/slowest_sync_clk
lr_connect clk_fabric/locked rst_cmac_100/dcm_locked
lr_connect util_inv_mig_rst/Res rst_cmac_100/ext_reset_in

# ===========================================================================
# 9. CMAC connections (robust: warn + continue on missing pins)
# ===========================================================================
lr_connect qsfp_refclk_p cmac_0/gt_ref_clk_p
lr_connect qsfp_refclk_n cmac_0/gt_ref_clk_n
connect_bd_intf_net [get_bd_intf_pins cmac_0/gt_serial_port] [get_bd_intf_ports gt_serial_port]

lr_connect clk_fabric/clk_out2 cmac_0/init_clk
lr_connect clk_fabric/clk_out2 cmac_0/drp_clk
# s_axi: connect if present; else print the actual CMAC interface list
set cmac_saxi [get_bd_intf_pins -quiet cmac_0/s_axi]
if {$cmac_saxi ne ""} {
    lr_connect clk_fabric/clk_out1 cmac_0/s_axi_aclk
    connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M01_AXI] $cmac_saxi
} else {
    puts "WARNING: cmac_0/s_axi interface NOT FOUND - CMAC control not wired"
    puts "  available cmac interfaces: [get_bd_intf_pins -of_objects [get_bd_cells cmac_0]]"
}
# CMAC sys_reset (input, active high) <- fabric reset
# NOTE: usr_rx_reset / usr_tx_reset are CMAC OUTPUTS (reset status) - they are
#       used in the RX path below to reset the CDC fifo (inverted).
lr_connect rst_cmac_100/peripheral_reset cmac_0/sys_reset

# tie core resets / misc to GND (sinks are all inputs; repeated source
# connects are legal in IPI - pattern proven by ADI hdl scripts)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_gnd
set_property -dict [list CONFIG.CONST_VAL {0}] [get_bd_cells const_gnd]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one
set_property -dict [list CONFIG.CONST_VAL {1}] [get_bd_cells const_one]
# Width-matched constants avoid leaving the upper bits of vector inputs
# electrically unconnected in IPI.
foreach {name width value} {
    const_gnd12 12 0
    const_gnd10 10 0
    const_gnd9 9 0
    const_gnd5 5 0
    const_gnd16 16 0
    const_gnd32 32 0
    const_gnd24 24 0
    const_gnd7 7 0
    const_gnd56 56 0
    const_ring_base 32 0x80000000
    const_raw_ring_words26 26 0x3F80000
    const_audio_base 32 0xFF000000
    const_audio_words26 26 0x80000
    const_audio_words32 32 0x80000
    const_one16 16 1
} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 $name
    set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL $value] \
        [get_bd_cells $name]
}
foreach p {core_rx_reset core_tx_reset core_drp_reset gtwiz_reset_tx_datapath \
           gtwiz_reset_rx_datapath} {
    lr_connect const_gnd/dout cmac_0/$p
}
# Explicitly park optional CMAC controls that the LR datapath does not use.
foreach p {ctl_tx_resend_pause ctl_tx_send_idle ctl_tx_send_lfi ctl_tx_send_rfi \
           drp_en drp_we pm_tick} {
    lr_connect const_gnd/dout cmac_0/$p
}
lr_connect const_gnd9/dout  cmac_0/ctl_tx_pause_req
lr_connect const_gnd10/dout cmac_0/drp_addr
lr_connect const_gnd16/dout cmac_0/drp_di
lr_connect const_gnd12/dout cmac_0/gt_loopback_in
lr_connect const_gnd56/dout cmac_0/tx_preamblein
lr_connect rst_fabric/peripheral_reset cmac_0/s_axi_sreset
lr_connect const_one/dout qsfp_resetl
lr_connect const_gnd/dout qsfp_lpmode
lr_connect const_one/dout qsfp_modsell

# RX data path: axis_rx -> CDC fifo (fabric 225) -> packetizer hookup in S3
lr_connect cmac_0/gt_rxusrclk2 fifo_cmac_rx_cdc/s_axis_aclk
lr_connect cmac_0/gt_rxusrclk2 cmac_0/rx_clk
set cmac_axis_rx [get_bd_intf_pins -quiet cmac_0/axis_rx]
set fifo_s_axis  [get_bd_intf_pins -quiet fifo_cmac_rx_cdc/S_AXIS]
if {$cmac_axis_rx ne "" && $fifo_s_axis ne ""} {
    connect_bd_intf_net $cmac_axis_rx $fifo_s_axis
} else {
    puts "WARNING: cmac axis_rx / fifo S_AXIS interface mismatch"
}
lr_connect clk_fabric/clk_out1 fifo_cmac_rx_cdc/m_axis_aclk
# The present receive side is a monitored sink (host commands use JTAG/UART
# control).  Drain accepted CMAC frames so the CDC FIFO cannot fill and
# backpressure the MAC indefinitely.
lr_connect const_one/dout fifo_cmac_rx_cdc/m_axis_tready
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 util_inv_rx_rst
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells util_inv_rx_rst]
lr_connect cmac_0/usr_rx_reset util_inv_rx_rst/Op1
lr_connect util_inv_rx_rst/Res fifo_cmac_rx_cdc/s_axis_aresetn

# ===========================================================================
# 10. AD9361 + stream fabric
# ===========================================================================
lr_connect rx_clk_in_p   axi_ad9361_0/rx_clk_in_p
lr_connect rx_clk_in_n   axi_ad9361_0/rx_clk_in_n
lr_connect rx_frame_in_p axi_ad9361_0/rx_frame_in_p
lr_connect rx_frame_in_n axi_ad9361_0/rx_frame_in_n
lr_connect rx_data_in_p  axi_ad9361_0/rx_data_in_p
lr_connect rx_data_in_n  axi_ad9361_0/rx_data_in_n
lr_connect axi_ad9361_0/l_clk axi_ad9361_0/clk
lr_connect clk_wiz_iodelay/clk_out1 axi_ad9361_0/delay_clk
lr_connect enable axi_ad9361_0/enable
lr_connect txnrx  axi_ad9361_0/txnrx
# up_enable is sampled in the 100 MHz AXI/up clock domain.  Driving it from
# the 225 MHz fabric reset created a real cross-clock timing path in the old
# report.  The core has its own synchronous AXI reset, so keep this RX-only
# design enabled with a static value instead.
lr_connect const_one/dout axi_ad9361_0/up_enable
lr_connect clk_fabric/clk_out1 axi_ad9361_0/s_axi_aclk
lr_connect rst_fabric/peripheral_aresetn axi_ad9361_0/s_axi_aresetn
lr_connect const_gnd/dout axi_ad9361_0/up_txnrx
# RX-only: tie all unused scalar inputs to GND and vector inputs to
# width-matched zero constants.
foreach p {dac_sync_in tdd_sync gps_pps adc_dovf dac_dunf} {
    lr_connect const_gnd/dout axi_ad9361_0/$p
}
foreach p {dac_data_i0 dac_data_q0 dac_data_i1 dac_data_q1} {
    lr_connect const_gnd16/dout axi_ad9361_0/$p
}
foreach p {up_dac_gpio_in up_adc_gpio_in} {
    lr_connect const_gnd32/dout axi_ad9361_0/$p
}

lr_connect clk_fabric/clk_out1 u_raw_iq/clk
lr_connect rst_fabric/peripheral_aresetn u_raw_iq/rst_n
lr_connect axi_ad9361_0/l_clk u_raw_iq/l_clk
# ADI's active-high reset is generated in l_clk; invert it for the router's
# active-low FIFO write-side reset instead of creating a second reset domain.
lr_connect axi_ad9361_0/rst util_inv_ad9361_rst/Op1
lr_connect util_inv_ad9361_rst/Res u_raw_iq/l_rst_n
lr_connect clk_fabric/clk_out1 u_ts/clk
lr_connect rst_fabric/peripheral_aresetn u_ts/rst_n
lr_connect clk_fabric/clk_out1 u_sc/clk
lr_connect rst_fabric/peripheral_aresetn u_sc/rst_n
# timestamp counter must run: enable=1, clear=0
lr_connect const_one/dout rst_mig_ui/dcm_locked
foreach r {rst_mig_ui rst_fabric rst_cmac_100} {
    # aux_reset_in is ACTIVE-LOW here (C_AUX_RESET_HIGH = 0, propagated):
    # it must be parked HIGH.  Tying it to GND held every peripheral reset
    # asserted forever (dead fabric domain, JTAG-AXI timeouts, LEDs off).
    lr_connect const_one/dout ${r}/aux_reset_in
    # mb_debug_sys_rst is active-high: GND = inactive.
    lr_connect const_gnd/dout ${r}/mb_debug_sys_rst
}
# Without this connection the MIG AXI slave's default is active reset (0).
lr_connect rst_mig_ui/peripheral_aresetn ddr4_0/c0_ddr4_aresetn
lr_connect const_one/dout u_ts/enable
lr_connect const_gnd/dout u_ts/clear
lr_connect const_one/dout u_sc/enable
lr_connect const_gnd/dout u_sc/clear

lr_connect axi_ad9361_0/adc_enable_i0 u_raw_iq/adc_enable_i0
lr_connect axi_ad9361_0/adc_valid_i0  u_raw_iq/adc_valid_i0
lr_connect axi_ad9361_0/adc_data_i0   u_raw_iq/adc_data_i0
lr_connect axi_ad9361_0/adc_enable_q0 u_raw_iq/adc_enable_q0
lr_connect axi_ad9361_0/adc_valid_q0  u_raw_iq/adc_valid_q0
lr_connect axi_ad9361_0/adc_data_q0   u_raw_iq/adc_data_q0
lr_connect u_ts/timestamp u_raw_iq/timestamp
lr_connect u_sc/count_value u_raw_iq/sample_count

# Count a sample exactly once, when the raw stream transfer is accepted.
lr_connect u_raw_iq/sample_accepted u_sc/count_enable

# ===========================================================================
# 11. Control plane AXI
# ===========================================================================
lr_connect clk_fabric/clk_out1 jtag_axi_0/aclk
lr_connect rst_fabric/peripheral_aresetn jtag_axi_0/aresetn
lr_connect clk_fabric/clk_out1 u_cmac_init/M_AXI_aclk
lr_connect rst_fabric/peripheral_aresetn u_cmac_init/M_AXI_aresetn
foreach m {ACLK ARESETN S00_ACLK S00_ARESETN S01_ACLK S01_ARESETN S02_ACLK S02_ARESETN \
           S03_ACLK S03_ARESETN S04_ACLK S04_ARESETN \
           M00_ACLK M00_ARESETN M01_ACLK M01_ARESETN M02_ACLK M02_ARESETN \
           M03_ACLK M03_ARESETN} {
    if {[string match "*ACLK*" $m]} {
        if {$m eq "M02_ACLK" || $m eq "S01_ACLK" || $m eq "S03_ACLK"} {
            lr_connect ddr4_0/c0_ddr4_ui_clk axi_ic_0/$m
        } elseif {$m eq "M03_ACLK"} {
            # Register bank is in the 225 MHz fabric domain.  AXI Interconnect
            # performs the control-plane 100 -> 225 MHz conversion.
            lr_connect clk_fabric/clk_out1 axi_ic_0/$m
        } else {
            lr_connect clk_fabric/clk_out1 axi_ic_0/$m
        }
    } else {
        if {$m eq "M02_ARESETN" || $m eq "S01_ARESETN" || $m eq "S03_ARESETN"} {
            lr_connect rst_mig_ui/interconnect_aresetn axi_ic_0/$m
        } elseif {$m eq "M03_ARESETN"} {
            lr_connect rst_fabric/interconnect_aresetn axi_ic_0/$m
        } else {
            lr_connect rst_fabric/interconnect_aresetn axi_ic_0/$m
        }
    }
}
connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_ic_0/S00_AXI]
# Open JTAG-to-AXI bridge (BSCANE2 USER4) used by tools/hw/lr_jtagd - the
# host program talks to the FT2232H directly, no Vivado needed at runtime.
create_bd_cell -type module -reference lr_jtag_axi_bridge u_jbridge
lr_connect clk_fabric/clk_out1 u_jbridge/M_AXI_aclk
lr_connect rst_fabric/peripheral_aresetn u_jbridge/M_AXI_aresetn
connect_bd_intf_net [get_bd_intf_pins u_jbridge/M_AXI] [get_bd_intf_pins axi_ic_0/S04_AXI]
connect_bd_intf_net [get_bd_intf_pins u_cmac_init/M_AXI] [get_bd_intf_pins axi_ic_0/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_ad9361_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M02_AXI] [get_bd_intf_pins ddr4_0/C0_DDR4_S_AXI]
# M01_AXI -> cmac s_axi was connected above (if present)

# ===========================================================================
# 12. Complete data path: DSP chain + network + DDR + control (S3/S4 wiring)
# ===========================================================================

# ---- 12a. Stream fanout (raw IQ -> DDR / FM path / FFT path) ----
create_bd_cell -type module -reference dsp_router u_dspr
lr_connect clk_fabric/clk_out1 u_dspr/clk
lr_connect rst_fabric/peripheral_aresetn u_dspr/rst_n
connect_bd_intf_net [get_bd_intf_pins u_raw_iq/m] [get_bd_intf_pins u_dspr/s]

# ---- 12b. DSP chain: FM/audio path ----
create_bd_cell -type module -reference dc_correction u_dc
create_bd_cell -type module -reference ddc_mixer u_mixer
create_bd_cell -type module -reference complex_cic_decimator u_cic
create_bd_cell -type module -reference fm_demod u_fm
create_bd_cell -type module -reference audio_pipeline u_audio
create_bd_cell -type module -reference nco_phase_control u_nco_cfg
# The NCO lives in ddc_mixer and advances once per AD9361 sample, so the
# tuning word is computed against the sample rate (61.44 Msps baseline).
set_property CONFIG.SAMPLE_HZ {61440000} [get_bd_cells u_nco_cfg]
# FM Phase-1: channel meter (CIC -> meter -> demod), seek controller,
# non-blocking audio fan-out (DDR recorder / network), DDR audio recorder.
create_bd_cell -type module -reference fm_signal_meter u_meter
create_bd_cell -type module -reference fm_seek u_seek
create_bd_cell -type module -reference axis_fanout2_nb u_fan
create_bd_cell -type module -reference audio_pcm_packer u_pack

# ---- 12c. DSP chain: spectrum path ----
create_bd_cell -type module -reference window_mult u_wind
create_bd_cell -type module -reference spectrum_engine u_spec
create_bd_cell -type module -reference signal_detector u_det
create_bd_cell -type ip -vlnv xilinx.com:ip:xfft:9.1 xfft_0
set_property -dict [list \
    CONFIG.TRANSFORM_LENGTH {4096} \
    CONFIG.INPUT_WIDTH {16} \
] [get_bd_cells xfft_0]

# ---- 12d. Network: packetizer -> CMAC TX; CMAC RX counter ----
create_bd_cell -type module -reference lr_packetizer u_pkt
# Deterministic bring-up destination: broadcast Ethernet/IPv4.  Module-reference
# parameters are serialized into a proxy XCI, so set them explicitly here;
# changing only the Verilog default would leave an older generated XCI active.
set_property -dict [list \
    CONFIG.MAC_DST {0xFFFFFFFFFFFF} \
    CONFIG.IP_DST  {0xFFFFFFFF} \
] [get_bd_cells u_pkt]
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 fifo_cmac_tx_cdc
set_property -dict [list \
    CONFIG.FIFO_DEPTH {4096} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.HAS_TKEEP {true} \
    CONFIG.HAS_TLAST {true} \
    CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.FIFO_MODE {2} \
] [get_bd_cells fifo_cmac_tx_cdc]
# FIFO_MODE 2 = packet mode: a frame is released to the CMAC only once its
# TLAST is in the FIFO.  The packetizer emits low-rate audio frames sample by
# sample; streaming them straight into the 322 MHz CMAC TX underflowed in the
# middle of a packet (tx_unfout).

# ---- 12e. DDR ring buffer (AXI4 master on S01) ----
create_bd_cell -type module -reference ring_buffer u_ring
lr_connect clk_fabric/clk_out1 u_ring/s_clk
lr_connect rst_fabric/peripheral_aresetn u_ring/rst_n
# The MIG's 2 GiB AXI aperture is mapped at 0x8000_0000.  A zero base would
# issue every recorder transaction into an unmapped address range.
lr_connect const_ring_base/dout u_ring/base_addr
# Raw-IQ ring: 0x8000_0000 .. 0xFEFF_FFFF (2 GiB - 16 MiB).  The top 16 MiB
# belong to the audio ring, so the two recorders can never overlap.
lr_connect const_raw_ring_words26/dout u_ring/ring_size

# ---- 12e2. DDR audio ring (AXI4 master on S03): 0xFF00_0000, 16 MiB ----
# 16 MiB = 0x8_0000 x 32-byte words = ~174 s of 48 kHz int16 mono PCM.
create_bd_cell -type module -reference ring_buffer u_aring
lr_connect clk_fabric/clk_out1 u_aring/s_clk
lr_connect rst_fabric/peripheral_aresetn u_aring/rst_n
lr_connect const_audio_base/dout u_aring/base_addr
lr_connect const_audio_words26/dout u_aring/ring_size
# Session control is done by audio_pcm_packer (graceful stop + padding), so
# the ring itself always accepts words.
lr_connect const_one/dout u_aring/rec_enable

# ---- 12f. Control: register bank + telemetry + buttons ----
create_bd_cell -type module -reference register_bank u_reg
create_bd_cell -type module -reference telemetry u_tele
create_bd_cell -type module -reference lr_button_controller u_btn
create_bd_cell -type module -reference lr_uart_byte_phy u_uart
set_property -dict [list CONFIG.CLK_HZ {225014957} CONFIG.BAUD {115200}] [get_bd_cells u_uart]
create_bd_cell -type module -reference command_parser u_cmd
create_bd_cell -type module -reference lr_ad9361_spi_controller u_ad9361_spi
create_bd_cell -type module -reference mode_manager u_mode
create_bd_cell -type module -reference cdc_level_sync u_cmac_rx_level_sync
set_property CONFIG.WIDTH {6} [get_bd_cells u_cmac_rx_level_sync]
# CMAC RX/TX error events -> fabric: toggle pulse CDC (one fabric pulse per
# event).  The former sticky lr_cdc_event_latch was cleared only by a CMAC
# reset, so one historic event kept ERR_STATUS permanently set.  Instance
# names contain "pulse_cdc" for the lr_timing_convergence false paths.
create_bd_cell -type module -reference lr_pulse_cdc u_cmac_rx_pulse_cdc
set_property CONFIG.WIDTH {3} [get_bd_cells u_cmac_rx_pulse_cdc]
create_bd_cell -type module -reference lr_pulse_cdc u_cmac_tx_pulse_cdc
set_property CONFIG.WIDTH {3} [get_bd_cells u_cmac_tx_pulse_cdc]
set_property CONFIG.CLK_HZ {225014957} [get_bd_cells u_tele]
set_property -dict [list CONFIG.NUM_KEYS {4} CONFIG.CLK_HZ {99722537}] [get_bd_cells u_btn]
# 100M button events -> 225M telemetry counters: pulse CDC (toggle sync + edge)
create_bd_cell -type module -reference lr_pulse_cdc u_btn_pulse_cdc
set_property CONFIG.WIDTH {4} [get_bd_cells u_btn_pulse_cdc]
# Debounced key levels 100M -> 225M for the front-panel gesture logic.
create_bd_cell -type module -reference cdc_level_sync u_key_sync
set_property CONFIG.WIDTH {4} [get_bd_cells u_key_sync]
create_bd_cell -type module -reference ui_panel u_ui
set_property CONFIG.CLK_HZ {225014957} [get_bd_cells u_ui]

# ---- 12f2. Config slice / status concat / constant helpers ----
# (Vivado get_bd_pins cannot resolve bit-select [N] - use whole-bus cells)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_maxbin16
set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {4095}] [get_bd_cells const_maxbin16]
# MIG system reset: tie low (const_gnd) - proven F_SMART practice
lr_connect const_gnd/dout ddr4_0/sys_rst
lr_connect clk_fabric/clk_out1 u_ad9361_spi/clk
lr_connect rst_fabric/peripheral_aresetn u_ad9361_spi/rst_n
# The FMC_AD936X card puts RESETB on J1-D31 (the FMC TDO pin), which the
# RK-XCKU5P-F carrier does not route as FPGA GPIO.  The card already provides
# a 10 kohm pull-up, so no external reset port is created or driven here.
lr_connect u_ad9361_spi/spi_csn spi_csn
lr_connect u_ad9361_spi/serial_out spi_sclk
lr_connect u_ad9361_spi/spi_mosi spi_mosi
lr_connect spi_miso u_ad9361_spi/spi_miso

proc lr_slice {name in_pin from to out_pin din_w} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 $name
    set_property -dict [list \
        CONFIG.DIN_WIDTH  $din_w \
        CONFIG.DIN_FROM   $from \
        CONFIG.DIN_TO     $to \
        CONFIG.DOUT_WIDTH [expr {$from - $to + 1}] \
    ] [get_bd_cells $name]
    lr_connect $in_pin ${name}/Din
    if {$out_pin ne ""} {
        lr_connect ${name}/Dout $out_pin
    }
}
proc lr_concat {name ports} {
    # ports: list of {pin width} or {pin width const} - constant ports left
    # unconnected (xlconcat ties unused InN inputs to 0 automatically)
    set n [llength $ports]
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 $name
    set cfg [list CONFIG.NUM_PORTS $n]
    set idx 0
    foreach p $ports {
        lappend cfg "CONFIG.IN${idx}_WIDTH" [lindex $p 1]
        incr idx
    }
    set_property -dict $cfg [get_bd_cells $name]
    set idx 0
    foreach p $ports {
        if {[llength $p] <= 2 || [lindex $p 2] ne "const"} {
            lr_connect [lindex $p 0] ${name}/In${idx}
        }
        incr idx
    }
    return ${name}/Dout
}

# Software stream enables: bit0 RAW/DDR, bit2 spectrum, bit3 audio/network,
# bit4 detection.  dsp_router outputs are m0=FM/audio, m1=DDR, m2=spectrum,
# m3=raw network.
lr_slice sl_en_raw   u_reg/reg_stream_en 0 0 "" 6
lr_slice sl_en_spec  u_reg/reg_stream_en 2 2 "" 6
lr_slice sl_en_audio u_reg/reg_stream_en 3 3 "" 6
lr_slice sl_en_det   u_reg/reg_stream_en 4 4 "" 6
lr_slice sl_ddr_rec  u_reg/reg_ddr_mode 0 0 "" 32
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 and_ddr_en
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] [get_bd_cells and_ddr_en]
lr_connect sl_en_raw/Dout and_ddr_en/Op1
lr_connect sl_ddr_rec/Dout and_ddr_en/Op2
set router_en [lr_concat xc_router_en [list \
    [list sl_en_audio/Dout 1] \
    [list and_ddr_en/Res 1] \
    [list sl_en_spec/Dout 1] \
    [list sl_en_raw/Dout 1]]]
lr_connect $router_en u_dspr/en_mask
lr_connect sl_ddr_rec/Dout u_ring/rec_enable

# ===========================================================================
# 12g. DSP wiring (FM/audio path)
# ===========================================================================
lr_connect clk_fabric/clk_out1 u_dc/clk
lr_connect rst_fabric/peripheral_aresetn u_dc/rst_n
lr_connect clk_fabric/clk_out1 u_mixer/clk
lr_connect rst_fabric/peripheral_aresetn u_mixer/rst_n
lr_connect clk_fabric/clk_out1 u_fm/clk
lr_connect rst_fabric/peripheral_aresetn u_fm/rst_n
lr_connect clk_fabric/clk_out1 u_cic/clk
lr_connect rst_fabric/peripheral_aresetn u_cic/rst_n
lr_connect u_reg/reg_decim u_cic/decim_rate
lr_connect clk_fabric/clk_out1 u_audio/clk
lr_connect rst_fabric/peripheral_aresetn u_audio/rst_n
lr_connect clk_fabric/clk_out1 u_nco_cfg/clk
lr_connect rst_fabric/peripheral_aresetn u_nco_cfg/rst_n

connect_bd_intf_net [get_bd_intf_pins u_dspr/m0] [get_bd_intf_pins u_dc/s]
lr_connect u_reg/reg_ddc_freq u_nco_cfg/freq_hz
lr_connect u_nco_cfg/cfg_tdata u_mixer/pinc_tdata
lr_connect u_nco_cfg/cfg_tvalid u_mixer/pinc_tvalid
# ddc_mixer latches every tuning word it is offered.
lr_connect const_one/dout u_nco_cfg/cfg_tready
connect_bd_intf_net [get_bd_intf_pins u_dc/m] [get_bd_intf_pins u_mixer/s]
connect_bd_intf_net [get_bd_intf_pins u_mixer/m] [get_bd_intf_pins u_cic/s]
connect_bd_intf_net [get_bd_intf_pins u_cic/m] [get_bd_intf_pins u_meter/s]
connect_bd_intf_net [get_bd_intf_pins u_meter/m] [get_bd_intf_pins u_fm/s]
connect_bd_intf_net [get_bd_intf_pins u_fm/m] [get_bd_intf_pins u_audio/s]
# audio gain: software-controlled (reg_audio_cfg[15:0]), default 0x7FFF = unity
lr_slice sl_gain u_reg/reg_audio_cfg 15 0 u_audio/gain 32
# de-emphasis: AUDIO_CFG[18] 0 = 50 us (China/EU, default), 1 = 75 us
lr_slice sl_deem u_reg/reg_audio_cfg 18 18 u_audio/deemph_75us 32
# DC offset bypass (reg_control[0], default 0 = correction active)
lr_slice sl_dc_byp u_reg/reg_control 0 0 u_dc/bypass 32

# ---- 12g2. Channel meter + seek controller ----
lr_connect clk_fabric/clk_out1 u_meter/clk
lr_connect rst_fabric/peripheral_aresetn u_meter/rst_n
lr_connect clk_fabric/clk_out1 u_seek/clk
lr_connect rst_fabric/peripheral_aresetn u_seek/rst_n
lr_slice sl_meter_thr  u_reg/reg_seek_thr 15 0  u_meter/thr_q8    32
lr_slice sl_meter_minp u_reg/reg_seek_thr 31 16 u_meter/min_power 32
lr_slice sl_seek_step  u_reg/reg_seek_cfg 15 0  u_seek/step_khz   32
lr_slice sl_seek_range u_reg/reg_seek_cfg 31 16 u_seek/range_khz  32
lr_connect u_seek/meter_restart u_meter/restart
lr_connect u_meter/result_valid u_seek/meter_valid
lr_connect u_meter/power_mean u_seek/meter_power
lr_connect u_meter/station_ok u_seek/meter_ok
lr_connect u_reg/reg_ddc_freq u_seek/cur_freq
lr_connect u_seek/freq_wr_valid u_reg/int_ddc_valid
lr_connect u_seek/freq_wr_data u_reg/int_ddc_data
lr_connect u_reg/seek_cmd_valid u_seek/host_cmd_valid
lr_connect u_reg/seek_cmd u_seek/host_cmd
lr_connect u_reg/ddc_bus_wr u_seek/host_abort
lr_connect u_ui/cmd_seek_up u_seek/cmd_seek_up
lr_connect u_ui/cmd_seek_down u_seek/cmd_seek_down
lr_connect u_ui/cmd_cancel u_seek/cmd_cancel
lr_connect u_ui/cmd_step_up u_seek/cmd_step_up
lr_connect u_ui/cmd_step_down u_seek/cmd_step_down
lr_connect u_ui/cmd_zero u_seek/cmd_zero

# ===========================================================================
# 12h. DSP wiring (spectrum path)
# ===========================================================================
lr_connect clk_fabric/clk_out1 u_wind/clk
lr_connect rst_fabric/peripheral_aresetn u_wind/rst_n
lr_connect clk_fabric/clk_out1 u_spec/clk
lr_connect rst_fabric/peripheral_aresetn u_spec/rst_n
lr_connect clk_fabric/clk_out1 u_det/clk
lr_connect rst_fabric/peripheral_aresetn u_det/rst_n
lr_connect xfft_0/aclk clk_fabric/clk_out1
# xFFT config: keep default transform config (tvalid asserted via const_one)
lr_connect const_one/dout xfft_0/s_axis_config_tvalid
lr_connect const_one16/dout xfft_0/s_axis_config_tdata

# Spectrum frame decimation: 1 of N frames (FFT_CFG[15:8], <2 -> 4) so the
# 4-clock/bin spectrum_engine keeps up; dsp_router m2 no longer overflows.
create_bd_cell -type module -reference axis_frame_decim u_fdec
lr_connect clk_fabric/clk_out1 u_fdec/clk
lr_connect rst_fabric/peripheral_aresetn u_fdec/rst_n
lr_slice sl_fft_decim u_reg/reg_fft_cfg 15 8 u_fdec/factor 32
connect_bd_intf_net [get_bd_intf_pins u_dspr/m2] [get_bd_intf_pins u_fdec/s]
connect_bd_intf_net [get_bd_intf_pins u_fdec/m] [get_bd_intf_pins u_wind/s]
connect_bd_intf_net [get_bd_intf_pins u_wind/m] [get_bd_intf_pins xfft_0/S_AXIS_DATA]
# window select: software-controlled (reg_fft_cfg[1:0], default 0 = rectangular,
# any nonzero value selects the currently provided Hanning ROM)
lr_slice sl_winsel u_reg/reg_fft_cfg 1 0 u_wind/win_sel 32
connect_bd_intf_net [get_bd_intf_pins xfft_0/M_AXIS_DATA] [get_bd_intf_pins u_spec/s]
connect_bd_intf_net [get_bd_intf_pins u_spec/m] [get_bd_intf_pins u_det/s]
# detector config: threshold = reg_det_cfg[15:0], min_bin = reg_det_cfg[31:16],
# max_bin = fixed 4095 (full 4096-bin FFT scan window)
lr_slice sl_thr    u_reg/reg_det_cfg 15 0  u_det/threshold 32
lr_slice sl_minbin u_reg/reg_det_cfg 31 16 u_det/min_bin    32
lr_connect const_maxbin16/dout u_det/max_bin
lr_connect sl_en_det/Dout u_det/enable
lr_connect const_one/dout u_det/ev_tready
# detector timestamp: low 32 bits of 64-bit fabric timestamp (software-visible)
lr_slice sl_det_ts u_ts/timestamp 31 0 u_det/ts_in 64
# spectrum engine config: avg_alpha = reg_spec_cfg[15:0], peak_hold = [16], bypass = [17]
lr_slice sl_avg   u_reg/reg_spec_cfg 15 0  u_spec/avg_alpha 32
lr_slice sl_phold u_reg/reg_spec_cfg 16 16 u_spec/peak_hold 32
lr_slice sl_sbyp  u_reg/reg_spec_cfg 17 17 u_spec/bypass     32

# ===========================================================================
# 12i. Network wiring (audio/raw IQ mux -> packetizer -> CMAC TX)
# ===========================================================================
create_bd_cell -type module -reference lr_axis_stream_mux2 u_net_mux
lr_connect clk_fabric/clk_out1 u_net_mux/clk
lr_connect rst_fabric/peripheral_aresetn u_net_mux/rst_n
lr_connect clk_fabric/clk_out1 u_pkt/clk
lr_connect rst_fabric/peripheral_aresetn u_pkt/rst_n
# Mode changes are applied only at a packet boundary.  FM selects audio;
# General SDR selects the additional raw-IQ fanout branch.
lr_connect clk_fabric/clk_out1 u_mode/clk
lr_connect rst_fabric/peripheral_aresetn u_mode/rst_n
lr_connect u_reg/reg_mode u_mode/mode_sel
lr_connect u_pkt/idle u_mode/mode_load
lr_slice sl_mode_raw u_mode/mode_active 0 0 u_net_mux/select_raw 2
# AUDIO_CFG[16] = DDR recording, AUDIO_CFG[17] = network audio.  The FM chain
# itself stays gated by STREAM_EN[3]; KEY4 / NET only affects the network.
lr_slice sl_audio_rec u_reg/reg_audio_cfg 16 16 "" 32
lr_slice sl_audio_net u_reg/reg_audio_cfg 17 17 "" 32
lr_connect sl_audio_net/Dout u_net_mux/audio_enable
lr_connect sl_en_raw/Dout u_net_mux/raw_enable
# Non-blocking fan-out: a stalled/disconnected CMAC path can never stop the
# DDR recorder or the FM chain (and vice versa).  Seek mutes both branches.
lr_connect clk_fabric/clk_out1 u_fan/clk
lr_connect rst_fabric/peripheral_aresetn u_fan/rst_n
lr_connect const_one/dout u_fan/en0
lr_connect sl_audio_net/Dout u_fan/en1
lr_connect u_seek/mute u_fan/mute
connect_bd_intf_net [get_bd_intf_pins u_audio/m] [get_bd_intf_pins u_fan/s]
connect_bd_intf_net [get_bd_intf_pins u_fan/m1] [get_bd_intf_pins u_net_mux/s0]
lr_connect clk_fabric/clk_out1 u_pack/clk
lr_connect rst_fabric/peripheral_aresetn u_pack/rst_n
lr_connect sl_audio_rec/Dout u_pack/enable
connect_bd_intf_net [get_bd_intf_pins u_fan/m0] [get_bd_intf_pins u_pack/s]
connect_bd_intf_net [get_bd_intf_pins u_pack/m] [get_bd_intf_pins u_aring/s]
connect_bd_intf_net [get_bd_intf_pins u_dspr/m3] [get_bd_intf_pins u_net_mux/s1]
connect_bd_intf_net [get_bd_intf_pins u_net_mux/m] [get_bd_intf_pins u_pkt/s]
lr_connect u_net_mux/tx_enable u_pkt/tx_enable
lr_connect u_net_mux/flow_sel u_pkt/flow_sel
lr_connect u_ts/timestamp u_pkt/timestamp
lr_connect u_raw_iq/m_sample_count u_pkt/sample_count

# packetizer (225M) -> CMAC TX (322.27M gt_txusrclk2) via async fifo
lr_connect clk_fabric/clk_out1 fifo_cmac_tx_cdc/s_axis_aclk
lr_connect rst_fabric/peripheral_aresetn fifo_cmac_tx_cdc/s_axis_aresetn
lr_connect cmac_0/gt_txusrclk2 fifo_cmac_tx_cdc/m_axis_aclk
connect_bd_intf_net [get_bd_intf_pins u_pkt/m] [get_bd_intf_pins fifo_cmac_tx_cdc/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins fifo_cmac_tx_cdc/M_AXIS] [get_bd_intf_pins cmac_0/axis_tx]

# ===========================================================================
# 12j. DDR ring (stream 0 -> DDR) + AXI master to S01
# ===========================================================================
lr_connect ddr4_0/c0_ddr4_ui_clk u_ring/M_AXI_aclk
lr_connect rst_mig_ui/peripheral_aresetn u_ring/M_AXI_aresetn
connect_bd_intf_net [get_bd_intf_pins u_dspr/m1] [get_bd_intf_pins u_ring/s]
connect_bd_intf_net [get_bd_intf_pins u_ring/M_AXI] [get_bd_intf_pins axi_ic_0/S01_AXI]
lr_connect ddr4_0/c0_ddr4_ui_clk u_aring/M_AXI_aclk
lr_connect rst_mig_ui/peripheral_aresetn u_aring/M_AXI_aresetn
connect_bd_intf_net [get_bd_intf_pins u_aring/M_AXI] [get_bd_intf_pins axi_ic_0/S03_AXI]

# ===========================================================================
# 12k. Control wiring (register bank / telemetry / buttons / LED)
# ===========================================================================
lr_connect clk_fabric/clk_out1 u_reg/s_axi_aclk
lr_connect rst_fabric/peripheral_aresetn u_reg/s_axi_aresetn
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M03_AXI] [get_bd_intf_pins u_reg/S_AXI]
lr_connect u_reg/spi_tx_data u_ad9361_spi/transaction_tx
lr_connect u_reg/spi_start u_ad9361_spi/start
lr_connect u_ad9361_spi/transaction_rx u_reg/spi_rx_data
lr_connect u_ad9361_spi/busy u_reg/spi_busy
lr_connect u_ad9361_spi/done u_reg/spi_done
lr_connect u_tele/err_status u_reg/err_status_in
lr_connect u_tele/uptime_sec u_reg/uptime_in
lr_connect u_det/ev_tdata u_reg/det_event_in
lr_connect u_tele/rdata u_reg/tele_rdata
lr_connect u_reg/tele_addr u_tele/addr
# CMAC statistics cross from independent RX/TX user clocks.  Synchronize
# levels and source-latch short events before exposing them to fabric logic.
set cmac_rx_levels [lr_concat xc_cmac_rx_levels [list \
    [list cmac_0/stat_rx_status 1] \
    [list cmac_0/stat_rx_aligned 1] \
    [list cmac_0/stat_rx_aligned_err 1] \
    [list cmac_0/stat_rx_hi_ber 1] \
    [list cmac_0/stat_rx_local_fault 1] \
    [list cmac_0/stat_rx_remote_fault 1]]]
set cmac_tx_events [lr_concat xc_cmac_tx_events [list \
    [list cmac_0/tx_ovfout 1] \
    [list cmac_0/tx_unfout 1] \
    [list cmac_0/stat_tx_bad_fcs 1]]]
foreach c {u_cmac_rx_level_sync u_cmac_rx_pulse_cdc u_cmac_tx_pulse_cdc} {
    lr_connect clk_fabric/clk_out1 ${c}/dst_clk
    lr_connect rst_fabric/peripheral_aresetn ${c}/dst_rst_n
}
lr_connect $cmac_rx_levels u_cmac_rx_level_sync/level_in
# Source-side toggles start from configuration state (no GT-domain reset).
lr_connect cmac_0/gt_rxusrclk2 u_cmac_rx_pulse_cdc/src_clk
lr_connect const_one/dout u_cmac_rx_pulse_cdc/src_rst_n
lr_connect cmac_0/stat_rx_bad_fcs u_cmac_rx_pulse_cdc/pulse_in
lr_connect cmac_0/gt_txusrclk2 u_cmac_tx_pulse_cdc/src_clk
lr_connect const_one/dout u_cmac_tx_pulse_cdc/src_rst_n
lr_connect $cmac_tx_events u_cmac_tx_pulse_cdc/pulse_in
lr_slice sl_cmac_rx_status u_cmac_rx_level_sync/level_out 0 0 "" 6
lr_slice sl_cmac_rx_align  u_cmac_rx_level_sync/level_out 1 1 "" 6
# status feedback (whole-bus concats)
lr_slice sl_dropcnt u_dspr/drop_count 15 0 "" 32
lr_slice sl_cmdcnt u_cmd/cmd_count 7 0 "" 32
lr_slice sl_badcmd u_cmd/invalid_count 3 0 "" 32
set s_dspr  [lr_concat xc_st_dspr  [list \
    [list sl_dropcnt/Dout 16] [list sl_cmdcnt/Dout 8] \
    [list sl_badcmd/Dout 4] [list u_sc/carry 1] \
    [list u_uart/framing_error 1] [list u_mode/mode_valid 1] \
    [list const_gnd/dout 1]]]
lr_slice sl_rdptr u_ring/rd_ptr 14 0 "" 26
lr_slice sl_wrwords u_ring/wr_words 13 0 "" 32
# MIG calib_complete (333M UI) -> fabric 225M status: level sync
create_bd_cell -type module -reference cdc_level_sync u_calib_sync
set_property CONFIG.WIDTH {1} [get_bd_cells u_calib_sync]
lr_connect clk_fabric/clk_out1 u_calib_sync/dst_clk
lr_connect rst_fabric/peripheral_aresetn u_calib_sync/dst_rst_n
lr_connect ddr4_0/c0_init_calib_complete u_calib_sync/level_in
set s_ring  [lr_concat xc_st_ring  [list [list sl_wrwords/Dout 14] [list sl_rdptr/Dout 15] [list u_calib_sync/level_out 1] [list u_ring/ring_full 1] [list u_ring/axi_write_error 1]]]
lr_slice sl_rawts u_raw_iq/m_timestamp 15 0 "" 64
lr_slice sl_sampcnt u_sc/count_value 9 0 "" 64
# AD9361 r1_mode (l_clk domain) -> fabric 225M status: level sync
create_bd_cell -type module -reference cdc_level_sync u_r1mode_sync
set_property CONFIG.WIDTH {1} [get_bd_cells u_r1mode_sync]
lr_connect clk_fabric/clk_out1 u_r1mode_sync/dst_clk
lr_connect rst_fabric/peripheral_aresetn u_r1mode_sync/dst_rst_n
lr_connect axi_ad9361_0/adc_r1_mode u_r1mode_sync/level_in
set s_rf    [lr_concat xc_st_rf    [list [list u_raw_iq/fifo_overflow 1] [list u_dspr/drop_event 1] [list u_tele/err_pulse 1] [list u_ts/tick 1] [list clk_wiz_iodelay/locked 1] [list u_r1mode_sync/level_out 1] [list sl_rawts/Dout 16] [list sl_sampcnt/Dout 10]]]
lr_slice sl_ovfcnt u_ring/overflow_cnt 3 0 "" 32
lr_slice sl_pktcnt u_pkt/pkt_count 7 0 "" 32
set s_net   [lr_concat xc_st_net   [list [list u_spec/noise_floor 16] [list u_spec/frame_done 1] [list u_det/ev_count_pulse 1] [list u_ring/ring_full 1] [list sl_cmac_rx_status/Dout 1] [list sl_ovfcnt/Dout 4] [list sl_pktcnt/Dout 8]]]
lr_connect $s_dspr u_reg/status_in
lr_connect $s_rf   u_reg/rf_status_in
lr_connect $s_ring u_reg/ddr_status_in
lr_connect $s_net  u_reg/net_status_in
# Audio status: [0]ring fifo full [1]axi err [2]rec active [3]0
#               [7:4]net drops [15:8]pack drops [31:16]ring overflow
lr_slice sl_aud_netdrop u_fan/drop1_count 3 0 "" 16
lr_slice sl_aud_pkdrop  u_pack/drop_count 7 0 "" 32
lr_slice sl_aud_ovf     u_aring/overflow_cnt 15 0 "" 32
set s_audio [lr_concat xc_st_audio [list \
    [list u_aring/ring_full 1] \
    [list u_aring/axi_write_error 1] \
    [list u_pack/rec_active 1] \
    [list const_gnd/dout 1] \
    [list sl_aud_netdrop/Dout 4] \
    [list sl_aud_pkdrop/Dout 8] \
    [list sl_aud_ovf/Dout 16]]]
lr_connect $s_audio u_reg/audio_status_in
lr_connect u_aring/wr_words u_reg/audio_wr_words_in
lr_connect const_audio_base/dout u_reg/audio_ring_base_in
lr_connect const_audio_words32/dout u_reg/audio_ring_words_in
lr_connect u_pack/rec_start_words u_reg/audio_rec_start_in
lr_connect u_ui/ui_status u_reg/ui_status_in
set s_seek [lr_concat xc_st_seek [list \
    [list u_seek/status 8] \
    [list const_gnd24/dout 24]]]
lr_connect $s_seek u_reg/seek_status_in
lr_connect u_meter/power_mean u_reg/sig_power_in
set s_sigq [lr_concat xc_st_sigq [list \
    [list u_meter/flat_q8 16] \
    [list u_meter/station_ok 1] \
    [list const_gnd7/dout 7] \
    [list u_meter/result_count 8]]]
lr_connect $s_sigq u_reg/sig_quality_in
lr_connect u_ui/cmd_rec_toggle u_reg/ui_rec_toggle
lr_connect u_ui/cmd_net_toggle u_reg/ui_net_toggle
lr_connect clk_fabric/clk_out1 u_uart/clk
lr_connect rst_fabric/peripheral_aresetn u_uart/rst_n
lr_connect uart_rx u_uart/uart_rx
lr_connect u_uart/uart_tx uart_tx
lr_connect clk_fabric/clk_out1 u_cmd/clk
lr_connect rst_fabric/peripheral_aresetn u_cmd/rst_n
lr_connect u_uart/rx_valid u_cmd/rx_valid
lr_connect u_uart/rx_data u_cmd/rx_data
lr_connect u_cmd/tx_load u_uart/tx_load
lr_connect u_cmd/tx_data u_uart/tx_data
lr_connect u_uart/tx_busy u_cmd/tx_busy
lr_connect u_cmd/cfg_wr_valid u_reg/cfg_wr_valid
lr_connect u_cmd/cfg_wr_addr u_reg/cfg_wr_addr
lr_connect u_cmd/cfg_wr_data u_reg/cfg_wr_data
lr_connect u_cmd/cfg_rd_valid u_reg/cfg_rd_valid
lr_connect u_cmd/cfg_rd_addr u_reg/cfg_rd_addr
lr_connect u_reg/cfg_rd_data u_cmd/cfg_rd_data

# telemetry strobes: rx words / detect events / tx packets
lr_connect clk_fabric/clk_out1 u_tele/clk
lr_connect rst_fabric/peripheral_aresetn u_tele/rst_n
set t_inc [lr_concat xc_t_inc [list \
    [list fifo_cmac_rx_cdc/m_axis_tvalid 1] \
    [list u_det/ev_tvalid 1] \
    [list u_pkt/pkt_count_pulse 1] \
    [list u_dspr/drop_event 1] \
    [list u_reg/wr_strobe 1] \
    [list xfft_0/event_frame_started 1] \
    [list u_mode/mode_changed 1] \
    [list u_btn_pulse_cdc/pulse_out 4] \
    [list const_gnd5/dout 5]]]
# Reduce multi-bit and related error groups to sticky telemetry classes.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_reduced_logic:2.0 red_cmac_rxfcs
set_property -dict [list CONFIG.C_SIZE {3} CONFIG.C_OPERATION {or}] [get_bd_cells red_cmac_rxfcs]
lr_connect u_cmac_rx_pulse_cdc/pulse_out red_cmac_rxfcs/Op1
# xFFT data_in/data_out "halt" events only mean the core waited for input
# (61.44 Msps into a 225 MHz core, plus decimated frames) or for the 4-clock
# spectrum_engine; nothing is lost (losses show up as dsp_router drops).
# Only the status channel halt is a genuine processing error.
set proc_err [lr_concat xc_proc_err [list \
    [list xfft_0/event_status_channel_halt 1] \
    [list u_uart/framing_error 1]]]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_reduced_logic:2.0 red_proc_err
set_property -dict [list CONFIG.C_SIZE {2} CONFIG.C_OPERATION {or}] [get_bd_cells red_proc_err]
lr_connect $proc_err red_proc_err/Op1
create_bd_cell -type ip -vlnv xilinx.com:ip:util_reduced_logic:2.0 red_cmac_txerr
set_property -dict [list CONFIG.C_SIZE {3} CONFIG.C_OPERATION {or}] [get_bd_cells red_cmac_txerr]
lr_connect u_cmac_tx_pulse_cdc/pulse_out red_cmac_txerr/Op1
set ring_err [lr_concat xc_ring_err [list \
    [list u_ring/ring_full 1] \
    [list u_ring/axi_write_error 1]]]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_reduced_logic:2.0 red_ring_err
set_property -dict [list CONFIG.C_SIZE {2} CONFIG.C_OPERATION {or}] [get_bd_cells red_ring_err]
lr_connect $ring_err red_ring_err/Op1
set t_err [lr_concat xc_t_err [list \
    [list u_raw_iq/fifo_overflow 1] \
    [list u_dspr/drop_event 1] \
    [list red_ring_err/Res 1] \
    [list xfft_0/event_tlast_missing 1] \
    [list xfft_0/event_tlast_unexpected 1] \
    [list red_proc_err/Res 1] \
    [list red_cmac_rxfcs/Res 1] \
    [list red_cmac_txerr/Res 1]]]
lr_connect $t_inc u_tele/inc
lr_connect $t_err u_tele/err_strobe
lr_connect u_reg/err_clear u_tele/clear_all

# Four-key controller remains connected for commands/telemetry.  LEDs are
# deterministic bring-up indicators: clocks, DDR, CMAC init, CMAC link.
lr_connect clk_fabric/clk_out2 u_btn/clk
lr_connect rst_cmac_100/peripheral_aresetn u_btn/rst_n
lr_connect key_in u_btn/key_in
# button-event pulse CDC: 100M source -> 225M telemetry
lr_connect clk_fabric/clk_out2 u_btn_pulse_cdc/src_clk
lr_connect rst_cmac_100/peripheral_aresetn u_btn_pulse_cdc/src_rst_n
lr_connect clk_fabric/clk_out1 u_btn_pulse_cdc/dst_clk
lr_connect rst_fabric/peripheral_aresetn u_btn_pulse_cdc/dst_rst_n
lr_connect u_btn/key_press u_btn_pulse_cdc/pulse_in
# Front panel: debounced key levels -> 225M, gestures, LED patterns.
lr_connect clk_fabric/clk_out1 u_key_sync/dst_clk
lr_connect rst_fabric/peripheral_aresetn u_key_sync/dst_rst_n
lr_connect u_btn/key_level u_key_sync/level_in
lr_connect clk_fabric/clk_out1 u_ui/clk
lr_connect rst_fabric/peripheral_aresetn u_ui/rst_n
lr_connect u_key_sync/level_out u_ui/key_level
lr_connect u_mode/mode_active u_ui/mode_active
lr_slice sl_panel_lock u_reg/reg_control 1 1 u_ui/panel_lock 32
lr_connect u_seek/busy u_ui/seek_busy
lr_connect u_seek/evt_notfound u_ui/evt_notfound
lr_connect u_seek/evt_limit u_ui/evt_limit
lr_connect u_calib_sync/level_out u_ui/calib_ok
lr_connect u_tele/err_status u_ui/err_status
lr_connect u_raw_iq/sample_accepted u_ui/sample_pulse
lr_connect u_meter/station_ok u_ui/station_ok
lr_connect u_pack/rec_active u_ui/rec_on
lr_connect u_pack/drop_pulse u_ui/rec_drop_pulse
lr_connect sl_audio_net/Dout u_ui/net_on
lr_connect sl_cmac_rx_align/Dout u_ui/link_up
lr_connect u_fan/drop1_pulse u_ui/net_drop_pulse
lr_connect u_ui/led led

# ===========================================================================
# 13. Address map + validate
# ===========================================================================
assign_bd_address
validate_bd_design
puts "=== LR FULL BD assembled (MIG + CMAC + AD9361 + DSP + network + DDR + control) ==="
puts "    Next: lr_constraints*.tcl -> lr_wrapper.tcl -> lr_build.tcl"
