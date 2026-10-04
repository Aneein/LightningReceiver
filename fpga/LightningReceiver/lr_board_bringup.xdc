# LR board bring-up constraints (RK-XCKU5P-F V1.2)
# system clock: 200 MHz differential via MIG (T24/U24, DIFF_SSTL12)
# (clock created by MIG generated XDC - pins only here)
set_property PACKAGE_PIN T24 [get_ports c0_sys_clk_clk_p]
set_property PACKAGE_PIN U24 [get_ports c0_sys_clk_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports c0_sys_clk_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports c0_sys_clk_clk_n]
# UART: RX AD13 / TX AC14 (LVCMOS33)
set_property PACKAGE_PIN AD13 [get_ports uart_rx]
set_property PACKAGE_PIN AC14 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
# KEY1..4 are active-low controls; system reset follows MIG/MMCM lock.
set_property -dict {PACKAGE_PIN K9  IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {key_in[0]}]
set_property -dict {PACKAGE_PIN K10 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {key_in[1]}]
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {key_in[2]}]
set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {key_in[3]}]
# LED1 clock lock, LED2 DDR calibration, LED3 CMAC init, LED4 link.
set_property -dict {PACKAGE_PIN H9  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J9  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN G11 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
# QSFP28 module controls (same proven F_SMART board mapping).
set_property -dict {PACKAGE_PIN W12 IOSTANDARD LVCMOS33} [get_ports qsfp_resetl]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports qsfp_lpmode]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports qsfp_modsell]
# bitstream
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
# clock cascade placement (clk_fabric -> clk_wiz_iodelay MMCM)
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets system_i/clk_fabric/inst/clk_out1]
