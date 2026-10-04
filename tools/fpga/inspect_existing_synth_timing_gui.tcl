# Read-only inspection of the existing synth_1 checkpoint in the open project.
# It does not launch or reset synthesis/implementation and restores system.bd.
if {[current_project -quiet] eq ""} {
    error "Open LightningReceiver.xpr before sourcing this script."
}
set lr_bd [get_files -quiet */system.bd]
open_run synth_1
puts "LR_EXISTING_SYNTH_CLOCKS_BEGIN"
foreach lr_clk [lsort [get_clocks -quiet]] {
    puts [format "%s period=%s source=%s" \
        $lr_clk \
        [get_property PERIOD $lr_clk] \
        [get_property SOURCE_PINS $lr_clk]]
}
puts "LR_EXISTING_SYNTH_CLOCKS_END"
puts "LR_EXISTING_SYNTH_CHECK_TIMING_BEGIN"
check_timing -verbose
puts "LR_EXISTING_SYNTH_CHECK_TIMING_END"
close_design
open_bd_design $lr_bd
puts "Synthesis and implementation were NOT launched or reset."
