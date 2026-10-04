open_project D:/workspace/.lr_val5/LRVal5.xpr
open_run impl_1
puts "=== u_ring CDC path slack (should be inf/N/A if false-pathed) ==="
report_timing -from [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_axi_reg*}] \
              -to   [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_gray_s1*}] \
              -max_paths 1 -nworst 1 -path_type summary
puts "=== rxoutclk->fabric failing endpoints (actual) ==="
report_timing -from [get_clocks rxoutclk_out[0]] -to [get_clocks clk_out1_system_clk_fabric_0] \
              -max_paths 3 -nworst 3 -path_type end
puts "=== full exception list (name filter) ==="
report_exceptions -file D:/workspace/.lr_exc_all.rpt
puts "DONE"
