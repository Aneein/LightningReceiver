# Validation: current user BD script + precise XDC, full synth + impl on scratch
create_project LRVal5 D:/workspace/.lr_val5 -part xcku5p-ffvb676-2-i -force
set_property target_language Verilog [current_project]
set lr "D:/workspace/LightningReceiver/tools/fpga"
source $lr/lr_sources.tcl
source $lr/lr_bd_s2.tcl
source $lr/lr_constraints.tcl
source $lr/lr_constraints_s1.tcl
source $lr/lr_constraints_s2.tcl
source $lr/lr_timing_convergence.tcl
source $lr/lr_wrapper.tcl
set RUN_IMPL 1
source $lr/lr_build.tcl
puts "=== LR VALIDATION 5 COMPLETE (synth + impl + bitstream) ==="
