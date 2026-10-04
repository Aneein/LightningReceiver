open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== u_tele cnt_reg path ==="
report_timing -to [get_pins -hier -filter {NAME =~ *cnt_reg*} ] -max_paths 2 -nworst 2 -path_type full
puts "=== u_btn path ==="
report_timing -to [get_pins -hier -filter {NAME =~ *u_btn*} ] -max_paths 2 -nworst 2 -path_type full
puts "DONE"
