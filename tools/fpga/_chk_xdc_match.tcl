# Verify current convergence XDC pattern matching on synth netlist
open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run synth_1
puts "=== pattern match test (same filter as XDC) ==="
foreach lr_pat { *sync1_reg*/D *rx_meta_reg/D *key_sync0_reg*/D *wr_ptr_gray_r1_reg*/D *rd_ptr_gray_r1_reg*/D *overflow_sync1_reg/D *axi_error_s1_reg/D *wr_words_gray_s1_reg*/D *ring_ptr_gray_s1_reg*/D } {
    set lr_pins [get_pins -hier -quiet -filter "NAME =~ $lr_pat && REF_PIN_NAME == D"]
    puts "pattern '$lr_pat' -> [llength $lr_pins] pins"
}
puts "=== specific: u_ring sync regs ==="
puts "wr_words_gray_s1: [llength [get_pins -hier -quiet -filter {NAME =~ *u_ring/inst/wr_words_gray_s1*}] ]"
puts "wr_ptr_gray_r1: [llength [get_pins -hier -quiet -filter {NAME =~ *u_sample_fifo/wr_ptr_gray_r1*}] ]"
puts "DONE"
