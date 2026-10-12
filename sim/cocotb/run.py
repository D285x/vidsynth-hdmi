#!/usr/bin/env python3
"""Build and run the cocotb test suites with Verilator (assertions enabled)."""
import os
import sys
from pathlib import Path
from cocotb.runner import get_runner

HERE = Path(__file__).resolve().parent
RTL = Path(os.environ.get("VS_RTL", HERE.parent.parent / "rtl"))
COMMON = [RTL / "vs_pkg.sv", RTL / "sin_lut.sv"]

SUITES = {
    "tmds0":   dict(top="tmds_channel", srcs=["tmds_channel.sv"], params={"CH": 0}, test="test_tmds"),
    "tmds1":   dict(top="tmds_channel", srcs=["tmds_channel.sv"], params={"CH": 1}, test="test_tmds"),
    "tmds2":   dict(top="tmds_channel", srcs=["tmds_channel.sv"], params={"CH": 2}, test="test_tmds"),
    "pattern0": dict(top="pattern_axis", srcs=["pattern_axis.sv"], params={"MODE": 0}, test="test_pattern", env={"VS_MODE": "0"}),
    "pattern1": dict(top="pattern_axis", srcs=["pattern_axis.sv"], params={"MODE": 1}, test="test_pattern", env={"VS_MODE": "1"}),
    "hdmi0":   dict(top="hdmi_core", srcs=["video_timing.sv", "pattern_axis.sv", "axis_to_video.sv", "audio_gen.sv",
                                           "tmds_channel.sv", "hdmi_tx.sv", HERE / "hdmi_core.sv"],
                    params={"MODE": 0}, test="test_hdmi", env={"VS_MODE": "0"}),
    "hdmi1":   dict(top="hdmi_core", srcs=["video_timing.sv", "pattern_axis.sv", "axis_to_video.sv", "audio_gen.sv",
                                           "tmds_channel.sv", "hdmi_tx.sv", HERE / "hdmi_core.sv"],
                    params={"MODE": 1}, test="test_hdmi", env={"VS_MODE": "1"}),
    "edid":    dict(top="edid_reader", srcs=["edid_reader.sv"],
                    params={"CLK_HZ": 4_000_000, "REFRESH_CYCLES": 2000}, test="test_edid"),
}


def run(name):
    s = SUITES[name]
    srcs = COMMON + [p if isinstance(p, Path) else RTL / p for p in s["srcs"]]
    runner = get_runner("verilator")
    build_dir = HERE / "build" / name
    runner.build(sources=[str(p) for p in srcs], hdl_toplevel=s["top"], parameters=s["params"],
                 build_args=["--assert", "-Wno-fatal", "-Wno-WIDTH", "--x-initial", "unique"],
                 build_dir=str(build_dir), always=True)
    os.environ.update(s.get("env", {}))
    os.environ["PYTHONPATH"] = str(HERE) + os.pathsep + os.environ.get("PYTHONPATH", "")
    res = runner.test(hdl_toplevel=s["top"], test_module=s["test"], build_dir=str(build_dir),
                      test_dir=str(HERE), extra_env=s.get("env", {}))
    return res


if __name__ == "__main__":
    for n in (sys.argv[1:] or list(SUITES)):
        print(f"===== suite {n} =====", flush=True)
        run(n)
