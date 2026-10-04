open_project D:/workspace/.lr_scratch3/LightningReceiver.xpr
open_bd_design [get_files system.bd]
puts "direct: [get_bd_pins -quiet ddr4_0/sys_rst]"
puts "all: [get_bd_pins -quiet -of_objects [get_bd_cells ddr4_0]]"
puts "type: [get_property TYPE [get_bd_pins ddr4_0/sys_rst]]"
puts "name: [get_property NAME [get_bd_pins ddr4_0/sys_rst]]"
