# Verify spectrum_engine fix: syntax + synth on scratch4
open_project D:/workspace/.lr_scratch4/LightningReceiver.xpr
set lr "D:/workspace/LightningReceiver/tools/fpga"
# re-add RTL (spectrum_engine.v changed on disk; refresh in project)
set sf [get_files -quiet -filter {NAME =~ *spectrum_engine.v}]
if {[llength $sf] > 0} {
    remove_files -fileset sources_1 $sf
}
add_files -norecurse -fileset sources_1 D:/workspace/LightningReceiver/rtl/dsp/spectrum_engine.v
update_compile_order -fileset sources_1
reset_run synth_1
set RUN_IMPL 0
source $lr/lr_build.tcl
puts "=== SPECTRUM FIX SYNTH DONE ==="
