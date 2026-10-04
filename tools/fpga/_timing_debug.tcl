# Timing debug: open routed design, report worst paths by clock domain
open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== CLOCK DOMAIN SUMMARY (failing paths per domain) ==="
report_timing_summary -max_paths 100 -delay_type min_max -report_unconstrained -check_timing_verbose -quiet -file D:/workspace/LightningReceiver/fpga/LightningReceiver/timing_debug.rpt
puts "=== WORST 3 PATHS ==="
report_timing -max_paths 3 -nworst 3 -path_type full -input_pins -sort_by slack
puts "=== DONE ==="
