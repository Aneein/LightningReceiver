# ============================================================================
# Lightning Receiver - S2 DDR4 + QSFP28 constraints (source-able)
# File: lr_constraints_s2.tcl
# ----------------------------------------------------------------------------
# DDR4 pins (from KU5P_DEMO 06_DDR_AXI Phy_Pin.xdc, proven on this board)
# + QSFP28 156.25 MHz GT reference clock (from stage3_100g_board_io.xdc).
# Usage:  source <path>/lr_constraints_s2.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

set proj_dir [get_property DIRECTORY [current_project]]
set xdc_file "$proj_dir/lr_ddr4_qsfp.xdc"

set old [get_files -quiet -of_objects [get_filesets constrs_1] lr_ddr4_qsfp.xdc]
if {[llength $old] > 0} {
    remove_files -fileset constrs_1 $old
}

set fp [open $xdc_file w]
puts $fp "# LR DDR4 + QSFP28 constraints (RK-XCKU5P-F V1.2)"
puts $fp "# DDR4 pins per KU5P_DEMO 06_DDR_AXI (2x MT40A512M16, 32-bit, DDR4-2666)"
puts $fp ""
puts $fp "# --- DDR4 command/address ---"
puts $fp "set_property PACKAGE_PIN P24 \[get_ports c0_ddr4_act_n\]"
puts $fp "set_property PACKAGE_PIN Y22 \[get_ports {c0_ddr4_adr\[0\]}\]"
puts $fp "set_property PACKAGE_PIN Y25 \[get_ports {c0_ddr4_adr\[1\]}\]"
puts $fp "set_property PACKAGE_PIN W23 \[get_ports {c0_ddr4_adr\[2\]}\]"
puts $fp "set_property PACKAGE_PIN V26 \[get_ports {c0_ddr4_adr\[3\]}\]"
puts $fp "set_property PACKAGE_PIN R26 \[get_ports {c0_ddr4_adr\[4\]}\]"
puts $fp "set_property PACKAGE_PIN U26 \[get_ports {c0_ddr4_adr\[5\]}\]"
puts $fp "set_property PACKAGE_PIN R21 \[get_ports {c0_ddr4_adr\[6\]}\]"
puts $fp "set_property PACKAGE_PIN W25 \[get_ports {c0_ddr4_adr\[7\]}\]"
puts $fp "set_property PACKAGE_PIN R20 \[get_ports {c0_ddr4_adr\[8\]}\]"
puts $fp "set_property PACKAGE_PIN Y26 \[get_ports {c0_ddr4_adr\[9\]}\]"
puts $fp "set_property PACKAGE_PIN R25 \[get_ports {c0_ddr4_adr\[10\]}\]"
puts $fp "set_property PACKAGE_PIN V23 \[get_ports {c0_ddr4_adr\[11\]}\]"
puts $fp "set_property PACKAGE_PIN AA24 \[get_ports {c0_ddr4_adr\[12\]}\]"
puts $fp "set_property PACKAGE_PIN W26 \[get_ports {c0_ddr4_adr\[13\]}\]"
puts $fp "set_property PACKAGE_PIN P23 \[get_ports {c0_ddr4_adr\[14\]}\]"
puts $fp "set_property PACKAGE_PIN AA25 \[get_ports {c0_ddr4_adr\[15\]}\]"
puts $fp "set_property PACKAGE_PIN T25 \[get_ports {c0_ddr4_adr\[16\]}\]"
puts $fp "set_property PACKAGE_PIN P21 \[get_ports {c0_ddr4_ba\[0\]}\]"
puts $fp "set_property PACKAGE_PIN P26 \[get_ports {c0_ddr4_ba\[1\]}\]"
puts $fp "set_property PACKAGE_PIN R22 \[get_ports c0_ddr4_bg\]"
puts $fp "set_property PACKAGE_PIN P20 \[get_ports c0_ddr4_cke\]"
puts $fp "set_property PACKAGE_PIN R23 \[get_ports c0_ddr4_odt\]"
puts $fp "set_property PACKAGE_PIN P25 \[get_ports c0_ddr4_cs_n\]"
puts $fp "set_property PACKAGE_PIN V24 \[get_ports c0_ddr4_ck_t\]"
puts $fp "set_property PACKAGE_PIN P19 \[get_ports c0_ddr4_reset_n\]"
puts $fp ""
puts $fp "# --- DDR4 data ---"
puts $fp "set_property PACKAGE_PIN AE25 \[get_ports {c0_ddr4_dm_n\[0\]}\]"
puts $fp "set_property PACKAGE_PIN AE22 \[get_ports {c0_ddr4_dm_n\[1\]}\]"
puts $fp "set_property PACKAGE_PIN AD20 \[get_ports {c0_ddr4_dm_n\[2\]}\]"
puts $fp "set_property PACKAGE_PIN Y20 \[get_ports {c0_ddr4_dm_n\[3\]}\]"
puts $fp "set_property PACKAGE_PIN AF24 \[get_ports {c0_ddr4_dq\[0\]}\]"
puts $fp "set_property PACKAGE_PIN AF25 \[get_ports {c0_ddr4_dq\[1\]}\]"
puts $fp "set_property PACKAGE_PIN AD24 \[get_ports {c0_ddr4_dq\[2\]}\]"
puts $fp "set_property PACKAGE_PIN AB26 \[get_ports {c0_ddr4_dq\[3\]}\]"
puts $fp "set_property PACKAGE_PIN AC24 \[get_ports {c0_ddr4_dq\[4\]}\]"
puts $fp "set_property PACKAGE_PIN AB25 \[get_ports {c0_ddr4_dq\[5\]}\]"
puts $fp "set_property PACKAGE_PIN AD25 \[get_ports {c0_ddr4_dq\[6\]}\]"
puts $fp "set_property PACKAGE_PIN AB24 \[get_ports {c0_ddr4_dq\[7\]}\]"
puts $fp "set_property PACKAGE_PIN AC21 \[get_ports {c0_ddr4_dq\[8\]}\]"
puts $fp "set_property PACKAGE_PIN AD23 \[get_ports {c0_ddr4_dq\[9\]}\]"
puts $fp "set_property PACKAGE_PIN AD21 \[get_ports {c0_ddr4_dq\[10\]}\]"
puts $fp "set_property PACKAGE_PIN AC22 \[get_ports {c0_ddr4_dq\[11\]}\]"
puts $fp "set_property PACKAGE_PIN AB21 \[get_ports {c0_ddr4_dq\[12\]}\]"
puts $fp "set_property PACKAGE_PIN AE23 \[get_ports {c0_ddr4_dq\[13\]}\]"
puts $fp "set_property PACKAGE_PIN AE21 \[get_ports {c0_ddr4_dq\[14\]}\]"
puts $fp "set_property PACKAGE_PIN AC23 \[get_ports {c0_ddr4_dq\[15\]}\]"
puts $fp "set_property PACKAGE_PIN AE16 \[get_ports {c0_ddr4_dq\[16\]}\]"
puts $fp "set_property PACKAGE_PIN AD19 \[get_ports {c0_ddr4_dq\[17\]}\]"
puts $fp "set_property PACKAGE_PIN AD16 \[get_ports {c0_ddr4_dq\[18\]}\]"
puts $fp "set_property PACKAGE_PIN AF17 \[get_ports {c0_ddr4_dq\[19\]}\]"
puts $fp "set_property PACKAGE_PIN AC19 \[get_ports {c0_ddr4_dq\[20\]}\]"
puts $fp "set_property PACKAGE_PIN AF19 \[get_ports {c0_ddr4_dq\[21\]}\]"
puts $fp "set_property PACKAGE_PIN AF18 \[get_ports {c0_ddr4_dq\[22\]}\]"
puts $fp "set_property PACKAGE_PIN AE17 \[get_ports {c0_ddr4_dq\[23\]}\]"
puts $fp "set_property PACKAGE_PIN AA20 \[get_ports {c0_ddr4_dq\[24\]}\]"
puts $fp "set_property PACKAGE_PIN AA18 \[get_ports {c0_ddr4_dq\[25\]}\]"
puts $fp "set_property PACKAGE_PIN AA19 \[get_ports {c0_ddr4_dq\[26\]}\]"
puts $fp "set_property PACKAGE_PIN Y18 \[get_ports {c0_ddr4_dq\[27\]}\]"
puts $fp "set_property PACKAGE_PIN AB20 \[get_ports {c0_ddr4_dq\[28\]}\]"
puts $fp "set_property PACKAGE_PIN Y17 \[get_ports {c0_ddr4_dq\[29\]}\]"
puts $fp "set_property PACKAGE_PIN AB19 \[get_ports {c0_ddr4_dq\[30\]}\]"
puts $fp "set_property PACKAGE_PIN AA17 \[get_ports {c0_ddr4_dq\[31\]}\]"
puts $fp "set_property PACKAGE_PIN AC26 \[get_ports {c0_ddr4_dqs_t\[0\]}\]"
puts $fp "set_property PACKAGE_PIN AA22 \[get_ports {c0_ddr4_dqs_t\[1\]}\]"
puts $fp "set_property PACKAGE_PIN AC18 \[get_ports {c0_ddr4_dqs_t\[2\]}\]"
puts $fp "set_property PACKAGE_PIN AB17 \[get_ports {c0_ddr4_dqs_t\[3\]}\]"
puts $fp ""
puts $fp "# --- MIG system clock: pins/clock in lr_board_bringup.xdc (T24/U24) ---"
puts $fp ""
puts $fp "# --- QSFP28 156.25 MHz GT reference clock (V7/V6, BANK225) ---"
puts $fp "set_property PACKAGE_PIN V7 \[get_ports qsfp_refclk_p\]"
puts $fp "set_property PACKAGE_PIN V6 \[get_ports qsfp_refclk_n\]"
puts $fp "# CMAC generated constraints create the qsfp_refclk_p input clock."
close $fp

add_files -fileset constrs_1 $xdc_file
puts "=== S2 DDR4 + QSFP28 constraints added: $xdc_file ==="
