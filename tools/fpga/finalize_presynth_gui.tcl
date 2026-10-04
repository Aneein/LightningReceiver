# Final presynthesis checks for the currently open LightningReceiver project.
# This script does not launch or reset synthesis/implementation runs.
if {[current_project -quiet] eq ""} {
    error "Open LightningReceiver.xpr before sourcing this script."
}

set lr_root D:/workspace/LightningReceiver
set lr_rtl $lr_root/rtl/network/cmac_axil_init.v
if {![file exists $lr_rtl]} {
    error "Missing RTL source: $lr_rtl"
}
if {[llength [get_files -quiet $lr_rtl]] != 1} {
    error "cmac_axil_init.v is not registered exactly once in sources_1"
}

# Vivado 2021.1 does not allow Tcl control-flow commands inside an XDC file.
# Also keep the QSFP clock-group name aligned with the actual primary clock
# created for the differential qsfp_refclk_p port.
set lr_timing_xdc $lr_root/fpga/LightningReceiver/lr_timing_convergence.xdc
set lr_fmc_xdc $lr_root/fpga/LightningReceiver/lr_fmc_ad9361.xdc
foreach lr_xdc [list $lr_timing_xdc $lr_fmc_xdc] {
    if {![file exists $lr_xdc]} {
        error "Missing constraint file: $lr_xdc"
    }
}
set lr_fd [open $lr_timing_xdc r]
set lr_timing_text [read $lr_fd]
close $lr_fd
if {[regexp -line {^[ \t]*foreach([ \t]|$)} $lr_timing_text]} {
    error "Unsupported foreach command remains in lr_timing_convergence.xdc"
}
set lr_fd [open $lr_fmc_xdc r]
set lr_fmc_text [read $lr_fd]
close $lr_fd
if {![regexp {get_clocks[^\n]*qsfp_refclk_p} $lr_fmc_text]} {
    error "QSFP asynchronous clock group does not reference qsfp_refclk_p"
}
if {[regexp {get_clocks[^\n]*qsfp_refclk([^_[:alnum:]]|$)} $lr_fmc_text]} {
    error "Stale non-existent qsfp_refclk clock name remains in lr_fmc_ad9361.xdc"
}

# Freeze the board-to-card cross-check at the presynthesis gate.  These are
# the RK-XCKU5P-F V1.2 package pins for FMC LA00..LA07, LA16 and LA26..LA27;
# the FMC_AD936X card schematic assigns those channels to RX LVDS, ENABLE /
# TXNRX and SPI respectively.  Exact-line checks intentionally catch P/N
# swaps, package-pin drift, an accidental return to LVDS_25/LVCMOS25, or loss
# of the on-die 100-ohm RX termination before a run consumes the XDC.
set lr_expected_fmc_constraints {
    {set_property -dict {PACKAGE_PIN G24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_clk_in_p]}
    {set_property -dict {PACKAGE_PIN G25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_clk_in_n]}
    {set_property -dict {PACKAGE_PIN J23 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_frame_in_p]}
    {set_property -dict {PACKAGE_PIN J24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_frame_in_n]}
    {set_property -dict {PACKAGE_PIN H21 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[0]}]}
    {set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[0]}]}
    {set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[1]}]}
    {set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[1]}]}
    {set_property -dict {PACKAGE_PIN H26 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[2]}]}
    {set_property -dict {PACKAGE_PIN G26 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[2]}]}
    {set_property -dict {PACKAGE_PIN F24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[3]}]}
    {set_property -dict {PACKAGE_PIN F25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[3]}]}
    {set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[4]}]}
    {set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[4]}]}
    {set_property -dict {PACKAGE_PIN D24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[5]}]}
    {set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[5]}]}
    {set_property -dict {PACKAGE_PIN E21 IOSTANDARD LVCMOS18} [get_ports enable]}
    {set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS18} [get_ports txnrx]}
    {set_property -dict {PACKAGE_PIN A19 IOSTANDARD LVCMOS18 PULLUP TRUE} [get_ports spi_csn]}
    {set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS18} [get_ports spi_sclk]}
    {set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS18} [get_ports spi_mosi]}
    {set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS18} [get_ports spi_miso]}
}
foreach lr_line $lr_expected_fmc_constraints {
    if {[string first $lr_line $lr_fmc_text] < 0} {
        error "Missing or changed frozen FMC constraint: $lr_line"
    }
}

set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1
set lr_bd [get_files -quiet */system.bd]
if {[llength $lr_bd] != 1} {
    error "Expected exactly one system.bd, found [llength $lr_bd]"
}
open_bd_design $lr_bd

