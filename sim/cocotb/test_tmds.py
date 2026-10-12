"""Unit test: tmds_channel against the reference TMDS / TERC4 / guard-band model."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
import refmodel as rm

TM_CTRL, TM_VIDEO, TM_TERC4, TM_VGUARD, TM_DGUARD = range(5)


@cocotb.test()
async def tmds_channel_matches_reference(dut):
    ch = int(dut.CH.value)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.mode.value = TM_CTRL
    dut.d.value = 0; dut.c.value = 0; dut.t4.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    rnd = random.Random(1234 + ch)
    cnt = 0
    max_disp = 0
    checked = 0
    expected = None
    for run in range(400):
        mode = rnd.choices([TM_VIDEO, TM_CTRL, TM_TERC4, TM_VGUARD, TM_DGUARD], [6, 2, 2, 1, 1])[0]
        length = rnd.randint(50, 400) if mode == TM_VIDEO else rnd.randint(1, 20)
        for _ in range(length):
            d = rnd.choice([rnd.randrange(256), 0x00, 0xFF, 0x80, 0x10])
            c = rnd.randrange(4); t4 = rnd.randrange(16)
            dut.mode.value = mode; dut.d.value = d; dut.c.value = c; dut.t4.value = t4
            # expected output after this edge
            if mode == TM_VIDEO:
                exp, cnt = rm.tmds_encode(d, cnt)
                max_disp = max(max_disp, abs(cnt))
            else:
                cnt = 0
                if mode == TM_CTRL:
                    exp = rm.CTRL_TOKENS[c]
                elif mode == TM_TERC4:
                    exp = rm.TERC4[t4]
                elif mode == TM_VGUARD:
                    exp = rm.VGUARD[ch]
                else:
                    exp = rm.DGUARD12
            await RisingEdge(dut.clk)
            await ReadOnly()
            q = int(dut.q.value)
            assert q == exp, f"ch{ch} mode {mode} d={d:#x}: got {q:010b} expected {exp:010b}"
            if mode == TM_VIDEO:
                assert rm.tmds_decode(q) == d
                assert rm.transitions(q) <= 5
            checked += 1
            await cocotb.triggers.Timer(1, units="ns")
    dut._log.info(f"channel {ch}: {checked} characters checked, max |disparity| = {max_disp}")
    assert max_disp <= 16
