open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== u_ring CDC path check (wr_words_axi -> gray_s1) ==="
report_timing -from [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_axi_reg*}] \
              -to   [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_gray_s1*}] \
              -max_paths 3 -nworst 3 -path_type summary
puts "=== exceptions applied ==="
report_exceptions -ignored -file D:/workspace/.lr_fp_check.rpt
puts "=== count of false paths ==="
set fps [get_timing_exceptions -quiet -filter {TYPE == false_path}]
puts "false_path count: [llength $fps]"
puts "DONE"
