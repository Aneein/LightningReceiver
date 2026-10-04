# Parse and apply the updated user timing exceptions against the existing
# synth_1 checkpoint.  This is read-only and never launches/resets a run.
if {[current_project -quiet] eq ""} {
    error "Open LightningReceiver.xpr before sourcing this script."
}
set lr_root D:/workspace/LightningReceiver
set lr_bd [get_files -quiet */system.bd]
open_run synth_1

# This proves that the explicit XDC syntax is accepted by Vivado 2021.1.
read_xdc -unmanaged $lr_root/fpga/LightningReceiver/lr_timing_convergence.xdc

set lr_rx_clks [get_clocks -quiet -include_generated_clocks rx_clk]
set lr_sys_clks [get_clocks -quiet -include_generated_clocks c0_sys_clk_clk_p]
set lr_qsfp_clks [get_clocks -quiet -include_generated_clocks qsfp_refclk_p]
if {[llength $lr_rx_clks] == 0} {
    error "rx_clk clock group is empty"
}
if {[llength $lr_sys_clks] == 0} {
    error "c0_sys_clk_clk_p clock group is empty"
}
if {[llength $lr_qsfp_clks] == 0} {
    error "qsfp_refclk_p clock group is empty"
}
set_clock_groups -asynchronous \
    -group $lr_rx_clks \
    -group $lr_sys_clks \
    -group $lr_qsfp_clks

foreach lr_pat {
    *sync1_reg*/D *rx_meta_reg/D *key_sync0_reg*/D
    *wr_ptr_gray_r1_reg*/D *rd_ptr_gray_r1_reg*/D
    *overflow_sync1_reg/D *axi_error_s1_reg/D
    *wr_words_gray_s1_reg*/D *ring_ptr_gray_s1_reg*/D
} {
    set lr_count [llength [get_pins -hier -quiet -filter "NAME =~ $lr_pat && REF_PIN_NAME == D"]]
    puts "LR_TIMING_ENDPOINTS $lr_pat $lr_count"
}
puts "LR_TIMING_XDC_PARSE_PASS"
puts "Synthesis and implementation were NOT launched or reset."
close_design
open_bd_design $lr_bd
