# Remove the invalid FMC_AD936X RESETB boundary port from the currently open
# LightningReceiver block design.  This script only updates design sources and
# generated products; it never launches or resets synthesis/implementation.
if {[current_project -quiet] eq ""} {
    error "Open LightningReceiver.xpr before sourcing this script."
}

set lr_bd [get_files -quiet */system.bd]
if {[llength $lr_bd] != 1} {
    error "Expected exactly one system.bd, found [llength $lr_bd]"
}
open_bd_design $lr_bd

set lr_reset_port [get_bd_ports -quiet gpio_resetb]
if {[llength $lr_reset_port] == 1} {
    delete_bd_objs $lr_reset_port
} elseif {[llength $lr_reset_port] != 0} {
    error "Expected zero or one gpio_resetb port, found [llength $lr_reset_port]"
}

if {[llength [get_bd_ports -quiet gpio_resetb]] != 0} {
    error "gpio_resetb port deletion did not take effect"
}

validate_bd_design
save_bd_design
generate_target all $lr_bd
export_ip_user_files -of_objects $lr_bd -no_script -sync -force -quiet
update_compile_order -fileset sources_1

puts "LR_GPIO_RESETB_REMOVED"
puts "Synthesis and implementation were NOT launched or reset."
