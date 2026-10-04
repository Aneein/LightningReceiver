open_project D:/workspace/.lr_val5/LRVal5.xpr
open_run impl_1
puts "=== actual sync reg names in u_cmac_rx_level_sync ==="
puts [get_cells -hier -quiet -filter {NAME =~ *u_cmac_rx_level_sync*}]
puts "=== the failing path from report: RX_CLK -> sync1_reg[2] ==="
report_timing -from [get_pins -hier -quiet -filter {NAME =~ *u_cmac_rx_level_sync/inst/sync1_reg*}] -max_paths 1 -nworst 1 -path_type full
puts "=== check false_path objects: any exceptions on sync1? ==="
report_exceptions -ignored -file D:/workspace/.lr_cmacfp_exc.rpt
puts "DONE"
