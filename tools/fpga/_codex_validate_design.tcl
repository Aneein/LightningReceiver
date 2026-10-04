# Source-level and block-design validation only.
# Deliberately does not launch synthesis or implementation.

set lr_root "D:/workspace/LightningReceiver"
set xpr "$lr_root/fpga/LightningReceiver/LightningReceiver.xpr"

open_project $xpr
# Drop project entries whose source file no longer exists on disk (renamed or
# deleted RTL); lr_sources.tcl only ever adds files.
foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
    # Only custom RTL; BD/IP outputs may legitimately not be generated yet.
    if {[string first [string tolower "$lr_root/rtl/"] [string tolower [file normalize $f]]] != 0} {
        continue
    }
    if {![file exists $f]} {
        puts "INFO: removing stale project source $f"
        remove_files -fileset sources_1 $f
    }
}
source "$lr_root/tools/fpga/lr_sources.tcl"
source "$lr_root/tools/fpga/lr_bd_s2.tcl"
source "$lr_root/tools/fpga/lr_constraints.tcl"
source "$lr_root/tools/fpga/lr_constraints_s1.tcl"
source "$lr_root/tools/fpga/lr_constraints_s2.tcl"

validate_bd_design
save_bd_design

# Inventory every genuinely unconnected BD pin/interface.  Vivado's canvas can
# show inferred interface groups that are not real wires, so keep a textual
# connectivity report that can be reviewed deterministically.
set report_dir "$lr_root/reports/source_validation"
file mkdir $report_dir
set uf [open "$report_dir/unconnected_bd_pins.rpt" w]
set unconnected_inputs 0
set unconnected_outputs 0
# Only report pins on top-level BD cells.  Pins inside hierarchical IP and
# scalar members of a connected interface are implementation details, not
# dangling design connections.
foreach c [lsort [get_bd_cells -quiet -filter {TYPE != hier}]] {
    foreach p [lsort [get_bd_pins -quiet -of_objects $c]] {
        if {[string equal -nocase [get_property INTF $p] "true"]} {
            continue
        }
        if {[llength [get_bd_nets -quiet -of_objects $p]] == 0} {
            puts $uf "PIN [get_property DIR $p] $p"
            if {[get_property DIR $p] eq "I"} {
                incr unconnected_inputs
            } else {
                incr unconnected_outputs
            }
        }
    }
}
foreach p [lsort [get_bd_intf_pins -quiet]] {
    if {[llength [get_bd_intf_nets -quiet -of_objects $p]] == 0} {
        puts $uf "INTF [get_property MODE $p] $p"
    }
}
close $uf
set sf [open "$report_dir/unconnected_bd_summary.rpt" w]
puts $sf "UNCONNECTED_SCALAR_INPUTS=$unconnected_inputs"
puts $sf "UNCONNECTED_SCALAR_OUTPUTS=$unconnected_outputs"
close $sf
if {$unconnected_inputs != 0} {
    error "BD has $unconnected_inputs unconnected scalar input pin(s); see unconnected_bd_pins.rpt"
}

source "$lr_root/tools/fpga/lr_wrapper.tcl"
update_compile_order -fileset sources_1

report_compile_order -used_in synthesis -file "$report_dir/compile_order.rpt"
report_ip_status -file "$report_dir/ip_status.rpt"

puts "CODEX_SOURCE_VALIDATION_PASS"
close_project
exit 0
