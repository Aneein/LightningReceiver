open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== u_tele cnt_reg[9] CE path ==="
report_timing -to [get_cells -hier -filter {NAME =~ *u_tele/inst/cnt_reg\[9\]*}] -max_paths 2 -nworst 2 -path_type full -input_pins
puts "=== u_btn violated path ==="
report_timing -to [get_cells -hier -filter {NAME =~ *u_btn*}] -max_paths 2 -nworst 2 -path_type full -input_pins
puts "DONE"
