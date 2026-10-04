open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== exceptions applied (false_path count) ==="
set fps [get_timing_exceptions -quiet -filter {TYPE == false_path}]
puts "false_path count: [llength $fps]"
puts "=== worst CDC path: mmcm_clkout0 -> clk_out1 ==="
report_timing -from [get_clocks mmcm_clkout0] -to [get_clocks clk_out1_system_clk_fabric_0] \
              -max_paths 3 -nworst 3 -path_type end
puts "=== check if that path endpoint has false_path ==="
report_timing -from [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_axi_reg*}] \
              -to   [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_gray_s1*}] \
              -max_paths 2 -nworst 2 -path_type summary
puts "DONE"
