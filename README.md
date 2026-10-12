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
| `constraints/` | `edge_artix7_hdmi.xdc` (template: fill in pins), VGA files for EDGE, Basys 3, Nexys A7 |
| `scripts/` | `create_project.tcl`, `build.tcl` (with reports), `program.tcl` |
| `sim/cocotb/` | Reference models (`refmodel.py`), tests, `run.py` |
| `sim/sv/` | Serial-level self-checking testbench and `run_serial.sh` |
| `tools/` | `gen_tables.py`, `ppm2png.py` |
| `preview/` | Frames decoded from the simulated HDMI serial lanes, and the pattern set |

## Quick start (EDGE Artix 7, HDMI)

1. Fill in every `XX` in `constraints/edge_artix7_hdmi.xdc` from the kit's pin list.
2. Vivado Tcl console:
   ```
   cd C:/path/to/vidsynth
   set argv {edge}          ;# or {edge720}, add noedid if DDC is not wired: {edge noedid}
   source scripts/create_project.tcl
   ```
3. Optional: Run Behavioral Simulation; expect `HDMI SERIAL CHECK: PASS`.
4. Generate Bitstream, then Hardware Manager, Program Device.
5. SW1, SW3, SW4, SW6, SW15 on: rainbow plasma with sound.

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

Not verified here: real hardware, Vivado timing closure, and the real MMCM/OSERDESE2 models (run step 3 above once to cover the last one).
