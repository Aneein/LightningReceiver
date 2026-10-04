# LR FMC_AD9361 pins (RK-XCKU5P-F V1.2, VADJ1=1.8V)
# Frozen from FMC_AD936X.pdf J1 and the carrier FMC pin definition.
# RESETB is on J1-D31 (FMC TDO), is not routed as carrier FPGA GPIO, and has
# a 10 kohm pull-up to VDD_INTERFACE on the card.  Do not drive an LA pin for it.

# --- RX LVDS (6-bit DDR) ---
set_property -dict {PACKAGE_PIN G24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_clk_in_p]
set_property -dict {PACKAGE_PIN G25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_clk_in_n]
set_property -dict {PACKAGE_PIN J23 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_frame_in_p]
set_property -dict {PACKAGE_PIN J24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports rx_frame_in_n]
set_property -dict {PACKAGE_PIN H21 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[0]}]
set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[0]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[1]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[1]}]
set_property -dict {PACKAGE_PIN H26 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[2]}]
set_property -dict {PACKAGE_PIN G26 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[2]}]
set_property -dict {PACKAGE_PIN F24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[3]}]
set_property -dict {PACKAGE_PIN F25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[3]}]
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[4]}]
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[4]}]
set_property -dict {PACKAGE_PIN D24 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_p[5]}]
set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports {rx_data_in_n[5]}]

create_clock -period 4.000 -name rx_clk [get_ports rx_clk_in_p]
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks rx_clk] \
    -group [get_clocks -include_generated_clocks c0_sys_clk_clk_p] \
    -group [get_clocks -include_generated_clocks qsfp_refclk]

# --- control (LVCMOS18, VADJ1) ---
set_property -dict {PACKAGE_PIN E21 IOSTANDARD LVCMOS18} [get_ports enable]
set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS18} [get_ports txnrx]
set_property -dict {PACKAGE_PIN A19 IOSTANDARD LVCMOS18 PULLUP TRUE} [get_ports spi_csn]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS18} [get_ports spi_sclk]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS18} [get_ports spi_mosi]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS18} [get_ports spi_miso]
