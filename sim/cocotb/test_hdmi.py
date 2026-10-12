"""
test_hdmi.py - protocol-level verification of the HDMI transmitter.

The testbench records the three TMDS character streams and the video that
enters the transmitter, then parses the streams the way an HDMI sink does
(control periods, preambles, guard bands, video periods, data islands) and
checks every rule and every value against the reference models:
  * video: every active pixel decodes to the transmitter's input (2-clock latency)
  * sync : HSYNC/VSYNC carried in control and TERC4 characters
  * structure: preamble length 8, guard bands 2, control periods >= 12
  * islands: TERC4 validity, first-character flag, BCH ECC of every block
  * packets: InfoFrame checksums and fields, ACR N/CTS, audio samples, parity,
             channel status and block-start flags against the DDS model
"""
import os
import collections
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
import refmodel as rm

MODE = int(os.environ.get("VS_MODE", "0"))
M = rm.MODES[MODE]


async def record(dut, cycles, sw, hdmi, qs, lim):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.sw.value = sw
    dut.cfg_hdmi.value = hdmi
    dut.cfg_qs.value = qs
    dut.cfg_limited.value = lim
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    w = np.zeros((cycles, 3), dtype=np.int64)
    ref = np.zeros((cycles, 6), dtype=np.int64)     # r, g, b, de, hs, vs
    na = 0
    for i in range(cycles):
        await FallingEdge(dut.clk)
        w[i] = (int(dut.tmds0.value), int(dut.tmds1.value), int(dut.tmds2.value))
        ref[i] = (int(dut.v_r.value), int(dut.v_g.value), int(dut.v_b.value),
                  int(dut.v_de.value), int(dut.v_hs.value), int(dut.v_vs.value))
        na += int(dut.a_valid.value)
    return w, ref, na


class SinkParser:
    """Parses TMDS character streams like an HDMI sink and checks the rules."""

    def __init__(self, w, hdmi):
        self.w, self.hdmi = w, hdmi
        self.n = len(w)
        self.video = np.zeros(self.n, dtype=bool)
        self.vguard = np.zeros(self.n, dtype=bool)
        self.pix = np.zeros((self.n, 3), dtype=np.int64)
        self.packets = []           # (index, header bytes, 4 subpacket byte lists)
        self.errors = collections.Counter()
        self.stats = collections.Counter()

    def is_ctrl(self, i):
        return all(int(x) in rm.CTRL_DECODE for x in self.w[i])

    def err(self, what):
        self.errors[what] += 1

    def parse(self):
        w = self.w
        # start after the first complete line (the stream begins mid-frame after reset)
        i = 0
        while i < self.n and not self.is_ctrl(i):
            i += 1
        while i < self.n and self.is_ctrl(i):
            i += 1
        while i < self.n and not self.is_ctrl(i):
            i += 1
        self.start = i
        while i < self.n - 40:
            start = i
            while i < self.n and self.is_ctrl(i):
                i += 1
            if i >= self.n - 40:
                break
            ctrl_len = i - start
            pre = [(rm.CTRL_DECODE[int(w[k][1])], rm.CTRL_DECODE[int(w[k][2])]) for k in range(max(start, i - 8), i)]
            c0, c1, c2 = (int(x) for x in w[i])
            if not self.hdmi:                                   # DVI: video follows control directly
                if any(p != (0, 0) for p in pre):
                    self.err("DVI: non-zero CTL bits")
                self.stats["video_periods"] += 1
                i = self.video_period(i)
                continue
            if ctrl_len < 12:
                self.err("control period shorter than 12")
            if (c0, c1, c2) == rm.VGUARD:
                if len(pre) != 8 or any(p != (1, 0) for p in pre):
                    self.err("video preamble not 8 x (CTL0=1)")
                if tuple(int(x) for x in w[i + 1]) != rm.VGUARD:
                    self.err("video guard band not 2 characters")
                self.stats["video_periods"] += 1
                self.vguard[i:i + 2] = True
                i = self.video_period(i + 2)
            elif c1 == rm.DGUARD12 and c2 == rm.DGUARD12 and c0 in rm.TERC4_DECODE and (rm.TERC4_DECODE[c0] >> 2) == 3:
                if len(pre) != 8 or any(p != (1, 1) for p in pre):
                    self.err("island preamble not 8 x (CTL0=1, CTL2=1)")
                i = self.data_island(i)
            else:
                self.err("unexpected character after control period")
                i += 1

    def video_period(self, i):
        start = i
        while i < self.n and not self.is_ctrl(i):
            q = [int(x) for x in self.w[i]]
            if any(rm.transitions(x) > 5 for x in q):
                self.err("video character with >5 transitions")
            self.video[i] = True
            self.pix[i] = (rm.tmds_decode(q[2]), rm.tmds_decode(q[1]), rm.tmds_decode(q[0]))   # R, G, B
            i += 1
        if i - start != M["h_act"] and i < self.n:
            self.err(f"video period length {i - start}")
        return i

    def data_island(self, i):
        w = self.w
        for k in (0, 1):                                       # leading guard band
            if not (int(w[i + k][1]) == rm.DGUARD12 and int(w[i + k][2]) == rm.DGUARD12):
                self.err("leading guard band")
        i += 2
        first = True
        npk = 0
        while i + 34 < self.n and not (int(w[i][1]) == rm.DGUARD12 and int(w[i][2]) == rm.DGUARD12):
            hdr_bits, sub_bits = [], [[0] * 64 for _ in range(4)]
            for c in range(32):
                t = [rm.TERC4_DECODE.get(int(x)) for x in w[i + c]]
                if None in t:
                    self.err("invalid TERC4 character")
                    t = [0 if v is None else v for v in t]
                flag = (t[0] >> 3) & 1
                if flag != (0 if (first and c == 0) else 1):
                    self.err("channel 0 bit 3 (first character flag)")
                hdr_bits.append((t[0] >> 2) & 1)
                for s in range(4):
                    sub_bits[s][2 * c] = (t[1] >> s) & 1
                    sub_bits[s][2 * c + 1] = (t[2] >> s) & 1
            first = False
            if rm.bch_syndrome(hdr_bits) != 0:
                self.err("header BCH")
            for s in range(4):
                if rm.bch_syndrome(sub_bits[s]) != 0:
                    self.err("subpacket BCH")
            hb = [rm.from_bits(hdr_bits[8 * b: 8 * b + 8]) for b in range(3)]
            sb = [[rm.from_bits(sub_bits[s][8 * b: 8 * b + 8]) for b in range(7)] for s in range(4)]
            self.packets.append((i, hb, sb))
            npk += 1
            i += 32
            if npk > 18:
                self.err("more than 18 packets")
                break
        if i + 34 >= self.n:
            return self.n
        for k in (0, 1):                                       # trailing guard band
            if not (int(w[i + k][1]) == rm.DGUARD12 and int(w[i + k][2]) == rm.DGUARD12):
                self.err("trailing guard band")
        self.stats["islands"] += 1
        self.stats[f"islands_with_{npk}_packets"] += 1
        return i + 2


