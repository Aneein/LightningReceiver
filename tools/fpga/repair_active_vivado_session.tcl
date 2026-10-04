# Repair a stale, already-open Vivado GUI session without launching synthesis
# or implementation.  This is needed when an older GUI session saves its
# in-memory system.bd after the source tree/BD was regenerated elsewhere.

set lr_root "D:/workspace/LightningReceiver"
set expected_xpr "$lr_root/fpga/LightningReceiver/LightningReceiver.xpr"

if {[current_project -quiet] eq ""} {
    error "No Vivado project is open; open $expected_xpr first"
}

set active_xpr [file normalize [file join \
    [get_property DIRECTORY [current_project]] \
    "[get_property NAME [current_project]].xpr"]]
if {![string equal -nocase $active_xpr [file normalize $expected_xpr]]} {
    error "Refusing to repair unexpected project: $active_xpr"
}

puts "LR_REPAIR: refreshing RTL and replacing stale system.bd"
source "$lr_root/tools/fpga/lr_sources.tcl"
source "$lr_root/tools/fpga/lr_bd_s2.tcl"
source "$lr_root/tools/fpga/lr_constraints.tcl"
source "$lr_root/tools/fpga/lr_constraints_s1.tcl"
source "$lr_root/tools/fpga/lr_constraints_s2.tcl"

validate_bd_design
save_bd_design
source "$lr_root/tools/fpga/lr_wrapper.tcl"
update_compile_order -fileset sources_1

set new_cells [get_bd_cells -quiet {u_uart u_cmd u_cic u_net_mux u_mode}]
set stale_cells [get_bd_cells -quiet {uartlite_0 fir_0 cic_0}]
if {[llength $new_cells] != 5 || [llength $stale_cells] != 0} {
    error "LR_REPAIR verification failed: new=$new_cells stale=$stale_cells"
}

puts "LR_ACTIVE_SESSION_REPAIR_PASS"
