# ============================================================================
# program.tcl - program the FPGA over JTAG (lost at power-off)
#   vivado -mode batch -source scripts/program.tcl -tclargs edge
# ============================================================================
set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "edge"}]
set root   [file normalize [file join [file dirname [info script]] ..]]
set bit    [lindex [glob [file join $root vivado_$target vidsynth_$target.runs impl_1 *.bit]] 0]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "Programmed $dev with $bit"
close_hw_manager
