# Standalone synthesis check for the DDR ring-buffer and its async FIFO.
# Uses an in-memory project so it never modifies the GUI project or run state.

set lr_root "D:/workspace/LightningReceiver"
create_project -in_memory -part xcku5p-ffvb676-2-i
set_property include_dirs [list "$lr_root/rtl/include"] [current_fileset]
read_verilog "$lr_root/rtl/fabric/lr_async_fifo.v"
read_verilog "$lr_root/rtl/ddr/ring_buffer.v"
synth_design -top ring_buffer -part xcku5p-ffvb676-2-i
report_utilization -file "$lr_root/reports/source_validation/ring_buffer_synth_util.rpt"
puts "LR_RING_SYNTH_PASS"
exit
