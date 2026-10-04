# Program the currently implemented LightningReceiver image into the first
# locally attached FPGA.  This script intentionally does not launch synthesis
# or implementation.

set project_root "D:/workspace/LightningReceiver"
set bit_file "$project_root/fpga/LightningReceiver/LightningReceiver.runs/impl_1/system_wrapper.bit"
set ltx_file "$project_root/fpga/LightningReceiver/LightningReceiver.runs/impl_1/system_wrapper.ltx"

if {![file exists $bit_file]} {
    error "Bitstream not found: $bit_file"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices -quiet] 0]
if {$dev eq ""} {
    error "No FPGA device was found on the hardware target"
}

current_hw_device $dev
set_property PROGRAM.FILE $bit_file $dev
if {[file exists $ltx_file]} {
    set_property PROBES.FILE $ltx_file $dev
    set_property FULL_PROBES.FILE $ltx_file $dev
}

puts "PROGRAM_BEGIN device=$dev bit=$bit_file"
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "PROGRAM_OK device=$dev"

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
