# ============================================================================
# Lightning Receiver - Master setup (source-able)
# File: lr_setup.tcl
# ----------------------------------------------------------------------------
# Sources all LR setup scripts in order against the OPEN project:
#   1. lr_bd_s0.tcl       - S0 block design (clocks/reset/UART)
#   2. lr_constraints.tcl - board XDC
#   3. lr_wrapper.tcl     - wrapper + top
# Then build with:  source <path>/lr_build.tcl
#
# Prerequisite: Vivado project created manually:
#   project name : LightningReceiver
#   location     : D:/workspace/LightningReceiver/fpga/LightningReceiver
#   part         : xcku5p-ffvb676-2-i
#
# Usage (in Vivado Tcl console, project open):
#   source D:/workspace/LightningReceiver/tools/fpga/lr_setup.tcl
# ============================================================================

set script_dir [file dirname [info script]]

source [file join $script_dir lr_bd_s0.tcl]
source [file join $script_dir lr_constraints.tcl]
source [file join $script_dir lr_wrapper.tcl]

puts ""
puts "======================================================================"
puts " LR S0 setup complete."
puts " Next: source [file join $script_dir lr_build.tcl]  (synth+impl+bit)"
puts "       or:  set RUN_IMPL 0; source <same>          (synth only)"
puts "======================================================================"
