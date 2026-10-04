# ============================================================================
# Lightning Receiver - Timing convergence constraints (source-able)
# PRECISE per-CDC-edge false paths (validated: WNS +0.052ns on scratch4)
# ----------------------------------------------------------------------------
# Cross-domain synchronizers are structurally asynchronous.  Relax only the
# sync-chain-internal and explicit CDC edges; all same-domain logic remains
# fully timing-checked.
# Usage:  source <path>/lr_timing_convergence.tcl   (inside Vivado)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

set proj_dir [get_property DIRECTORY [current_project]]
set xdc_file "$proj_dir/lr_timing_convergence.xdc"

set old [get_files -quiet -of_objects [get_filesets constrs_1] lr_timing_convergence.xdc]
if {[llength $old] > 0} {
    remove_files -fileset constrs_1 $old
    puts "INFO: removed previous lr_timing_convergence.xdc from fileset"
}

set fp [open $xdc_file w]
puts $fp "# LR timing convergence: async CDC false paths"
puts $fp "# Cross-domain synchronizers are structurally asynchronous.  Relax only"
puts $fp "# the sync-chain-internal and explicit CDC edges; all same-domain logic"
puts $fp "# remains fully timing-checked."
puts $fp "# ---- generic: ASYNC_REG sync chains in custom RTL ----"
puts $fp "# (cdc_level_sync / lr_cdc_event_latch / lr_async_fifo / lr_pulse_cdc /"
puts $fp "#  button key sync).  Relax only *between* sync flops."
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {ASYNC_REG == \"TRUE\"}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {ASYNC_REG == \"TRUE\"}\]"
puts $fp "# ---- lr_pulse_cdc: source-domain toggle feeds the dst sync chain ----"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *pulse_cdc*/toggle_src*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *pulse_cdc*/sync1*}\]"
puts $fp "# ---- u_calib_sync / u_r1mode_sync: MIG/AD9361 level -> fabric sync1 ----"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_ddr_cal_top/calDone_gated_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_calib_sync/inst/sync1*}\]"
puts $fp "set_false_path -from \[get_pins -hier -quiet -filter {NAME =~ *axi_ad9361_0/adc_r1_mode*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_r1mode_sync/inst/sync1*}\]"
puts $fp "# ---- u_ring Gray-coded status syncs ----"
puts $fp "# The 333M-domain Gray encoders (wr_words_axi / ring_ptr) feed the 225M"
puts $fp "# double-flop sync stages (gray_s1/s2).  The CDC edge is axi->gray_s1."
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_axi_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_gray_s1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/ring_ptr_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/ring_ptr_gray_s1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/axi_write_error_axi_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/axi_error_s1*}\]"
puts $fp "# ---- u_aring (DDR audio ring): same Gray-coded status syncs as u_ring ----"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/wr_words_axi_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/wr_words_gray_s1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/ring_ptr_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/ring_ptr_gray_s1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/axi_write_error_axi_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/axi_error_s1*}\]"
puts $fp "# ---- u_key_sync: debounced key levels 100M (u_btn) -> 225M sync1 ----"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_btn/inst/key_stable_reg*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_key_sync/inst/sync1*}\]"
puts $fp "# ---- lr_jtag_axi_bridge: BSCANE2 USER4 TCK (FT2232H, <= 30 MHz) ----"
puts $fp "create_clock -period 33.333 -name lr_jtag_tck \[get_pins -hier -filter {NAME =~ *u_jbridge/inst/u_bscan/TCK}\]"
puts $fp "set_clock_groups -asynchronous -group \[get_clocks -include_generated_clocks lr_jtag_tck\] \\"
puts $fp "    -group \[get_clocks -include_generated_clocks clk_out1_system_clk_fabric_0\]"
puts $fp "# ---- u_ring async FIFO pointer sync (source gray -> dst gray_r1) ----"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_bin*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_bin*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_gray_r1*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_gray*}\] \\"
puts $fp "                -to   \[get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_gray_r1*}\]"
puts $fp "# ---- CMAC GT-domain status/events -> 225M syncers ----"
puts $fp "# CMAC stat_*/usr_* signals are in rxoutclk/txoutclk (GT) domain and feed"
puts $fp "# cdc_level_sync / lr_cdc_event_latch with dst_clk = fabric 225M.  The GT"
puts $fp "# clocks and fabric clock are genuinely asynchronous: declare them as"
puts $fp "# separate async groups (covers every GT->fabric path, including CMAC"
puts $fp "# internal CDC syncs into stats and our level/event syncers)."
puts $fp "set_clock_groups -asynchronous \\"
puts $fp "    -group \[get_clocks -include_generated_clocks rxoutclk_out\[0\]\] \\"
puts $fp "    -group \[get_clocks -include_generated_clocks txoutclk_out\[0\]\] \\"
puts $fp "    -group \[get_clocks -include_generated_clocks clk_out1_system_clk_fabric_0\]"
puts $fp "# CMAC internal GT-domain stat accumulators: IP-internal async paths"
puts $fp "# (reset-done CDC into stats) are not user-timing-relevant."
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *cmac_cdc_sync_gt_rxresetdone_int/s_out_d4_reg*}\]"
puts $fp "set_false_path -from \[get_cells -hier -quiet -filter {NAME =~ *cmac_cdc_sync_gt_txresetdone_int/s_out_d4_reg*}\]"
close $fp

add_files -fileset constrs_1 $xdc_file
# MIG / CMAC OOC cells do not exist during global synthesis; these CDC pins
# only materialize in the elaborated implementation netlist.  Apply the file
# at implementation only (same practice as F_SMART stage3_calib_cdc_falsepath).
set_property USED_IN_SYNTHESIS false [get_files $xdc_file]
set_property USED_IN_IMPLEMENTATION true [get_files $xdc_file]
puts "=== LR CDC constraints added (precise per-edge, impl-only): $xdc_file ==="
