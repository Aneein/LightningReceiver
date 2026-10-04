# ============================================================================
# Lightning Receiver - S0 Block Design builder (source-able)
# File: lr_bd_s0.tcl
# ----------------------------------------------------------------------------
# Creates the S0 "system" block design inside the OPEN Vivado project:
#   clk_wiz_225  : 200 MHz differential -> 225 MHz (fabric)
#   clk_wiz_100  : 225 MHz (no-buffer)  -> 100 MHz (control)
#   rst_225 / rst_100 : proc_sys_reset
#   uartlite_0   : axi_uartlite 115200 (control plane)
# Ports: sys_clk_p/n, fpga_rst_n, uart_rx, uart_tx
# Idempotent: existing "system" BD is deleted and recreated.
# Usage:  source <path>/lr_bd_s0.tcl   (inside Vivado, project open)
# ============================================================================

# --- guard: project must be open ---
if {[current_project -quiet] eq ""} {
    error "No project open. Create/open the LR project first (part xcku5p-ffvb676-2-i), then source this script."
}

# --- idempotent: remove existing BD ---
if {[llength [get_bd_designs -quiet system]] > 0} {
    puts "INFO: BD 'system' exists - removing and recreating"
    catch { close_bd_design [get_bd_designs system] }
    remove_files -fileset sources_1 [get_files -quiet system.bd]
}

create_bd_design "system"

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
# 200 MHz differential -> 225 MHz
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_225
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {225.000} \
    CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_225]

# 225 MHz (no buffer) -> 100 MHz control clock
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_100
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {225.000} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_100]

# ---------------------------------------------------------------------------
# Resets
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_225
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_100

# ---------------------------------------------------------------------------
# UART control plane
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 uartlite_0
set_property -dict [list CONFIG.C_BAUDRATE {115200}] [get_bd_cells uartlite_0]

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------
create_bd_port -dir I -type clk sys_clk_p
create_bd_port -dir I -type clk sys_clk_n
create_bd_port -dir I -type rst fpga_rst_n
create_bd_port -dir I uart_rx
create_bd_port -dir O uart_tx

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_ports sys_clk_p] [get_bd_pins clk_wiz_225/clk_in1_p]
connect_bd_net [get_bd_ports sys_clk_n] [get_bd_pins clk_wiz_225/clk_in1_n]
connect_bd_net [get_bd_pins clk_wiz_225/clk_out1] [get_bd_pins clk_wiz_100/clk_in1]

connect_bd_net [get_bd_pins clk_wiz_225/clk_out1] [get_bd_pins rst_225/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1] [get_bd_pins rst_100/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_100/clk_out1] [get_bd_pins uartlite_0/s_axi_aclk]

connect_bd_net [get_bd_ports fpga_rst_n] [get_bd_pins rst_225/ext_reset_in]
connect_bd_net [get_bd_ports fpga_rst_n] [get_bd_pins rst_100/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_225/locked] [get_bd_pins rst_225/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_225/locked] [get_bd_pins rst_100/dcm_locked]
connect_bd_net [get_bd_pins rst_100/peripheral_aresetn] [get_bd_pins uartlite_0/s_axi_aresetn]

connect_bd_net [get_bd_ports uart_rx] [get_bd_pins uartlite_0/rx]
connect_bd_net [get_bd_pins uartlite_0/tx] [get_bd_ports uart_tx]

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
validate_bd_design
puts "=== LR S0 BD 'system' created and validated ==="
