# ============================================================================
# Lightning Receiver - S1 FMC AD9361 constraints (source-able)
# File: lr_constraints_s1.tcl
# ----------------------------------------------------------------------------
# Adds the FMC_AD936X LVDS/control pin constraints (RK-XCKU5P-F FMC,
# VADJ1=1.8V) as a separate XDC.  Mapping is frozen from the card J1
# schematic and carrier FMC pin definition.
# Usage:  source <path>/lr_constraints_s1.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

set proj_dir [get_property DIRECTORY [current_project]]
set xdc_file "$proj_dir/lr_fmc_ad9361.xdc"

set old [get_files -quiet -of_objects [get_filesets constrs_1] lr_fmc_ad9361.xdc]
if {[llength $old] > 0} {
    remove_files -fileset constrs_1 $old
}

set fp [open $xdc_file w]
puts $fp "# LR FMC_AD9361 pins (RK-XCKU5P-F V1.2, VADJ1=1.8V)"
puts $fp "# Frozen from FMC_AD936X.pdf J1 and the carrier FMC pin definition."
puts $fp "# RESETB is on J1-D31 (FMC TDO), is not routed as carrier FPGA GPIO, and has"
puts $fp "# a 10 kohm pull-up to VDD_INTERFACE on the card.  Do not drive an LA pin for it."
puts $fp ""
puts $fp "# --- RX LVDS (6-bit DDR) ---"
puts $fp "set_property -dict {PACKAGE_PIN G24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports rx_clk_in_p\]"
puts $fp "set_property -dict {PACKAGE_PIN G25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports rx_clk_in_n\]"
puts $fp "set_property -dict {PACKAGE_PIN J23 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports rx_frame_in_p\]"
puts $fp "set_property -dict {PACKAGE_PIN J24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports rx_frame_in_n\]"
puts $fp "set_property -dict {PACKAGE_PIN H21 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_p\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_n\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_p\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_n\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN H26 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_p\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G26 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_n\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_p\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_n\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_p\[4\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_n\[4\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN D24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_p\[5\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} \[get_ports {rx_data_in_n\[5\]}\]"
puts $fp ""
puts $fp "create_clock -period 4.000 -name rx_clk \[get_ports rx_clk_in_p\]"
puts $fp "set_clock_groups -asynchronous \\"
puts $fp "    -group \[get_clocks -include_generated_clocks rx_clk\] \\"
puts $fp "    -group \[get_clocks -include_generated_clocks c0_sys_clk_clk_p\] \\"
puts $fp "    -group \[get_clocks -include_generated_clocks qsfp_refclk\]"
puts $fp ""
puts $fp "# --- control (LVCMOS18, VADJ1) ---"
puts $fp "set_property -dict {PACKAGE_PIN E21 IOSTANDARD LVCMOS18} \[get_ports enable\]"
puts $fp "set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS18} \[get_ports txnrx\]"
puts $fp "set_property -dict {PACKAGE_PIN A19 IOSTANDARD LVCMOS18 PULLUP TRUE} \[get_ports spi_csn\]"
puts $fp "set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS18} \[get_ports spi_sclk\]"
puts $fp "set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS18} \[get_ports spi_mosi\]"
puts $fp "set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS18} \[get_ports spi_miso\]"
close $fp

add_files -fileset constrs_1 $xdc_file
# This file refers to the MIG-created input clock, so read it after generated
# IP constraints.  Without LATE processing the clock-group command can be
# evaluated before c0_sys_clk_clk_p exists.
set_property PROCESSING_ORDER LATE [get_files $xdc_file]
puts "=== S1 FMC AD9361 constraints added: $xdc_file (schematic-frozen mapping) ==="
