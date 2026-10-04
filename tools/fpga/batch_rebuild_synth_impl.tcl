# Batch entry point used when the open GUI cannot safely accept automation.
# It exercises the same project/run flow and emits the same reports/bitstream.

set lr_root "D:/workspace/LightningReceiver"
open_project "$lr_root/fpga/LightningReceiver/LightningReceiver.xpr"
source "$lr_root/tools/fpga/gui_rebuild_synth_impl.tcl"
close_project
exit
