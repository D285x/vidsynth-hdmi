"""pattern_axis: pixel-exact comparison with the numpy model, with and without backpressure."""
import os
import random
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
import refmodel as rm

MODE = int(os.environ.get("VS_MODE", "0"))


_clock_started = False


async def reset(dut, sw):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await Timer(1, units="ns")
    dut.rst.value = 1
    dut.sw.value = sw
    dut.m_tready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0


async def capture_frame(dut, h, v, ready_prob, rnd, next_sw=None):
    """Sample on the falling edge (stable values), transfer on the next rising edge."""
    img = np.zeros((v, h, 3), dtype=np.int64)
    n = 0
    stalls = 0
    while n < h * v:
        await FallingEdge(dut.clk)
        ready = 1 if rnd.random() < ready_prob else 0
        dut.m_tready.value = ready
        if int(dut.m_tvalid.value):
            if ready:
                data = int(dut.m_tdata.value)
                y, x = divmod(n, h)
                assert int(dut.m_tuser.value) == (1 if n == 0 else 0), f"tuser wrong at pixel {n}"
                assert int(dut.m_tlast.value) == (1 if x == h - 1 else 0), f"tlast wrong at pixel {n}"
                img[y, x] = ((data >> 16) & 0xFF, data & 0xFF, (data >> 8) & 0xFF)   # R, G, B
                n += 1
                if n == (h * v) // 2 and next_sw is not None:
                    dut.sw.value = next_sw          # sampled when the next frame starts
            else:
                stalls += 1
    await RisingEdge(dut.clk)                       # complete the last transfer
    return img, stalls


async def run_frames(dut, settings, ready_prob, seed):
    m = rm.MODES[MODE]
    h, v = m["h_act"], m["v_act"]
    await reset(dut, settings[0])
    model = rm.PatternModel(MODE)
    rnd = random.Random(seed)
    for f, sw in enumerate(settings):
        nxt = settings[f + 1] if f + 1 < len(settings) else None
        img, stalls = await capture_frame(dut, h, v, ready_prob, rnd, nxt)
        r, g, b = model.frame(sw)
        ref = np.stack([r, g, b], axis=-1)
        bad = np.argwhere(np.any(img != ref, axis=-1))
        assert len(bad) == 0, (f"frame {f} sw={sw:#06x}: {len(bad)} mismatches, first at {bad[0].tolist()}: "
                               f"got {img[tuple(bad[0])].tolist()} expected {ref[tuple(bad[0])].tolist()}")
        dut._log.info(f"frame {f} sw={sw:#06x} matches the model ({h}x{v}, {stalls} stall cycles)")


# switch words: pattern | speed<<3 | palette<<6 | effects
SET_A = [0x0002 | (3 << 3) | (1 << 6),                    # plasma, rainbow
         0x0004 | (5 << 3) | (3 << 6),                    # moire, sunset (moving centres)
         0x0005 | (0 << 6),                               # static noise (LFSR)
         0x0007 | (5 << 6) | (1 << 10) | (1 << 13)]       # domain warp, fire, mirror + zoom
SET_B = [0x0003 | (2 << 6) | (1 << 14),                   # zone plate, ocean, cycling
         0x0006 | (6 << 6) | (1 << 11) | (1 << 9),        # warp checker, acid, posterize, invert
         0x0001 | (4 << 6) | (1 << 12),                   # XOR, neon, freeze
         0x0000 | (7 << 6)]                               # diagonal, CRT green


@cocotb.test(skip=os.environ.get("ONLY_BP") == "1")
async def frames_no_backpressure(dut):
    await run_frames(dut, SET_A, 1.0, 1)


@cocotb.test()
async def frames_random_backpressure(dut):
    await run_frames(dut, SET_B, 0.6, 2)
