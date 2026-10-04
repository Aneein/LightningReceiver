# Self-validation driver v2: full LR S2 flow INCLUDING implementation
# (verifies the clock cascade placement fix for Place 30-718)
create_project LightningReceiver D:/workspace/.lr_scratch3 -part xcku5p-ffvb676-2-i -force
set_property target_language Verilog [current_project]

set lr "D:/workspace/LightningReceiver/tools/fpga"

source $lr/lr_sources.tcl
source $lr/lr_bd_s2.tcl
source $lr/lr_constraints.tcl
source $lr/lr_constraints_s1.tcl
source $lr/lr_constraints_s2.tcl
source $lr/lr_wrapper.tcl
set RUN_IMPL 1
source $lr/lr_build.tcl

puts "=== SELF-VALIDATION v2 COMPLETE (incl. implementation) ==="
