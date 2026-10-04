# Enumerate every block-design pin/interface/port that has no explicit net.
# Read-only audit: this script never launches synthesis or implementation.
if {[current_project -quiet] eq ""} {
    error "Open LightningReceiver.xpr before sourcing this script."
}
set lr_bd [get_files -quiet */system.bd]
if {[llength $lr_bd] != 1} {
    error "Expected exactly one system.bd, found [llength $lr_bd]"
}
open_bd_design $lr_bd

proc lr_open_bd_pins {dir} {
    set result {}
    foreach obj [get_bd_pins -quiet -hierarchical -filter "DIR == $dir"] {
        set connected [expr {[llength [get_bd_nets -quiet -of_objects $obj]] != 0}]
        foreach intf [get_bd_intf_pins -quiet -of_objects $obj] {
            if {[llength [get_bd_intf_nets -quiet -of_objects $intf]] != 0} {
                set connected 1
            }
        }
        if {!$connected} {
            lappend result $obj
        }
    }
    return [lsort -dictionary $result]
}

proc lr_open_bd_intf_pins {mode} {
    set result {}
    foreach obj [get_bd_intf_pins -quiet -hierarchical -filter "MODE == $mode"] {
        if {[llength [get_bd_intf_nets -quiet -of_objects $obj]] == 0} {
            lappend result $obj
        }
    }
    return [lsort -dictionary $result]
}

proc lr_open_bd_ports {dir} {
    set result {}
    foreach obj [get_bd_ports -quiet -filter "DIR == $dir"] {
        set connected [expr {[llength [get_bd_nets -quiet -of_objects $obj]] != 0}]
        foreach intf [get_bd_intf_ports -quiet -of_objects $obj] {
            if {[llength [get_bd_intf_nets -quiet -of_objects $intf]] != 0} {
                set connected 1
            }
        }
        if {!$connected} {
            lappend result $obj
        }
    }
    return [lsort -dictionary $result]
}

proc lr_open_bd_intf_ports {mode} {
    set result {}
    foreach obj [get_bd_intf_ports -quiet -filter "MODE == $mode"] {
        if {[llength [get_bd_intf_nets -quiet -of_objects $obj]] == 0} {
            lappend result $obj
        }
    }
    return [lsort -dictionary $result]
}

set lr_pin_inputs  [lr_open_bd_pins I]
set lr_pin_outputs [lr_open_bd_pins O]
set lr_intf_slaves [lr_open_bd_intf_pins Slave]
set lr_intf_masters [lr_open_bd_intf_pins Master]
set lr_port_inputs [lr_open_bd_ports I]
set lr_port_outputs [lr_open_bd_ports O]
set lr_intf_port_slaves [lr_open_bd_intf_ports Slave]
set lr_intf_port_masters [lr_open_bd_intf_ports Master]

set lr_lines [list \
    "LR_BD_OPEN_INPUT_PINS [llength $lr_pin_inputs]: $lr_pin_inputs" \
    "LR_BD_OPEN_OUTPUT_PINS [llength $lr_pin_outputs]: $lr_pin_outputs" \
    "LR_BD_OPEN_SLAVE_INTERFACES [llength $lr_intf_slaves]: $lr_intf_slaves" \
    "LR_BD_OPEN_MASTER_INTERFACES [llength $lr_intf_masters]: $lr_intf_masters" \
    "LR_BD_OPEN_INPUT_PORTS [llength $lr_port_inputs]: $lr_port_inputs" \
    "LR_BD_OPEN_OUTPUT_PORTS [llength $lr_port_outputs]: $lr_port_outputs" \
    "LR_BD_OPEN_SLAVE_INTERFACE_PORTS [llength $lr_intf_port_slaves]: $lr_intf_port_slaves" \
    "LR_BD_OPEN_MASTER_INTERFACE_PORTS [llength $lr_intf_port_masters]: $lr_intf_port_masters" \
    "Synthesis and implementation were NOT launched or reset."]

set lr_report_dir D:/workspace/LightningReceiver/reports/presynth
file mkdir $lr_report_dir
set lr_report [open $lr_report_dir/bd_connectivity_audit.txt w]
foreach lr_line $lr_lines {
    puts $lr_line
    puts $lr_report $lr_line
}
close $lr_report
puts "LR_BD_CONNECTIVITY_REPORT $lr_report_dir/bd_connectivity_audit.txt"
