# Read-only live LR register dump through the instantiated JTAG AXI master.
# No transaction in this file has type "write".
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set axi [lindex [get_hw_axis -of_objects $dev] 0]
if {$axi eq ""} {
    error "No JTAG AXI core found in the programmed design"
}

# Re-arm the JTAG AXI debug slave after configuration.  Without this explicit
# reset Vivado can retain the pre-configuration transaction state and report a
# misleading Xicom 50-38 connection failure on the first access.
reset_hw_axi $axi

proc lr_read {axi name addr words} {
    set txn "lr_rd_${name}"
    catch {delete_hw_axi_txn [get_hw_axi_txns -quiet $txn]}
    create_hw_axi_txn $txn $axi -type read -address $addr -len $words -size 32
    if {[catch {run_hw_axi [get_hw_axi_txns $txn]} err]} {
        puts "READ_FAIL name=$name addr=$addr error=$err"
        return
    }
    puts "READ_OK name=$name addr=$addr data=[get_property DATA [get_hw_axi_txns $txn]]"
}

foreach {name addr} {
    lr_id          44A20000
    lr_status      44A20004
    lr_control     44A20008
    lr_mode        44A2000C
    lr_rf_freq     44A20010
    lr_rf_status   44A2001C
    lr_stream_en   44A20020
    lr_ddr_status  44A2004C
    lr_net_status  44A20050
    lr_err_status  44A20054
    lr_uptime      44A20058
    lr_cmac_status 44A20068
    cmac_tx_cfg    44A1000C
    cmac_rx_cfg    44A10014
    cmac_mode      44A10020
    cmac_version   44A10024
    ad9361_version 44A00000
    ad9361_id      44A00004
    ad9361_scratch 44A00040
    ad9361_reset   44A00044
    ad9361_status  44A0005C
} {
    lr_read $axi $name $addr 1
}

puts "=== MIG DEBUG CORES ==="
foreach mig [get_hw_migs -quiet -of_objects $dev] {
    puts "MIG=$mig"
    report_property $mig
}

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
