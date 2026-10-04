# ============================================================================
# Lightning Receiver - implementation with retry on the intermittent MIG PHY
# debug-core failure (opt_design "Phase 1 Generate And Synthesize MIG Cores").
#
# On this host the PHY sub-synthesis (a separate Vivado process) randomly
# fails to open a file it needs ("couldn't read file .../unimacro_vhdl.tcl:
# No error", ".../retarget_vhdl.tcl", or "Cannot open file ...phy.xdc") ->
# IP_Flow 19-3805 / Mig 66-119 / Opt 31-306.  The design is not involved and
# a re-run usually passes.  Only that signature is retried; any other
# implementation error stops immediately.
#
# Usage (GUI Tcl console, project open, synth_1 complete):
#   source D:/workspace/LightningReceiver/tools/fpga/impl_retry.tcl
#   lr_impl_with_retry          ;# default: up to 5 attempts, 4 jobs
#   lr_impl_with_retry 8 8      ;# 8 attempts, 8 jobs
# ============================================================================

proc lr_impl_with_retry {{max_attempts 5} {jobs 4}} {
    set run [get_runs impl_1]
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        error "synth_1 is not complete - run synthesis first"
    }
    for {set attempt 1} {$attempt <= $max_attempts} {incr attempt} {
        puts "=== LR impl attempt $attempt / $max_attempts ==="
        reset_run $run
        launch_runs $run -to_step write_bitstream -jobs $jobs
        wait_on_run $run
        if {[get_property PROGRESS $run] eq "100%" &&
            ![string match "*ERROR*" [get_property STATUS $run]]} {
            puts "=== LR impl OK on attempt $attempt (bitstream written) ==="
            return
        }
        set log [file join [get_property DIRECTORY $run] runme.log]
        set txt ""
        if {[file exists $log]} {
            set fh [open $log r]; set txt [read $fh]; close $fh
        }
        if {[string first "Mig 66-119" $txt] >= 0 ||
            [string first "IP_Flow 19-3805" $txt] >= 0} {
            puts "=== LR attempt $attempt hit the transient MIG PHY failure - retrying ==="
            continue
        }
        error "impl_1 failed for another reason - see $log (not retried)"
    }
    error "impl_1: MIG PHY generation failed $max_attempts times in a row"
}

puts "LR: lr_impl_with_retry ?max_attempts? ?jobs? is available"
