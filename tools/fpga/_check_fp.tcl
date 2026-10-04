open_project D:/workspace/.lr_scratch4/LightningReceiver.xpr
open_run synth_1
puts "=== check false path coverage ==="
puts "u_sample_fifo cells found:"
puts [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}]
puts ""
puts "=== timing on that path (should be N/A if false-pathed) ==="
report_timing -from [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}] -max_paths 1 -nworst 1 -path_type summary
puts "=== constraint check ==="
report_exceptions -ignored -file D:/workspace/.lr_scratch4/exc.rpt
puts "DONE"
