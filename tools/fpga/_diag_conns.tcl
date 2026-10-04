# Diagnostic: rerun BD generation on scratch, capture all skipped connects
open_project D:/workspace/.lr_scratch3/LightningReceiver.xpr
set lr "D:/workspace/LightningReceiver/tools/fpga"
source $lr/lr_sources.tcl
source $lr/lr_bd_s2.tcl
puts "=== VALIDATE ==="
validate_bd_design
save_bd_design
puts "=== DIAG DONE ==="
