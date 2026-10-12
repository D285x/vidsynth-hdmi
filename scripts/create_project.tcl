# ============================================================================
# create_project.tcl - creates the Vivado project for vidsynth
#
# Vivado Tcl console:   cd <path>/vidsynth ; set argv {edge} ; source scripts/create_project.tcl
# Command line:         vivado -mode batch -source scripts/create_project.tcl -tclargs edge
#
# Targets:
#   edge        EDGE Artix 7, HDMI, 640x480 at 60 Hz (VIC 1)
#   edge720     EDGE Artix 7, HDMI, 1280x720 at 60 Hz (VIC 4)
#   edge_vga    EDGE Artix 7, VGA port, 640x480
#   basys3      Digilent Basys 3, VGA, 640x480
#   nexysa7_100 Digilent Nexys A7-100T / Nexys 4 DDR, VGA, 640x480
#   nexysa7_50  Digilent Nexys A7-50T, VGA, 640x480
# Optional second argument for HDMI targets: noedid  (DDC pins not connected)
# ============================================================================
set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "edge"}]
set opt    [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
set root   [file normalize [file join [file dirname [info script]] ..]]
set edid   [expr {$opt eq "noedid" ? 0 : 1}]

switch -- $target {
    edge        { set part xc7a35tftg256-1;   set xdc edge_artix7_hdmi.xdc; set top vidsynth_hdmi_top; set gen "CLKIN_MHZ=50 MODE=0 EDID_ENABLE=$edid" }
    edge720     { set part xc7a35tftg256-1;   set xdc edge_artix7_hdmi.xdc; set top vidsynth_hdmi_top; set gen "CLKIN_MHZ=50 MODE=1 EDID_ENABLE=$edid" }
    edge_vga    { set part xc7a35tftg256-1;   set xdc edge_artix7_vga.xdc;  set top vidsynth_vga_top;  set gen "CLKIN_MHZ=50 MODE=0" }
    basys3      { set part xc7a35tcpg236-1;   set xdc basys3_vga.xdc;       set top vidsynth_vga_top;  set gen "CLKIN_MHZ=100 MODE=0" }
    nexysa7_100 { set part xc7a100tcsg324-1;  set xdc nexys_a7_vga.xdc;     set top vidsynth_vga_top;  set gen "CLKIN_MHZ=100 MODE=0" }
    nexysa7_50  { set part xc7a50ticsg324-1L; set xdc nexys_a7_vga.xdc;     set top vidsynth_vga_top;  set gen "CLKIN_MHZ=100 MODE=0" }
    default     { error "Unknown target '$target'." }
}

set proj_dir [file join $root vivado_$target]
create_project vidsynth_$target $proj_dir -part $part -force

# design sources (SystemVerilog); the package first
set pkg  [file join $root rtl vs_pkg.sv]
set rest [lsearch -all -inline -not -exact [lsort [glob [file join $root rtl *.sv]]] $pkg]
add_files -norecurse [concat [list $pkg] $rest]
set_property file_type SystemVerilog [get_files *.sv]
add_files -fileset constrs_1 -norecurse [file join $root constraints $xdc]

set_property top     $top [current_fileset]
set_property generic $gen [current_fileset]

# simulation: the serial-level self-checking testbench (real MMCM/OSERDES models)
if {$top eq "vidsynth_hdmi_top"} {
    add_files -fileset sim_1 -norecurse [file join $root sim sv tb_hdmi_top.sv]
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] *.sv]
    set_property top tb_hdmi_top [get_filesets sim_1]
    set_property generic "MODE=[expr {$target eq "edge720" ? 1 : 0}]" [get_filesets sim_1]
    set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
}
update_compile_order -fileset sources_1
puts "Created $proj_dir/vidsynth_$target.xpr  part=$part top=$top  $gen"
