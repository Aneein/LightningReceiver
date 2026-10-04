# Incremental validation: re-source convergence XDC + rerun synth on scratch4
open_project D:/workspace/.lr_scratch4/LightningReceiver.xpr
set lr "D:/workspace/LightningReceiver/tools/fpga"
source $lr/lr_timing_convergence.tcl
reset_run synth_1
set RUN_IMPL 0
source $lr/lr_build.tcl
puts "=== VALIDATION DONE ==="
