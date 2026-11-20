# ============================================================================
# strategies.tcl - rerun implementation with several strategies, compare slack
#   vivado -mode batch -source scripts/strategies.tcl -tclargs edge720
# Uses the existing synthesis result. Takes several minutes per strategy.
# Writes <root>/stats_<target>/strategies.csv
# ============================================================================
set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "edge720"}]
set root   [file normalize [file join [file dirname [info script]] ..]]
set out    [file join $root stats_$target]
file mkdir $out

open_project [file join $root vivado_$target vidsynth_$target.xpr]

set strats {
    Performance_Explore
    Performance_ExtraTimingOpt
    Performance_NetDelay_high
    Area_Explore
    Flow_RuntimeOptimized
}
set runs {}
set i 0
foreach s $strats {
    incr i
    set r impl_s$i
    if {[llength [get_runs -quiet $r]]} { delete_runs $r }
    create_run $r -parent_run synth_1 -flow {Vivado Implementation 2025} -strategy $s
    lappend runs $r
}
launch_runs $runs -jobs 4
foreach r $runs { wait_on_run $r }

set fh [open [file join $out strategies.csv] w]
puts $fh "run,strategy,status,WNS_ns,WHS_ns,LUTs,FFs"
puts "run,strategy,status,WNS_ns,WHS_ns,LUTs,FFs"
foreach r $runs s $strats {
    set st [get_property STATUS [get_runs $r]]
    if {[get_property PROGRESS [get_runs $r]] eq "100%"} {
        open_run $r -name $r
        set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
        set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1]]
        set lut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
        set ff  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
        close_design
    } else { set wns NA; set whs NA; set lut NA; set ff NA }
    set line "$r,$s,$st,$wns,$whs,$lut,$ff"
    puts $fh $line; puts $line
}
close $fh
close_project
