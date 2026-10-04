# LR timing convergence: async CDC false paths
# Cross-domain synchronizers are structurally asynchronous.  Relax only
# the sync-chain-internal and explicit CDC edges; all same-domain logic
# remains fully timing-checked.
# ---- generic: ASYNC_REG sync chains in custom RTL ----
# (cdc_level_sync / lr_cdc_event_latch / lr_async_fifo / lr_pulse_cdc /
#  button key sync).  Relax only *between* sync flops.
set_false_path -from [get_cells -hier -quiet -filter {ASYNC_REG == "TRUE"}] \
                -to   [get_cells -hier -quiet -filter {ASYNC_REG == "TRUE"}]
# ---- lr_pulse_cdc: source-domain toggle feeds the dst sync chain ----
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *pulse_cdc*/toggle_src*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *pulse_cdc*/sync1*}]
# ---- u_calib_sync / u_r1mode_sync: MIG/AD9361 level -> fabric sync1 ----
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_ddr_cal_top/calDone_gated_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_calib_sync/inst/sync1*}]
set_false_path -from [get_pins -hier -quiet -filter {NAME =~ *axi_ad9361_0/adc_r1_mode*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_r1mode_sync/inst/sync1*}]
# ---- u_ring Gray-coded status syncs ----
# The 333M-domain Gray encoders (wr_words_axi / ring_ptr) feed the 225M
# double-flop sync stages (gray_s1/s2).  The CDC edge is axi->gray_s1.
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_axi_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_gray_s1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/ring_ptr_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/ring_ptr_gray_s1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/axi_write_error_axi_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_ring/inst/axi_error_s1*}]
# ---- u_aring (DDR audio ring): same Gray-coded status syncs as u_ring ----
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/wr_words_axi_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/wr_words_gray_s1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/ring_ptr_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/ring_ptr_gray_s1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/axi_write_error_axi_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_aring/inst/axi_error_s1*}]
# ---- u_key_sync: debounced key levels 100M (u_btn) -> 225M sync1 ----
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_btn/inst/key_stable_reg*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_key_sync/inst/sync1*}]
# ---- lr_jtag_axi_bridge: BSCANE2 USER4 TCK (FT2232H, <= 30 MHz) ----
create_clock -period 33.333 -name lr_jtag_tck [get_pins -hier -filter {NAME =~ *u_jbridge/inst/u_bscan/TCK}]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks lr_jtag_tck] \
    -group [get_clocks -include_generated_clocks clk_out1_system_clk_fabric_0]
# ---- u_ring async FIFO pointer sync (source gray -> dst gray_r1) ----
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_bin*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_bin*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_gray_r1*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_gray*}] \
                -to   [get_cells -hier -quiet -filter {NAME =~ *u_sample_fifo/rd_ptr_gray_r1*}]
# ---- CMAC GT-domain status/events -> 225M syncers ----
# CMAC stat_*/usr_* signals are in rxoutclk/txoutclk (GT) domain and feed
# cdc_level_sync / lr_cdc_event_latch with dst_clk = fabric 225M.  The GT
# clocks and fabric clock are genuinely asynchronous: declare them as
# separate async groups (covers every GT->fabric path, including CMAC
# internal CDC syncs into stats and our level/event syncers).
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks rxoutclk_out[0]] \
    -group [get_clocks -include_generated_clocks txoutclk_out[0]] \
    -group [get_clocks -include_generated_clocks clk_out1_system_clk_fabric_0]
# CMAC internal GT-domain stat accumulators: IP-internal async paths
# (reset-done CDC into stats) are not user-timing-relevant.
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *cmac_cdc_sync_gt_rxresetdone_int/s_out_d4_reg*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *cmac_cdc_sync_gt_txresetdone_int/s_out_d4_reg*}]
