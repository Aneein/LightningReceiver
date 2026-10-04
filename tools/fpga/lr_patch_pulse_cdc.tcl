# ============================================================================
# LR timing-convergence patch: insert pulse CDC for 100M button events
# counted in the 225M telemetry domain (u_btn/key_press -> u_tele/inc[7:9]).
# Runs against the CURRENT open BD (no regeneration).  Safe to re-run.
# ============================================================================
if {[current_project -quiet] eq ""} {
    error "No project open."
}
if {[llength [get_bd_designs -quiet system]] == 0} {
    open_bd_design [get_files system.bd]
}

# make the new RTL resolvable (lr_sources already globs rtl/**/*.v; re-add if missing)
set pulse_src [file join [get_property DIRECTORY [current_project]] ../../../rtl/fabric/lr_pulse_cdc.v]
puts "INFO: pulse_cdc source: $pulse_src"

# 1) add module cell if not present
if {[llength [get_bd_cells -quiet u_btn_pulse_cdc]] == 0} {
    create_bd_cell -type module -reference lr_pulse_cdc u_btn_pulse_cdc
    set_property -dict [list CONFIG.WIDTH {3}] [get_bd_cells u_btn_pulse_cdc]
    puts "INFO: created u_btn_pulse_cdc (WIDTH=3)"
} else {
    puts "INFO: u_btn_pulse_cdc already exists"
}

# 2) wire src side (100M domain)
lr_connect clk_fabric/clk_out2 u_btn_pulse_cdc/src_clk
lr_connect rst_cmac_100/peripheral_aresetn u_btn_pulse_cdc/src_rst_n
# 3) wire dst side (225M domain)
lr_connect clk_fabric/clk_out1 u_btn_pulse_cdc/dst_clk
lr_connect rst_fabric/peripheral_aresetn u_btn_pulse_cdc/dst_rst_n
# 4) data: u_btn/key_press -> cdc -> xc_t_inc/In7
lr_connect u_btn/key_press u_btn_pulse_cdc/pulse_in
lr_connect u_btn_pulse_cdc/pulse_out xc_t_inc/In7

puts "=== PULSE CDC PATCH DONE ==="
