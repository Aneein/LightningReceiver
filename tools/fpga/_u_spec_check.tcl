open_project D:/workspace/LightningReceiver/fpga/LightningReceiver/LightningReceiver.xpr
open_run impl_1
puts "=== u_spec violating endpoints ==="
set eps [get_timing_paths -max_paths 20000 -nworst 1 -setup -filter {SLACK < 0 && ENDPOINT =~ *u_spec*}]
puts "u_spec violated endpoints: [llength $eps]"
set shown 0
foreach ep $eps {
    if {$shown < 12} {
        puts "  [get_property ENDPOINT $ep] slack=[get_property SLACK $ep]"
        incr shown
    }
}
puts "=== total violated ==="
puts "total: [llength [get_timing_paths -max_paths 20000 -nworst 1 -setup -filter {SLACK < 0}]]"
puts "DONE"
