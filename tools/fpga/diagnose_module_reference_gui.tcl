# Diagnose Vivado module-reference refresh behavior in the open BD.
# This script never launches or resets synthesis/implementation runs.
set lr_root D:/workspace/LightningReceiver
set lr_report $lr_root/reports/presynth/module_reference_diagnostic.txt
file mkdir [file dirname $lr_report]
set lr_fd [open $lr_report w]
puts $lr_fd "current_bd_design=[current_bd_design -quiet]"
puts $lr_fd "u_btn_cells=[get_bd_cells -quiet u_btn]"
puts $lr_fd "u_btn_ips=[get_ips -quiet *btn*]"
foreach lr_cell [get_bd_cells -quiet -hier] {
    set lr_type ""
    catch {set lr_type [get_property TYPE $lr_cell]}
    set lr_ref ""
    catch {set lr_ref [get_property CONFIG.Component_Name $lr_cell]}
    if {$lr_type ne "" || $lr_ref ne ""} {
        puts $lr_fd "CELL=$lr_cell TYPE=$lr_type COMPONENT=$lr_ref"
    }
}
set lr_rc [catch {update_module_reference u_btn} lr_msg lr_opts]
puts $lr_fd "UPDATE_U_BTN_RC=$lr_rc"
puts $lr_fd "UPDATE_U_BTN_MESSAGE=$lr_msg"
if {$lr_rc && [dict exists $lr_opts -errorinfo]} {
    puts $lr_fd "UPDATE_U_BTN_ERRORINFO=[dict get $lr_opts -errorinfo]"
}
set lr_rc [catch {update_module_reference lr_button_controller} lr_msg lr_opts]
puts $lr_fd "UPDATE_LR_BUTTON_CONTROLLER_RC=$lr_rc"
puts $lr_fd "UPDATE_LR_BUTTON_CONTROLLER_MESSAGE=$lr_msg"
if {$lr_rc && [dict exists $lr_opts -errorinfo]} {
    puts $lr_fd "UPDATE_LR_BUTTON_CONTROLLER_ERRORINFO=[dict get $lr_opts -errorinfo]"
}
set lr_rc [catch {update_module_reference [get_ips -quiet system_u_btn_0]} lr_msg lr_opts]
puts $lr_fd "UPDATE_SYSTEM_U_BTN_0_RC=$lr_rc"
puts $lr_fd "UPDATE_SYSTEM_U_BTN_0_MESSAGE=$lr_msg"
if {$lr_rc && [dict exists $lr_opts -errorinfo]} {
    puts $lr_fd "UPDATE_SYSTEM_U_BTN_0_ERRORINFO=[dict get $lr_opts -errorinfo]"
}
close $lr_fd
puts "LR_MODULE_REFERENCE_DIAGNOSTIC $lr_report"
puts "Synthesis and implementation were NOT launched or reset."
