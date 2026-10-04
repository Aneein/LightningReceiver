open_project D:/workspace/.lr_val5/LRVal5.xpr
open_run impl_1
puts "=== cmac sync1 pins matched by XDC pattern ==="
foreach pat { *u_cmac_rx_level_sync/inst/sync1_reg*/D *u_cmac_misc_sync/inst/sync1_reg*/D *u_cmac_rx_event/inst/sync1_reg*/D *u_cmac_tx_event/inst/sync1_reg*/D } {
    set p [get_pins -hier -quiet -filter "NAME =~ $pat && REF_PIN_NAME == D"]
    puts "pattern $pat -> [llength $p]"
}
puts "DONE"
