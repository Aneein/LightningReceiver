# Read-only timing inspection of an already existing synthesis checkpoint.
# This script never opens a project and never launches or resets a run.
set lr_dcp D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.runs/synth_1/system_wrapper.dcp
if {![file exists $lr_dcp]} {
    error "Existing synthesis checkpoint not found: $lr_dcp"
}
open_checkpoint $lr_dcp
puts "LR_EXISTING_DCP_CLOCKS_BEGIN"
foreach lr_clk [lsort [get_clocks -quiet]] {
    puts [format "%s period=%s source=%s" \
        $lr_clk \
        [get_property PERIOD $lr_clk] \
        [get_property SOURCE_PINS $lr_clk]]
}
puts "LR_EXISTING_DCP_CLOCKS_END"
puts "LR_EXISTING_DCP_CHECK_TIMING_BEGIN"
check_timing -verbose
puts "LR_EXISTING_DCP_CHECK_TIMING_END"
close_design
exit
