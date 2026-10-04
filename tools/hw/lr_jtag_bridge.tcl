# ============================================================================
# Lightning Receiver - JTAG-AXI TCP bridge (Vivado 2021.1 hardware manager)
# ----------------------------------------------------------------------------
# Owns the JTAG connection and serves a tiny line protocol on 127.0.0.1 so
# host programs (tools/hw/ad9361_jtag) can reach the FPGA AXI space without
# a CPU in the design.
#
#   R <addr>          -> OK <data>          32-bit read  (hex, no 0x)
#   W <addr> <data>   -> OK                 32-bit write
#   B <addr> <n>      -> OK <w0> ... <wn-1> burst read, n = 1..256 words,
#                                           ascending addresses
#   S <tx24>          -> OK <rx24>          one AD9361 SPI transaction via
#                                           register_bank SPI_TX/CONTROL/STATUS
#   P                 -> OK pong
#   Q                 -> OK bye             (closes this client)
#   errors            -> ERR <text>
#
# Start (PowerShell):
#   $env:PROCESSOR_ARCHITECTURE='AMD64'
#   D:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode tcl -nojournal -nolog `
#       -source tools\hw\lr_jtag_bridge.tcl [-tclargs <port>]
# Only one program may hold the JTAG-AXI core: close other hardware-manager
# sessions (GUI "Open Target") before starting the bridge.
# ============================================================================

set lr_port 5555
if {[llength $argv] > 0} { set lr_port [lindex $argv 0] }

# LR register bank (jtag_axi_0 address map, see lr_defines.vh)
set LR_BASE      0x44A20000
set LR_SPI_TX    [expr {$LR_BASE + 0x050}]
set LR_SPI_RX    [expr {$LR_BASE + 0x054}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set lr_dev [lindex [get_hw_devices] 0]
current_hw_device $lr_dev
refresh_hw_device -update_hw_probes false $lr_dev
set lr_axi [lindex [get_hw_axis -of_objects $lr_dev] 0]
if {$lr_axi eq ""} { error "no JTAG-AXI core in the programmed design" }
reset_hw_axi $lr_axi

proc lr_hex32 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

proc lr_txn {type addr len {data ""}} {
    global lr_axi
    catch {delete_hw_axi_txn [get_hw_axi_txns -quiet lr_bridge_txn]}
    if {$type eq "write"} {
        create_hw_axi_txn lr_bridge_txn $lr_axi -type write \
            -address [lr_hex32 $addr] -len $len -data $data
    } else {
        create_hw_axi_txn lr_bridge_txn $lr_axi -type read \
            -address [lr_hex32 $addr] -len $len
    }
    run_hw_axi -quiet [get_hw_axi_txns lr_bridge_txn]
    return [get_property DATA [get_hw_axi_txns lr_bridge_txn]]
}

proc lr_read32 {addr} {
    return [string range [lr_txn read $addr 1] end-7 end]
}

proc lr_write32 {addr data} {
    lr_txn write $addr 1 [lr_hex32 $data]
}

# One 24-bit AD9361 SPI transaction.
#   Burst write SPI_TX..SPI_CONTROL = {tx, -, -, start}; register_bank ignores
#   writes to the read-only SPI_RX/SPI_STATUS words.  Burst DATA lists the
#   highest address first.  Then read {SPI_STATUS, SPI_RX} until not busy.
proc lr_spi {tx24} {
    global LR_SPI_TX LR_SPI_RX
    set tx [expr {$tx24 & 0xFFFFFF}]
    # {CONTROL=start}{STATUS}{RX}{TX}
    lr_txn write $LR_SPI_TX 4 "00000001[string repeat 0 16][lr_hex32 $tx]"
    for {set i 0} {$i < 50} {incr i} {
        set d [lr_txn read $LR_SPI_RX 2]
        # d = {STATUS(0x058)}{RX(0x054)}
        set status [expr {"0x[string range $d 0 7]"}]
        set rx     [expr {"0x[string range $d 8 15]"}]
        if {($status & 1) == 0} { return [format %06X [expr {$rx & 0xFFFFFF}]] }
    }
    error "SPI busy timeout"
}

proc lr_handle {chan} {
    if {[catch {gets $chan line} n] || $n < 0} {
        if {[eof $chan]} { catch {close $chan} }
        return
    }
    set f [split [string trim $line]]
    set cmd [string toupper [lindex $f 0]]
    if {[catch {
        switch -- $cmd {
            R { set r "OK [lr_read32 [expr {"0x[lindex $f 1]"}]]" }
            W { lr_write32 [expr {"0x[lindex $f 1]"}] [expr {"0x[lindex $f 2]"}]; set r "OK" }
            S { set r "OK [lr_spi [expr {"0x[lindex $f 1]"}]]" }
            B {
                # burst read: B <addr> <n 1..256> -> OK w0 w1 ... (ascending)
                set n [lindex $f 2]
                if {$n < 1 || $n > 256} { error "burst length 1..256" }
                set d [lr_txn read [expr {"0x[lindex $f 1]"}] $n]
                set words {}
                for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
                    lappend words [string range $d [expr {8 * $i}] [expr {8 * $i + 7}]]
                }
                set r "OK [join $words { }]"
            }
            P { set r "OK pong" }
            Q { set r "OK bye" }
            default { set r "ERR unknown command '$cmd'" }
        }
    } err]} {
        set r "ERR [string map {"\n" " "} $err]"
    }
    puts $chan $r
    flush $chan
    if {$cmd eq "Q"} { catch {close $chan} }
}

proc lr_accept {chan addr port} {
    fconfigure $chan -buffering line -translation lf
    fileevent $chan readable [list lr_handle $chan]
    puts "LR_BRIDGE client $addr:$port"
}

socket -server lr_accept -myaddr 127.0.0.1 $lr_port
puts "LR_BRIDGE_READY port=$lr_port device=$lr_dev axi=$lr_axi"
vwait forever