# Refresh the button-controller module reference after synchronizer RTL
# changes.  Generating BD targets alone does not clear Vivado's
# "Module references are out-of-date" state.
set lr_btn_cell [get_bd_cells -quiet u_btn]
set lr_btn_ip [get_ips -quiet system_u_btn_0]
if {[llength $lr_btn_cell] != 1 || [llength $lr_btn_ip] != 1} {
    error "Expected one u_btn cell and system_u_btn_0 proxy IP"
}
# Source management and compile order were refreshed above.  Update the
# generated module-reference proxy object registered with get_ips.
update_module_reference $lr_btn_ip

# Module-reference parameters are persisted in generated proxy XCIs.  Pin the
# bring-up packet destination here as well as in the BD generator, otherwise a
# stale unicast MAC/IP can survive a Verilog-default change and make a healthy
# link appear silent on the host.
set lr_pkt [get_bd_cells -quiet u_pkt]
if {[llength $lr_pkt] != 1} {
    error "Missing u_pkt packetizer BD module"
}
set_property -dict [list \
    CONFIG.MAC_DST {0xFFFFFFFFFFFF} \
    CONFIG.IP_DST  {0xFFFFFFFF} \
] $lr_pkt

# RESETB is J1-D31/FMC-TDO on the AD936X card and is not a carrier FPGA GPIO.
# A stale gpio_resetb boundary port used to drive LA23/CTRL_OUT6, causing an
# electrical-direction conflict with an AD9361 output.
if {[llength [get_bd_ports -quiet gpio_resetb]] != 0} {
    error "Stale gpio_resetb BD port remains; delete it and rely on card pull-up"
}

# Check the module reference that previously produced the invalid proxy XCI.
set lr_cmac_init [get_bd_cells -quiet u_cmac_init]
if {[llength $lr_cmac_init] != 1} {
    error "Missing u_cmac_init BD module"
}
foreach lr_obj {u_cmac_init/M_AXI u_cmac_init/M_AXI_aclk u_cmac_init/M_AXI_aresetn u_cmac_init/init_done u_cmac_init/init_error u_cmac_init/init_step} {
    if {[llength [get_bd_intf_pins -quiet $lr_obj]] == 0 && [llength [get_bd_pins -quiet $lr_obj]] == 0} {
        error "Missing u_cmac_init pin/interface: $lr_obj"
    }
}
if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins u_cmac_init/M_AXI]]] != 1} {
    error "u_cmac_init/M_AXI is not connected"
}

# Confirm the saved boundary nets explicitly. A raw get_bd_nets query on a
# vector external port is inconsistent in Vivado 2021.1, so do not use the
# former per-port query that falsely reported four connected ports as open.
foreach lr_net {
    uart_rx_1 qsfp_refclk_p_1 qsfp_refclk_n_1
    rx_clk_in_p_1 rx_clk_in_n_1 rx_frame_in_p_1 rx_frame_in_n_1
    rx_data_in_p_1 rx_data_in_n_1 spi_miso_1 key_in_1
} {
    if {[llength [get_bd_nets -quiet $lr_net]] != 1} {
        error "Missing external-input BD net: $lr_net"
    }
}
if {[llength [get_bd_intf_nets -quiet c0_sys_clk_1]] != 1} {
    error "Missing external clock interface net: c0_sys_clk_1"
}

# Explicit regressions for the three user-reported BD faults.
if {[get_property CONFIG.NUM_KEYS [get_bd_cells u_btn]] != 4} {
    error "u_btn NUM_KEYS is not 4"
}
if {[get_property CONFIG.WIDTH [get_bd_cells u_btn_pulse_cdc]] != 4} {
    error "u_btn_pulse_cdc WIDTH is not 4"
}
foreach lr_pin {xc_st_cmac/In13 xc_t_inc/In8 u_btn/key_in} {
    if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $lr_pin]]] != 1} {
        error "Required BD pin is not connected: $lr_pin"
    }
}

validate_bd_design
save_bd_design
generate_target all $lr_bd
export_ip_user_files -of_objects $lr_bd -no_script -sync -force -quiet
update_compile_order -fileset sources_1

# Missing source/product references must be zero before hand-off to synthesis.
set lr_missing [get_files -quiet -all -filter {IS_MISSING == 1}]
if {[llength $lr_missing] != 0} {
    puts "ERROR: missing project files: $lr_missing"
    error "Project still contains [llength $lr_missing] missing file references"
}

if {[string toupper [get_property CONFIG.MAC_DST $lr_pkt]] ne "0XFFFFFFFFFFFF" ||
    [string toupper [get_property CONFIG.IP_DST $lr_pkt]] ne "0XFFFFFFFF"} {
    error "u_pkt bring-up destination parameters were not persisted"
}

puts "LR_PRESYNTH_READY"
puts "Synthesis and implementation were NOT launched or reset."
