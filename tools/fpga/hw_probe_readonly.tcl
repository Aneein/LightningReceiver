# Read-only hardware inventory for LR bring-up.  This script never programs
# the FPGA and never writes an AXI register.
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

puts "=== HW TARGETS ==="
puts [get_hw_targets]
puts "=== HW DEVICES ==="
puts [get_hw_devices]

foreach dev [get_hw_devices] {
    current_hw_device $dev
    catch {refresh_hw_device -update_hw_probes false $dev} refresh_msg
    puts "DEVICE=$dev REFRESH=$refresh_msg"
    puts "PROGRAM_FILE=[get_property PROGRAM.FILE $dev]"
    puts "PROBES_FILE=[get_property PROBES.FILE $dev]"
    puts "AXI_CORES=[get_hw_axis -quiet -of_objects $dev]"
    puts "ILA_CORES=[get_hw_ilas -quiet -of_objects $dev]"
    puts "VIO_CORES=[get_hw_vios -quiet -of_objects $dev]"
}

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
