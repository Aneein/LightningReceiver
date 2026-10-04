# ============================================================================
# Lightning Receiver - Build (synthesis / implementation / bitstream)
# File: lr_build.tcl
# ----------------------------------------------------------------------------
# Uses the standard Vivado run infrastructure (launch_runs / wait_on_run),
# which automatically synthesizes BD IP (OOC) then the top design.
#   RUN_IMPL : set to 1 to run implementation + bitstream (default 1)
# Usage:  source <path>/lr_build.tcl   (inside Vivado, project open)
#         or:  set RUN_IMPL 0; source <path>/lr_build.tcl   (synth only)
# Re-run: reset_run synth_1; reset_run impl_1   (if previously completed)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

if {![info exists RUN_IMPL]} { set RUN_IMPL 1 }

set proj_dir  [get_property DIRECTORY [current_project]]
set proj_name [get_property NAME [current_project]]

# ---------------------------------------------------------------------------
# Synthesis (launch_runs handles BD IP OOC synthesis automatically)
# ---------------------------------------------------------------------------
puts "=== Launching synth_1 ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis failed - check the synth_1 run log"
}

open_run synth_1
report_utilization -file [file join $proj_dir rpt_synth_util.rpt]
report_timing_summary -file [file join $proj_dir rpt_synth_timing.rpt]
close_design
puts "=== SYNTHESIS DONE ==="

if {$RUN_IMPL} {
    # -----------------------------------------------------------------------
    # Implementation + bitstream
    # -----------------------------------------------------------------------
    puts "=== Launching impl_1 (to write_bitstream) ==="
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "Implementation failed - check the impl_1 run log"
    }
    open_run impl_1
    report_timing_summary -file [file join $proj_dir rpt_impl_timing.rpt]
    report_utilization  -file [file join $proj_dir rpt_impl_util.rpt]
    close_design
    set bit_file [file join $proj_dir ${proj_name}.runs impl_1 ${proj_name}.bit]
    puts "=== IMPLEMENTATION + BITSTREAM DONE: $bit_file ==="
} else {
    puts "=== SYNTH ONLY (RUN_IMPL=0) ==="
}
