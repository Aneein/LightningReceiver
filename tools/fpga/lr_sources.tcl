# ============================================================================
# Lightning Receiver - Add custom RTL sources + ADI IP repo (source-able)
# File: lr_sources.tcl
# ----------------------------------------------------------------------------
# Adds the LR custom RTL source tree (D:/workspace/LightningReceiver/rtl) to
# the open project (per-subdir glob, only missing files) and registers the
# ADI HDL IP repository (axi_ad9361 etc.). Idempotent.
# Usage:  source <path>/lr_sources.tcl   (inside Vivado, project open)
# ============================================================================

if {[current_project -quiet] eq ""} {
    error "No project open. Open the LR project first, then source this script."
}

set lr_root  "D:/workspace/LightningReceiver"
set rtl_dir  "$lr_root/rtl"
set adi_lib  "$lr_root/fpga/vendor_reference/FMC_AD936X_PL/library"

# ---------------------------------------------------------------------------
# 1. Register ADI IP repository (axi_ad9361, axi_dmac, util_* ...)
# ---------------------------------------------------------------------------
set repos [get_property ip_repo_paths [current_project]]
if {[lsearch -exact $repos $adi_lib] < 0} {
    set_property ip_repo_paths [concat $repos [list $adi_lib]] [current_project]
    puts "INFO: ADI IP repo added: $adi_lib"
} else {
    puts "INFO: ADI IP repo already registered"
}
update_ip_catalog

# ---------------------------------------------------------------------------
# 2. Add custom RTL sources (per-subdir glob; add only missing files)
# ---------------------------------------------------------------------------
if {![file exists $rtl_dir]} {
    puts "WARNING: $rtl_dir does not exist - no custom RTL added"
} else {
    set to_add [list]
    foreach d [glob -nocomplain -directory $rtl_dir -type d *] {
        foreach f [glob -nocomplain -directory $d *.v *.vh *.mem] {
            if {[llength [get_files -quiet -filter "NAME == \"$f\""]] == 0} {
                lappend to_add $f
            }
        }
    }
    if {[llength $to_add] > 0} {
        add_files -norecurse -fileset sources_1 $to_add
        puts "INFO: added [llength $to_add] RTL file(s)"
    } else {
        puts "INFO: all custom RTL already in project"
    }
    # include path for lr_defines.vh; memory initialization files such as the
    # 4096-entry window ROM are added above so synthesis can resolve readmemh.
    set_property include_dirs [list $rtl_dir/include] [get_filesets sources_1]
    # refresh compile order so BD can resolve the modules as cells
    update_compile_order -fileset sources_1
    puts "=== Custom RTL ready from $rtl_dir ==="
}
