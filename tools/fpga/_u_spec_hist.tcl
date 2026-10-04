open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== u_spec cell paths ==="
puts [get_cells -hier -filter {NAME =~ *u_spec*}]
puts "=== worst 5 u_spec paths ==="
report_timing -from [get_cells -hier -filter {NAME =~ *u_spec*}] -to [get_cells -hier -filter {NAME =~ *u_spec*}] -max_paths 5 -nworst 5 -path_type end -sort_by slack
puts "DONE"
