# ============================================================================
# Lightning Receiver - Board constraints (source-able)
# File: lr_constraints.tcl
# ----------------------------------------------------------------------------
# Writes the RK-XCKU5P-F V1.2 bring-up XDC into the project directory and adds
# it to the constrs_1 fileset. Idempotent (old copy removed first).
# NOTE: all Vivado Tcl brackets inside the generated XDC are escaped \[ \]
#       so they are written literally, not evaluated here.
# Usage:  source <path>/lr_constraints.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

set proj_dir [get_property DIRECTORY [current_project]]
set xdc_file "$proj_dir/lr_board_bringup.xdc"

# remove previous copy from fileset if present
set old [get_files -quiet -of_objects [get_filesets constrs_1] lr_board_bringup.xdc]
if {[llength $old] > 0} {
    remove_files -fileset constrs_1 $old
    puts "INFO: removed previous lr_board_bringup.xdc from fileset"
}

set fp [open $xdc_file w]
puts $fp "# LR board bring-up constraints (RK-XCKU5P-F V1.2)"
puts $fp "# system clock: 200 MHz differential via MIG (T24/U24, DIFF_SSTL12)"
puts $fp "# (clock created by MIG generated XDC - pins only here)"
puts $fp "set_property PACKAGE_PIN T24 \[get_ports c0_sys_clk_clk_p\]"
puts $fp "set_property PACKAGE_PIN U24 \[get_ports c0_sys_clk_clk_n\]"
puts $fp "set_property IOSTANDARD DIFF_SSTL12 \[get_ports c0_sys_clk_clk_p\]"
puts $fp "set_property IOSTANDARD DIFF_SSTL12 \[get_ports c0_sys_clk_clk_n\]"
puts $fp "# UART: RX AD13 / TX AC14 (LVCMOS33)"
puts $fp "set_property PACKAGE_PIN AD13 \[get_ports uart_rx\]"
puts $fp "set_property PACKAGE_PIN AC14 \[get_ports uart_tx\]"
puts $fp "set_property IOSTANDARD LVCMOS33 \[get_ports uart_rx\]"
puts $fp "set_property IOSTANDARD LVCMOS33 \[get_ports uart_tx\]"
puts $fp "# KEY1..4 are active-low controls; system reset follows MIG/MMCM lock."
puts $fp "set_property -dict {PACKAGE_PIN K9  IOSTANDARD LVCMOS33 PULLUP TRUE} \[get_ports {key_in\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN K10 IOSTANDARD LVCMOS33 PULLUP TRUE} \[get_ports {key_in\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS33 PULLUP TRUE} \[get_ports {key_in\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS33 PULLUP TRUE} \[get_ports {key_in\[3\]}\]"
puts $fp "# LED1 clock lock, LED2 DDR calibration, LED3 CMAC init, LED4 link."
puts $fp "set_property -dict {PACKAGE_PIN H9  IOSTANDARD LVCMOS33} \[get_ports {led\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J9  IOSTANDARD LVCMOS33} \[get_ports {led\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G11 IOSTANDARD LVCMOS33} \[get_ports {led\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS33} \[get_ports {led\[3\]}\]"
puts $fp "# QSFP28 module controls (same proven F_SMART board mapping)."
puts $fp "set_property -dict {PACKAGE_PIN W12 IOSTANDARD LVCMOS33} \[get_ports qsfp_resetl\]"
puts $fp "set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} \[get_ports qsfp_lpmode\]"
puts $fp "set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} \[get_ports qsfp_modsell\]"
puts $fp "# bitstream"
puts $fp "set_property BITSTREAM.GENERAL.COMPRESS TRUE \[current_design\]"
puts $fp "set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 \[current_design\]"
puts $fp "# clock cascade placement (clk_fabric -> clk_wiz_iodelay MMCM)"
puts $fp "set_property CLOCK_DEDICATED_ROUTE BACKBONE \[get_nets system_i/clk_fabric/inst/clk_out1\]"
close $fp

add_files -fileset constrs_1 $xdc_file
puts "=== LR board constraints added: $xdc_file ==="
