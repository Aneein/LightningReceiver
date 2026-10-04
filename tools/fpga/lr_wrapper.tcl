# ============================================================================
# Lightning Receiver - Wrapper + top set (source-able)
# File: lr_wrapper.tcl
# ----------------------------------------------------------------------------
# Generates the BD wrapper, adds it as top, refreshes compile order.
# Usage:  source <path>/lr_wrapper.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

make_wrapper -files [get_files system.bd] -top
# generate IP output products for the BD (required before synthesis)
generate_target all [get_files system.bd]
set proj_dir [get_property DIRECTORY [current_project]]
set proj_name [get_property NAME [current_project]]
add_files -norecurse $proj_dir/${proj_name}.srcs/sources_1/bd/system/hdl/system_wrapper.v
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]
puts "=== LR top set to system_wrapper; BD IP targets generated ==="
