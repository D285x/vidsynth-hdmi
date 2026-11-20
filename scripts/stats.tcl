# ============================================================================
# stats.tcl - extra reports for an already implemented build (no board needed)
#   vivado -mode batch -source scripts/stats.tcl -tclargs edge720
# Reports go to <root>/stats_<target>/
# ============================================================================
set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "edge720"}]
set root   [file normalize [file join [file dirname [info script]] ..]]
set out    [file join $root stats_$target]
file mkdir $out

open_project [file join $root vivado_$target vidsynth_$target.xpr]
open_run impl_1

report_power             -file [file join $out power.rpt]
report_design_analysis   -logic_level_distribution -file [file join $out logic_levels.rpt]
report_design_analysis   -congestion               -file [file join $out congestion.rpt]
report_design_analysis   -timing -max_paths 10     -file [file join $out critical_paths.rpt]
report_clock_utilization -file [file join $out clock_utilization.rpt]
report_io                -file [file join $out io.rpt]
report_utilization -hierarchical                   -file [file join $out util_hier.rpt]
report_timing -max_paths 5 -nworst 1 -path_type full -file [file join $out worst_paths.rpt]
report_drc               -file [file join $out drc.rpt]

puts "Reports written to $out"
close_project