def check_packets(dut, packets, sw, qs, total_samples_expected, hdmi=1):
    err = collections.Counter()
    types = collections.Counter()
    samples = []
    for (_, hb, sb) in packets:
        t = hb[0]
        types[t] += 1
        if t == 0x00:
            if any(hb) or any(any(s) for s in sb):
                err["null packet not all zero"] += 1
        elif t == 0x01:
            for s in sb:
                cts = ((s[1] & 0xF) << 16) | (s[2] << 8) | s[3]
                n = ((s[4] & 0xF) << 16) | (s[5] << 8) | s[6]
                if (cts, n) != (M["cts"], rm.ACR_N):
                    err[f"ACR N/CTS {n}/{cts}"] += 1
        elif t in (0x82, 0x84):
            length = hb[2]
            pb = sb[0] + sb[1] + sb[2] + sb[3]
            if (sum(hb) + sum(pb[:length + 1])) % 256 != 0:
                err["InfoFrame checksum"] += 1
            if t == 0x82:
                exp = [0x10, 0x28 if M["wide"] else 0x18, 0x08 if qs else 0x00, M["vic"]]
                if hb[1:] != [0x02, 0x0D] or pb[1:5] != exp or any(pb[5:14]):
                    err[f"AVI fields {hb} {pb[:14]}"] += 1
            else:
                if hb[1:] != [0x01, 0x0A] or pb[1:11] != [0x01] + [0] * 9:
                    err["Audio InfoFrame fields"] += 1
        elif t == 0x02:
            sp, layout, bflags, flat = hb[1] & 0xF, (hb[1] >> 4) & 1, hb[2] & 0xF, hb[2] >> 4
            if layout or flat or sp not in (1, 3, 7, 15):
                err["audio header"] += 1
            for k in range(4):
                if not (sp >> k) & 1:
                    continue
                s = sb[k]
                l = s[0] | (s[1] << 8) | (s[2] << 16)
                r = s[3] | (s[4] << 8) | (s[5] << 16)
                f = s[6]
                vl, ul, cl, pl = f & 1, (f >> 1) & 1, (f >> 2) & 1, (f >> 3) & 1
                vr, ur, cr, pr = (f >> 4) & 1, (f >> 5) & 1, (f >> 6) & 1, (f >> 7) & 1
                if (bin(l).count("1") + vl + ul + cl + pl) % 2 or (bin(r).count("1") + vr + ur + cr + pr) % 2:
                    err["audio parity"] += 1
                if vl or ul or vr or ur:
                    err["V/U bits"] += 1
                samples.append((l, r, cl, cr, (bflags >> k) & 1))
        else:
            err[f"unexpected packet type {t:#x}"] += 1

    # compare the audio stream with the DDS model
    if (sw >> 15 & 1) and hdmi:
        exp = rm.audio_samples(sw & 7, len(samples))
        for k, ((l, r, cl, cr, b), (el, er, idx)) in enumerate(zip(samples, exp)):
            if l != ((el << 8) & 0xFFFFFF) or r != ((er << 8) & 0xFFFFFF):
                err["audio sample value"] += 1
            if cl != (1 if idx == 25 else 0) or cr != cl:
                err["channel status bit"] += 1
            if b != (1 if idx == 0 else 0):
                err["block start flag"] += 1
        if abs(total_samples_expected - len(samples)) > 8:
            err[f"sample count {len(samples)} vs produced {total_samples_expected}"] += 1
    elif samples:
        err["audio sent while disabled"] += 1
    return err, types, len(samples)


