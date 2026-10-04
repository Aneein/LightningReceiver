# Repair the currently open LightningReceiver project in one Vivado process.
# This deliberately rebuilds the BD, removing stale module/XCI proxy records.
set lr_root D:/workspace/LightningReceiver
set lr_tools $lr_root/tools/fpga
set lr_rtl $lr_root/rtl/network/cmac_axil_init.v

if {[current_project -quiet] eq ""} {
    error "Open LightningReceiver.xpr before sourcing this script."
}

set_property source_mgmt_mode All [current_project]
if {[llength [get_files -quiet $lr_rtl]] == 0} {
    add_files -norecurse -fileset sources_1 $lr_rtl
}
update_compile_order -fileset sources_1

source $lr_tools/lr_bd_s2.tcl
source $lr_tools/lr_constraints.tcl
source $lr_tools/lr_constraints_s1.tcl
source $lr_tools/lr_constraints_s2.tcl
source $lr_tools/lr_timing_convergence.tcl
source $lr_tools/lr_wrapper.tcl
update_compile_order -fileset sources_1

set lr_bd [get_files -quiet */system.bd]
if {[llength $lr_bd] != 1} {
    error "Expected exactly one system.bd, found [llength $lr_bd]"
}
open_bd_design $lr_bd
validate_bd_design
save_bd_design

generate_target all $lr_bd
export_ip_user_files -of_objects $lr_bd -no_script -sync -force -quiet
puts "LR_GUI_REPAIR_PASS"
