# ============================================================================
# Lightning Receiver - pre-synthesis BD sanity check (GUI or batch)
# Usage (project open, BD open):  source tools/fpga/check_bd_current.tcl
# ----------------------------------------------------------------------------
# Catches a BD that was not rebuilt with the current lr_bd_s2.tcl, e.g. after
# "Refresh Changed Modules": new module ports then exist but are unconnected
# and get tied to 0 (2026-10-05: iq_mode ports of the 0005 build).
# Errors out (stop, do not synthesise) on any unconnected scalar input pin of
# a top-level BD cell, or on a missing key connection.
# ============================================================================
open_bd_design [get_files system.bd]

set bad 0
foreach c [lsort [get_bd_cells -quiet -filter {TYPE != hier}]] {
    foreach p [lsort [get_bd_pins -quiet -of_objects $c -filter {DIR == I}]] {
        if {[string equal -nocase [get_property INTF $p] "true"]} continue
        if {[llength [get_bd_nets -quiet -of_objects $p]] == 0} {
            puts "LR_CHECK ERROR: unconnected input $p"
            incr bad
        }
    }
}

# key connections of the current design (extend when adding features)
foreach p {
    u_fm/iq_bypass u_audio/iq_mode u_pack/iq_mode u_pack/rec_iq
    u_audio/deemph_75us u_jbridge/M_AXI_aclk
} {
    set pin [get_bd_pins -quiet $p]
    if {$pin eq "" || [llength [get_bd_nets -quiet -of_objects $pin]] == 0} {
        puts "LR_CHECK ERROR: missing connection $p"
        incr bad
    }
}
if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins -quiet u_jbridge/M_AXI]]] == 0} {
    puts "LR_CHECK ERROR: u_jbridge/M_AXI not connected"
    incr bad
}

if {$bad} {
    error "BD is not current ($bad problem(s)): source tools/fpga/lr_bd_s2.tcl and lr_wrapper.tcl, then synthesise"
}
puts "LR_CHECK_BD_OK"
