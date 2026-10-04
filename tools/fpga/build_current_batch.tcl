# Batch entry point for the already regenerated current LightningReceiver BD.
set lr_root "D:/workspace/LightningReceiver"
open_project "$lr_root/fpga/LightningReceiver/LightningReceiver.xpr"
source "$lr_root/tools/fpga/gui_rebuild_synth_impl.tcl"
close_project
exit 0
