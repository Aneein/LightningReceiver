# Incremental re-validation: reopen scratch project, run impl only
# (synth_1 already passed; re-verifies impl + bitstream after transient unimacro failure)
open_project D:/workspace/.lr_scratch3/LightningReceiver.xpr
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "=== IMPL-ONLY RE-RUN FAILED ==="
    exit 1
}
puts "=== IMPL-ONLY RE-RUN: IMPL + BITSTREAM OK ==="
