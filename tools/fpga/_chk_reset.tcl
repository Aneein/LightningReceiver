# Quick validation: rebuild BD with reset fix, validate only (no synth)
create_project LRResetChk D:/workspace/.lr_resetchk -part xcku5p-ffvb676-2-i -force
set_property target_language Verilog [current_project]
set lr "D:/workspace/LightningReceiver/tools/fpga"
source $lr/lr_sources.tcl
source $lr/lr_bd_s2.tcl
puts "=== BD GENERATED ==="
# verify the reset net
set net [get_bd_nets -quiet *ui_clk_sync_rst*]
puts "ui_clk_sync_rst net ports:"
puts [get_bd_pins -quiet -of_objects $net]
set net2 [get_bd_nets -quiet *util_inv_mig_rst*]
puts "util_inv_mig_rst net ports:"
puts [get_bd_pins -quiet -of_objects $net2]
puts "=== BD VALIDATE ==="
validate_bd_design
save_bd_design
puts "=== VALIDATION OK ==="
