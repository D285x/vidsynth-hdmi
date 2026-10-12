#!/bin/sh
# Serial-level HDMI testbench with Verilator: ./sim/sv/run_serial.sh 0   (or 1 for 720p)
set -e
MODE=${1:-0}
cd "$(dirname "$0")/../.."
SRC="rtl/vs_pkg.sv rtl/sin_lut.sv rtl/sync_2ff.sv rtl/clkgen.sv rtl/video_timing.sv rtl/pattern_axis.sv \
     rtl/axis_to_video.sv rtl/tmds_channel.sv rtl/audio_gen.sv rtl/hdmi_tx.sv rtl/edid_reader.sv \
     rtl/tmds_serializer.sv rtl/vidsynth_hdmi_top.sv sim/sv/tb_hdmi_top.sv"
verilator --binary --timing -DSIM --assert -Wno-fatal -Wno-WIDTH -Wno-lint -Wno-style \
    --top-module tb_hdmi_top -GMODE=$MODE -Mdir sim/sv/obj$MODE $SRC
mkdir -p sim/sv/run$MODE
cd sim/sv/run$MODE && ../obj$MODE/Vtb_hdmi_top