async def run_case(dut, frames, sw, hdmi, qs, lim, name):
    cycles = int(frames * M["h_tot"] * M["v_tot"]) + 3000
    w, ref, na = await record(dut, cycles, sw, hdmi, qs, lim)
    p = SinkParser(w, hdmi)
    p.parse()
    errs = collections.Counter(p.errors)

    # video: every active input pixel appears 2 clocks later, decoded
    de = ref[:, 3].astype(bool)
    rgb = ref[:, 0:3]
    if lim:
        rgb = rm.to_limited(rgb)
    first = p.start
    idx = np.nonzero(de[: cycles - 2])[0]
    idx = idx[idx + 2 >= first]
    if not np.all(p.video[idx + 2]):
        errs["active pixel not sent as video"] += int(np.sum(~p.video[idx + 2]))
    bad = np.any(p.pix[idx + 2] != rgb[idx], axis=1)
    errs["pixel value mismatch"] += int(np.sum(bad))
    vid_idx = np.nonzero(p.video)[0]
    errs["video character without active pixel"] += int(np.sum(~de[vid_idx - 2]))

    # sync: HSYNC/VSYNC in control and TERC4 characters on channel 0
    sync_bad = 0
    for i in range(first, cycles):
        c0 = int(w[i][0])
        if c0 in rm.CTRL_DECODE:
            hv = rm.CTRL_DECODE[c0]
        elif c0 in rm.TERC4_DECODE and not p.video[i] and not p.vguard[i]:
            hv = rm.TERC4_DECODE[c0] & 3
        else:
            continue
        if hv != (ref[i - 2][4] | (ref[i - 2][5] << 1)):
            sync_bad += 1
    errs["sync mismatch"] += sync_bad

    perr, types, nsamp = check_packets(dut, p.packets, sw, qs, na, hdmi)
    errs.update(perr)
    errs = {k: v for k, v in errs.items() if v}
    dut._log.info(f"[{name}] {cycles} characters, {int(p.video.sum())} video pixels checked, "
                  f"{p.stats['islands']} islands, packets by type {dict(types)}, "
                  f"{nsamp} audio samples (produced {na})")
    dut._log.info(f"[{name}] structure: {dict(p.stats)}")
    assert not errs, f"[{name}] errors: {errs}"


@cocotb.test()
async def hdmi_audio_and_infoframes(dut):
    """HDMI mode, audio on, sink without QS."""
    sw = (1 << 15) | (3 << 3) | (1 << 6) | 2         # plasma, rainbow, audio on
    await run_case(dut, 2.2 if MODE == 0 else 1.2, sw, 1, 0, 1 if MODE == 1 else 0, "hdmi")


@cocotb.test()
async def hdmi_full_range_declared(dut):
    """HDMI mode, sink with QS: Q = full in the AVI InfoFrame, no range scaling."""
    sw = (1 << 15) | (4 << 6) | 4                    # moire, neon, audio on
    await run_case(dut, 1.1, sw, 1, 1, 0, "hdmi-qs")


@cocotb.test()
async def hdmi_audio_off(dut):
    """Audio switch off: no Audio Sample packets, ACR and InfoFrames continue."""
    sw = (2 << 6) | 3
    await run_case(dut, 1.1, sw, 1, 0, 0, "audio-off")


@cocotb.test()
async def dvi_mode(dut):
    """DVI sink: video and control tokens only."""
    sw = (1 << 15) | (6 << 6) | 7
    await run_case(dut, 1.1, sw, 0, 0, 0, "dvi")
