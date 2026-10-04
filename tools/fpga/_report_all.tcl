open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
report_timing -max_paths 20000 -nworst 1 -path_type end -sort_by slack -file D:/workspace/LightningReceiver/fpga/LightningReceiver/all_violated.rpt
puts "DONE"
