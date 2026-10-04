# quick check of ddr4_0 pins
open_project D:/workspace/.lr_scratch3/LightningReceiver.xpr
open_bd_design [get_files system.bd]
puts "ddr4_0 pins:"
foreach p [get_bd_pins -of_objects [get_bd_cells ddr4_0]] {
    puts "  [get_property NAME $p] dir=[get_property DIR $p]"
}
