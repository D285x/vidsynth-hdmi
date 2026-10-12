"""edid_reader: I2C protocol and EDID parsing against a Python EEPROM (24C02-like) model."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import refmodel as rm


class I2CSlave:
    """Bit-level I2C slave at address 0x50 serving a 256-byte memory."""

    def __init__(self, mem, present=True, stretch=0):
        self.mem, self.present, self.stretch_len = mem, present, stretch
        self.state, self.bit, self.shift, self.drive = "idle", 0, 0, 0
        self.ptr, self.rw, self.ack_m = 0, 0, False
        self.pscl, self.psda = 1, 1
        self.stretch = 0
        self.starts = self.stops = self.bytes_read = 0
        self.violations = 0

    def _data_drive(self):
        return 0 if (self.mem[self.ptr & 0xFF] >> (7 - self.bit)) & 1 else 1

    def step(self, scl_oe, sda_oe):
        if self.stretch:
            self.stretch -= 1
        scl = 0 if (scl_oe or self.stretch) else 1
        sda = 0 if (sda_oe or self.drive) else 1
        rising, falling = scl and not self.pscl, (not scl) and self.pscl
        if scl and self.pscl and self.psda and not sda:          # START or repeated START
            self.state, self.bit, self.shift, self.drive = "addr", 0, 0, 0
            self.starts += 1
        elif scl and self.pscl and not self.psda and sda:        # STOP
            self.state, self.drive = "idle", 0
            self.stops += 1
        elif scl and self.pscl and sda != self.psda and sda_oe != getattr(self, "_psda_oe", sda_oe):
            self.violations += 1                                 # master changed SDA while SCL high
        elif rising:
            if self.state in ("addr", "wdata") and self.bit < 8:
                self.shift = ((self.shift << 1) | sda) & 0xFF
                self.bit += 1
            elif self.state == "read_ack":
                self.ack_m = (sda == 0)
        elif falling:
            if self.state in ("addr", "wdata"):
                if self.bit == 8:
                    if self.state == "addr":
                        ok = self.present and (self.shift >> 1) == 0x50
                        self.rw = self.shift & 1
                    else:
                        ok = True
                    self.drive = 1 if ok else 0
                    self.bit = 9
                    if not ok:
                        self.state = "idle"
                elif self.bit == 9:
                    self.drive = 0
                    self.stretch = self.stretch_len
                    if self.state == "addr" and self.rw:
                        self.state, self.bit = "read", 0
                        self.drive = self._data_drive()
                    elif self.state == "addr":
                        self.state, self.bit, self.shift = "wdata", 0, 0
                    else:
                        self.ptr, self.state = self.shift, "wait"
            elif self.state == "read":
                self.bit += 1
                if self.bit < 8:
                    self.drive = self._data_drive()
                else:
                    self.drive, self.state = 0, "read_ack"
            elif self.state == "read_ack":
                self.bytes_read += 1
                if self.ack_m:
                    self.ptr = (self.ptr + 1) & 0xFF
                    self.state, self.bit = "read", 0
                    self.drive = self._data_drive()
                    self.stretch = self.stretch_len
                else:
                    self.state, self.drive = "idle", 0
        self._psda_oe = sda_oe
        self.pscl, self.psda = scl, (0 if (sda_oe or self.drive) else 1)
        return scl, self.psda


async def run_read(dut, mem, present=True, stretch=0):
    cocotb.start_soon(Clock(dut.clk, 250, units="ns").start())     # 4 MHz
    slave = I2CSlave(mem, present, stretch)
    dut.rst.value = 1
    dut.scl_i.value = 1
    dut.sda_i.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    seen_busy = False
    for cyc in range(400_000):
        await FallingEdge(dut.clk)
        scl, sda = slave.step(int(dut.scl_oe.value), int(dut.sda_oe.value))
        dut.scl_i.value = scl
        dut.sda_i.value = sda
        b = int(dut.busy.value)
        seen_busy |= bool(b)
        if seen_busy and not b:
            break
    for _ in range(5):
        await RisingEdge(dut.clk)
    res = dict(ok=int(dut.edid_ok.value), hdmi=int(dut.is_hdmi.value),
               qs=int(dut.qs.value), p720=int(dut.has_720p.value))
    dut._log.info(f"result {res}; slave saw {slave.starts} START, {slave.stops} STOP, "
                  f"{slave.bytes_read} bytes read, {slave.violations} SDA-while-SCL-high violations")
    assert slave.violations == 0
    return res, slave


@cocotb.test()
async def hdmi_tv_with_qs_and_720p(dut):
    res, s = await run_read(dut, rm.make_edid(hdmi=True, qs=True, vics=(16, 4, 1)))
    assert res == dict(ok=1, hdmi=1, qs=1, p720=1)
    assert s.bytes_read == 256 and s.starts == 2 and s.stops == 1


@cocotb.test()
async def hdmi_tv_without_qs_or_720p(dut):
    res, _ = await run_read(dut, rm.make_edid(hdmi=True, qs=False, vics=(16, 1)))
    assert res == dict(ok=1, hdmi=1, qs=0, p720=0)


@cocotb.test()
async def dvi_monitor(dut):
    res, _ = await run_read(dut, rm.make_edid(cta=False))
    assert res["ok"] == 1 and res["hdmi"] == 0 and res["qs"] == 0


@cocotb.test()
async def cta_block_without_hdmi_vsdb(dut):
    res, _ = await run_read(dut, rm.make_edid(hdmi=False, qs=True, vics=(4,)))
    assert res == dict(ok=1, hdmi=0, qs=1, p720=1)


@cocotb.test()
async def corrupted_checksum(dut):
    res, _ = await run_read(dut, rm.make_edid(corrupt=True))
    assert res["ok"] == 0


@cocotb.test()
async def no_display_connected(dut):
    res, s = await run_read(dut, rm.make_edid(), present=False)
    assert res["ok"] == 0 and s.bytes_read == 0


@cocotb.test()
async def slave_stretches_clock(dut):
    res, _ = await run_read(dut, rm.make_edid(hdmi=True, qs=True, vics=(4,)), stretch=60)
    assert res == dict(ok=1, hdmi=1, qs=1, p720=1)
