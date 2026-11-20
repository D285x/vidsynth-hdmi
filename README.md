# vidsynth: HDMI video synthesizer for the Artix-7

A real-time procedural video synthesizer with a native HDMI transmitter built from FPGA logic. Written in SystemVerilog, verified with cocotb, Verilator and independent Python reference models.

**Features**
- 640x480 at 60 Hz (VIC 1) or 1280x720 at 60 Hz (VIC 4), chosen at build time
- 8 patterns, 8 palettes, 6 effects, controlled by 16 switches
- AXI4-Stream video (AMD UG934) between generator and output, with full backpressure
- HDMI 1.4 transmitter: TMDS video, data islands, TERC4, BCH ECC, AVI and Audio InfoFrames
- 48 kHz stereo audio (a chord per pattern) with exact Audio Clock Regeneration
- EDID read over DDC: automatic HDMI or DVI mode and full or limited RGB range
- VGA top level for Basys 3, Nexys A7 and the EDGE board's VGA port

## Folder layout

| Path | Contents |
|---|---|
| `rtl/` | SystemVerilog design (13 files; `vs_pkg.sv` first) |
| `constraints/` | `edge_artix7_hdmi.xdc` (EDGE pin map, tested on hardware), VGA files for EDGE, Basys 3, Nexys A7 |
| `scripts/` | `create_project.tcl`, `build.tcl` (with reports), `program.tcl`, `stats.tcl` (extra reports), `strategies.tcl` (strategy sweep) |
| `sim/cocotb/` | Reference models (`refmodel.py`), tests, `run.py` |
| `sim/sv/` | Serial-level self-checking testbench and `run_serial.sh` |
| `tools/` | `gen_tables.py`, `ppm2png.py` |
| `preview/` | Frames decoded from the simulated HDMI serial lanes, and the pattern set |

## Quick start (EDGE Artix 7, HDMI)

The EDGE board does not route the HDMI DDC lines to the FPGA, so build with `noedid`.
The design then defaults to HDMI mode. The two DDC ports are parked on unused J11
header pins (M16, N16) and stay tri-stated; leave J11 unconnected.

Command line (one step: project, synthesis, implementation, bitstream, reports):
```
cd C:\path\to\vidsynth
vivado -mode batch -source scripts/build.tcl -tclargs edge noedid      # 640x480
vivado -mode batch -source scripts/build.tcl -tclargs edge720 noedid   # 1280x720
vivado -mode batch -source scripts/program.tcl -tclargs edge720        # program over JTAG
```
If `vivado` is not on the PATH, give the full path to `vivado.bat`.

Or in the Vivado Tcl console:
```
cd C:/path/to/vidsynth
set argv {edge noedid}          ;# or {edge720 noedid}
source scripts/create_project.tcl
```
then Generate Bitstream, Hardware Manager, Program Device.

Optional: Run Behavioral Simulation; expect `HDMI SERIAL CHECK: PASS`.

Switch numbering: `sw[n]` is the board switch labelled SW(n+3). For example `sw[1]` (plasma)
is board SW4, and `sw[15]` (audio) is board SW18. The reset is the centre push button (SW22).

## Controls and indicators

| Switch | Function | LED | Meaning |
|---|---|---|---|
| SW2..0 | Pattern (and audio chord) | LED15 | Heartbeat |
| SW5..3 | Speed | LED14 | EDID read and valid |
| SW8..6 | Palette | LED13 | HDMI mode (off = DVI) |
| SW9 | Invert | LED12 | Sink honours RGB range (QS) |
| SW10 | Kaleidoscope | LED11 | Sink lists 720p |
| SW11 | Posterize | LED10 | Video stream locked |
| SW12 | Freeze | LED9..0 | Mirror SW9..0 |
| SW13 | Zoom x2 | | |
| SW14 | Palette cycling | | |
| SW15 | Audio on | | |
| Button | Reset (picture only) | | |

## Verification

```
pip install -r sim/cocotb/requirements.txt
cd sim/cocotb && python3 run.py          # Verilator + cocotb, all suites
./sim/sv/run_serial.sh 0                 # serial-level testbench, 640x480 (1 for 720p)
```

| Suite | What is checked | Result |
|---|---|---|
| tmds0..2 | Each channel vs reference TMDS/TERC4 encoder, decode round trip, disparity | PASS (about 143,000 characters, max disparity 8) |
| pattern0/1 | Pixel-exact vs NumPy model, 8 frames each, 4 with random backpressure | PASS at 640x480 and 1280x720 |
| hdmi0/1 | Sink-style parser: structure, sync, video, BCH, InfoFrames, ACR, audio samples, DVI mode | PASS |
| edid | I2C slave model: HDMI TV, DVI monitor, no VSDB, bad checksum, no device, clock stretching | PASS (7 tests) |
| Serial | Bit-level decode of the four lanes, frame compare, ECC of every packet | PASS at both resolutions |

All suites were rerun with Verilator 5.020 and cocotb 1.9.2: 22 of 22 tests pass. Totals: 142,770 TMDS
characters against the reference encoder; 16 frames pixel-exact against the NumPy model; 7.9 M HDMI
characters and 5.9 M pixels through the sink parser, with every data island, InfoFrame and audio sample checked.

## Hardware results

Tested on the EDGE Artix 7 (XC7A35T-1FTG256) with a Dell E2422HS monitor.

| | 640x480 at 60 Hz | 1280x720 at 60 Hz |
|---|---|---|
| Pixel clock | 25.0 MHz | 74.22 MHz |
| TMDS rate per lane (configured) | 250 Mb/s | 742 Mb/s |
| Setup slack (WNS) | +30.219 ns | +3.742 ns |
| Hold slack (WHS) | +0.061 ns | +0.072 ns |
| Slice LUTs | 1,424 (6.85%) | 1,564 (7.52%) |
| Flip-flops | 801 (1.93%) | 805 (1.94%) |
| Block RAM / DSP | 5 RAMB18 / 6 | 5 RAMB18 / 6 |
| Estimated on-chip power | 0.316 W | 0.330 W |
| Picture and audio on hardware | yes | yes (monitor reports 1280x720, 60 Hz) |

Power figures are Vivado estimates with default switching activity (confidence: low). At 720p,
0.138 W is I/O and 0.105 W is the MMCM; all logic together is under 0.01 W.

720p timing across implementation strategies (`scripts/strategies.tcl`):

| Strategy | WNS | WHS |
|---|---|---|
| Default | +3.742 ns | +0.072 ns |
| Performance_NetDelay_high | +4.226 ns | +0.072 ns |
| Performance_ExtraTimingOpt | +4.104 ns | +0.087 ns |
| Performance_Explore | +4.052 ns | +0.065 ns |
| Flow_RuntimeOptimized | +3.567 ns | +0.061 ns |
| Area_Explore | +3.346 ns | +0.079 ns |

The 720p critical path runs from `hdmi_tx` to the channel 2 disparity counter: 10 logic levels,
9.50 ns, 63% routing. No congestion above level 5. `report_cdc` finds no unsafe crossings.

Not measured: TMDS signal integrity (no eye diagram) and board power (no meter).
