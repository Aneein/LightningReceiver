# Full impl validation on scratch4 (with all timing fixes)
open_project D:/workspace/.lr_scratch4/LightningReceiver.xpr
set lr "D:/workspace/LightningReceiver/tools/fpga"
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "=== IMPL FAILED ==="
    exit 1
}
open_run impl_1
report_timing_summary -max_paths 10 -file D:/workspace/.lr_scratch4/final_timing.rpt
report_utilization -file D:/workspace/.lr_scratch4/final_util.rpt
close_design
puts "=== IMPL + BITSTREAM OK ==="
