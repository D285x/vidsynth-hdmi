# ============================================================================
# build.tcl - create the project, synthesize, implement, write the bitstream,
#             and write the utilization, timing, CDC and methodology reports.
#   vivado -mode batch -source scripts/build.tcl -tclargs edge
# ============================================================================
source [file join [file dirname [info script]] create_project.tcl]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed" }

open_run impl_1
report_utilization        -file [file join $proj_dir utilization.rpt]
report_timing_summary     -file [file join $proj_dir timing_summary.rpt]
report_clock_interaction  -file [file join $proj_dir clock_interaction.rpt]
report_cdc                -file [file join $proj_dir cdc.rpt]
report_methodology        -file [file join $proj_dir methodology.rpt]
puts "Bitstream: [glob [get_property DIRECTORY [get_runs impl_1]]/*.bit]"
