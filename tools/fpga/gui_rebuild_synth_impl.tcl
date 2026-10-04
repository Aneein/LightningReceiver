# Refresh changed RTL/module-reference products in the currently open GUI,
# then run synthesis, implementation and bitstream generation with reports.

set lr_root "D:/workspace/LightningReceiver"
if {[current_project -quiet] eq ""} {
    error "Open the LightningReceiver project before sourcing this script"
}

puts "LR_GUI_BUILD: refresh sources and BD products"
source "$lr_root/tools/fpga/lr_sources.tcl"
update_compile_order -fileset sources_1
open_bd_design [get_files system.bd]
validate_bd_design
save_bd_design
generate_target all [get_files system.bd]
source "$lr_root/tools/fpga/lr_wrapper.tcl"
update_compile_order -fileset sources_1

# Clear failed/out-of-date parent runs. Vivado will recreate the required OOC
# module runs from the freshly generated BD products.
catch {reset_run impl_1}
catch {reset_run synth_1}

set RUN_IMPL 1
source "$lr_root/tools/fpga/lr_build.tcl"
puts "LR_GUI_SYNTH_IMPL_PASS"
