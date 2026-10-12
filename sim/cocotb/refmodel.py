"""
refmodel.py - independent Python reference models for vidsynth verification.

Written from the standards (DVI 1.0, HDMI 1.4, CTA-861, IEC 60958), not from
the RTL, so that the testbenches compare two separate implementations.
"""
import math
import numpy as np

# --------------------------------------------------------------------- modes
MODES = {
    0: dict(h_act=640, h_fp=16, h_sync=96, h_bp=48, v_act=480, v_fp=10, v_sync=2, v_bp=33,
            pos=False, vic=1, wide=False, shift=0, cts=25000, f_pix=25_000_000),
    1: dict(h_act=1280, h_fp=110, h_sync=40, h_bp=220, v_act=720, v_fp=5, v_sync=5, v_bp=20,
            pos=True, vic=4, wide=True, shift=1, cts=74219, f_pix=74_218_750),
}
for m in MODES.values():
    m["h_tot"] = m["h_act"] + m["h_fp"] + m["h_sync"] + m["h_bp"]
    m["v_tot"] = m["v_act"] + m["v_fp"] + m["v_sync"] + m["v_bp"]
ACR_N = 6144

# ---------------------------------------------------------------- TMDS 8b10b
CTRL_TOKENS = {0b00: 0b1101010100, 0b01: 0b0010101011, 0b10: 0b0101010100, 0b11: 0b1010101011}
CTRL_DECODE = {v: k for k, v in CTRL_TOKENS.items()}


def tmds_encode(d, cnt):
    """DVI 1.0 TMDS encoder. Returns (10-bit word, new running disparity)."""
    bits = [(d >> i) & 1 for i in range(8)]
    n1 = sum(bits)
    xnor = n1 > 4 or (n1 == 4 and bits[0] == 0)
    qm = [bits[0]]
    for i in range(1, 8):
        v = qm[i - 1] ^ bits[i]
        qm.append(1 - v if xnor else v)
    qm.append(0 if xnor else 1)
    n1q = sum(qm[:8])
    n0q = 8 - n1q
    if cnt == 0 or n1q == n0q:
        q9 = 1 - qm[8]
        low = qm[:8] if qm[8] else [1 - b for b in qm[:8]]
        cnt += (n1q - n0q) if qm[8] else (n0q - n1q)
    elif (cnt > 0 and n1q > n0q) or (cnt < 0 and n0q > n1q):
        q9 = 1
        low = [1 - b for b in qm[:8]]
        cnt += 2 * qm[8] + (n0q - n1q)
    else:
        q9 = 0
        low = qm[:8]
        cnt += -2 * (1 - qm[8]) + (n1q - n0q)
    word = sum(b << i for i, b in enumerate(low)) | (qm[8] << 8) | (q9 << 9)
    return word, cnt


def tmds_decode(q):
    x = q & 0xFF
    if (q >> 9) & 1:
        x ^= 0xFF
    xb = [(x >> i) & 1 for i in range(8)]
    d = [xb[0]]
    for i in range(1, 8):
        v = xb[i] ^ xb[i - 1]
        d.append(v if (q >> 8) & 1 else 1 - v)
    return sum(b << i for i, b in enumerate(d))


def transitions(word, n=10):
    return sum(1 for i in range(n - 1) if ((word >> i) & 1) != ((word >> (i + 1)) & 1))


# -------------------------------------------------------------------- TERC4
TERC4 = [0b1010011100, 0b1001100011, 0b1011100100, 0b1011100010,
         0b0101110001, 0b0100011110, 0b0110001110, 0b0100111100,
         0b1011001100, 0b0100111001, 0b0110011100, 0b1011000110,
         0b1010001110, 0b1001110001, 0b0101100011, 0b1011000011]
TERC4_DECODE = {v: i for i, v in enumerate(TERC4)}
VGUARD = (0b1011001100, 0b0100110011, 0b1011001100)   # channels 0, 1, 2
DGUARD12 = 0b0100110011

# ----------------------------------------------------------- BCH (HDMI ECC)
# g(x) = x^8 + x^7 + x^6 + 1. A block c_0..c_{n-1} (c_0 transmitted first)
# is the polynomial sum c_i x^(n-1-i); valid codewords are multiples of g(x).
G_POLY = (1 << 8) | (1 << 7) | (1 << 6) | 1


def _polymod(p):
    while p.bit_length() >= 9:
        p ^= G_POLY << (p.bit_length() - 9)
    return p


def bch_parity(msg_bits):
    """Parity bits (8, in transmission order) for message bits (transmission order)."""
    n = len(msg_bits) + 8
    p = 0
    for i, b in enumerate(msg_bits):
        p |= b << (n - 1 - i)
    r = _polymod(p)                     # remainder of x^8 m(x) / g(x)
    return [(r >> (7 - j)) & 1 for j in range(8)]


def bch_syndrome(code_bits):
    n = len(code_bits)
    return _polymod(sum(b << (n - 1 - i) for i, b in enumerate(code_bits)))


def bits_le(value, n):
    return [(value >> i) & 1 for i in range(n)]


def from_bits(bits):
    return sum(b << i for i, b in enumerate(bits))


# ------------------------------------------------------------ pattern model
_SIN = np.array([max(0, min(255, int(round(127.5 + 127.5 * math.sin(2 * math.pi * i / 256)))))
                 for i in range(256)], dtype=np.int64)


def sin_lut(a):
    return _SIN[np.asarray(a, dtype=np.int64) & 0xFF]


def lfsr_seq(start_state, count):
    """Galois LFSR x^16 + x^14 + x^13 + x^11 + 1 (mask 0xB400), right shifting."""
    out = np.zeros(count, dtype=np.int64)
    s = start_state
    for i in range(count):
        out[i] = s
        s = (s >> 1) ^ (0xB400 if s & 1 else 0)
    return out, s


class PatternModel:
    """Frame-by-frame model of pattern_axis. Call frame(sw) once per frame, in order."""

    def __init__(self, mode=0):
        self.m = MODES[mode]
        self.t = 0
        self.vw = self.m["h_act"] >> self.m["shift"]
        self.vh = self.m["v_act"] >> self.m["shift"]
        self.cx, self.cy = self.vw // 2, self.vh // 2
        self.lfsr = 0xACE1
        self.adv = 0              # pipeline advances so far (= pixels issued)
        self.first = True

    def frame(self, sw):
        m = self.m
        H, V = m["h_act"], m["v_act"]
        # per-frame state update (at the first pixel of the frame)
        tf = self.t
        tf8 = tf & 0xFF
        tf15 = (tf8 + ((tf >> 1) & 0xFF)) & 0xFF
        l1, l2 = int(sin_lut(tf8)), int(sin_lut(tf8 + 64))
        l3, l4 = int(sin_lut(tf15)), int(sin_lut(tf15 + 100))
        c1x, c1y = self.cx - 128 + l1, self.cy - 64 + (l2 >> 1)
        c2x, c2y = self.cx + 128 - l3, self.cy + 64 - (l4 >> 1)
        speed, freeze = (sw >> 3) & 7, (sw >> 12) & 1
        t = tf if freeze else (tf + speed + 1) & 0xFFFF
        self.t = t

        mode, pal = sw & 7, (sw >> 6) & 7
        invert, mirror, poster = (sw >> 9) & 1, (sw >> 10) & 1, (sw >> 11) & 1
        zoom, cycle = (sw >> 13) & 1, (sw >> 14) & 1

        y, x = np.mgrid[0:V, 0:H].astype(np.int64)
        xv, yv = x >> m["shift"], y >> m["shift"]
        if mirror:
            xv = np.where(xv >= self.cx, self.vw - 1 - xv, xv)
            yv = np.where(yv >= self.cy, self.vh - 1 - yv, yv)
        if zoom:
            xs = (xv >> 1) + self.cx // 2
            ys = (yv >> 1) + self.cy // 2
        else:
            xs, ys = xv, yv
        xs &= 0x3FF
        ys &= 0x3FF

        t8 = t & 0xFF
        t15 = (t8 + ((t >> 1) & 0xFF)) & 0xFF
        s0 = sin_lut(((xs >> 1) & 0xFF) + t8)
        s1 = sin_lut(((ys >> 1) & 0xFF) - t15)
        s2 = sin_lut((((xs + ys) & 0x3FF) >> 2) + (t8 >> 1))
        s3 = sin_lut((ys & 0xFF) + ((t8 << 1) & 0xFF))
        d = (xs - self.cx) ** 2 + (ys - self.cy) ** 2
        m1 = (xs - c1x) ** 2 + (ys - c1y) ** 2
        m2 = (xs - c2x) ** 2 + (ys - c2y) ** 2

        # LFSR value seen by each pixel: pixel p of the run sees state after p+2 advances
        n = H * V
        need = self.adv + n + 2
        if not hasattr(self, "_lf") or len(self._lf) < need:
            self._lf, _ = lfsr_seq(0xACE1, need + H * V)
        lf = self._lf[self.adv + 2: self.adv + 2 + n].reshape(V, H)
        self.adv += n

        if mode == 0:
            v = ((xs >> 1) & 0xFF) + ((ys >> 1) & 0xFF) + t8
        elif mode == 1:
            v = (((xs >> 1) & 0xFF) ^ ((ys >> 1) & 0xFF)) + t8
        elif mode == 2:
            v = ((s0 + s1 + s2 + s3) & 0x3FF) >> 2
        elif mode == 3:
            v = ((d >> 5) & 0xFF) - ((t8 << 1) & 0xFF)
        elif mode == 4:
            v = np.where(((m1 >> 11) ^ (m2 >> 11)) & 1, 0xD0 + (t8 >> 1), 0x30 + (t8 >> 1))
        elif mode == 5:
            v = lf & 0xFF
        elif mode == 6:
            wx = (xs + (s3 >> 3)) & 0x3FF
            wy = (ys + (s0 >> 3)) & 0x3FF
            v = np.where(((wx >> 5) ^ (wy >> 5)) & 1, 0xC0 + t8, 0x40 + t8)
        else:
            v = sin_lut(((xs >> 1) & 0xFF) + s3)
        v = v & 0xFF
        if cycle:
            v = (v + t8) & 0xFF

        v2x, v3x = (v << 1) & 0xFF, (v + (v << 1)) & 0xFF
        phases = {1: (v, v + 85, v + 171), 2: (v + 128, v + 200, v + 20), 3: (v, v + 36, v + 96),
                  4: (v2x, v2x + 85, v2x + 171), 6: (v3x, v3x + 128, v3x + 64)}
        ir, ig, ib = phases.get(pal, (v, v, v))
        lr, lg, lb = sin_lut(ir), sin_lut(ig), sin_lut(ib)
        if pal == 0:
            r, g, b = v, v, v
        elif pal == 2:
            r, g, b = lr >> 2, lg, lb | 0x40
        elif pal == 3:
            r, g, b = lr | 0x30, lg >> 1, lb >> 1
        elif pal == 5:
            r = np.where(v & 0x80, 0xFF, (v << 1) & 0xFF)
            g = np.where(v & 0x80, (v << 1) & 0xFF, 0)
            b = np.where(v >= 224, (v & 0x1F) << 3, 0)
        elif pal == 7:
            r, g, b = v >> 3, v, v >> 2
        else:
            r, g, b = lr, lg, lb
        r, g, b = [np.asarray(c, dtype=np.int64) & 0xFF for c in (r, g, b)]
        if poster:
            r, g, b = [((c >> 6) * 0x55) for c in (r, g, b)]
        if invert:
            r, g, b = [c ^ 0xFF for c in (r, g, b)]
        return r, g, b


def to_limited(v):
    return 16 + ((np.asarray(v, dtype=np.int64) * 220) >> 8)


# ------------------------------------------------------------- audio model
NOTE_INC = [(91446, 137169), (102642, 153962), (115214, 172821), (137014, 205521),
            (153791, 230687), (182889, 274334), (205287, 307930), (230425, 345637)]


def audio_samples(note, count):
    """Expected (left, right, frame index) for the first `count` samples."""
    il, ir = NOTE_INC[note]
    pl = pr = 0
    out = []
    for k in range(count):
        l = (int(_SIN[(pl >> 16) & 0xFF]) - 128) * 64
        r = (int(_SIN[(pr >> 16) & 0xFF]) - 128) * 64
        out.append((l, r, k % 192))
        pl = (pl + il) & 0xFFFFFF
        pr = (pr + ir) & 0xFFFFFF
    return out


def sample_ticks(mode, clocks):
    """Number of samples produced by the exact rational divider in `clocks` cycles."""
    mod = 128 * MODES[mode]["cts"]
    return (clocks * ACR_N) // mod


# --------------------------------------------------------------- EDID builder
def edid_checksum(block):
    block[127] = (256 - sum(block[:127]) % 256) % 256
    return block


def make_edid(hdmi=True, qs=True, vics=(16, 4, 1), cta=True, corrupt=False):
    b0 = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] + [0] * 120
    b0[8:10] = [0x4C, 0x2D]          # manufacturer 'SAM'-like id
    b0[18:20] = [1, 3]
    b0[20] = 0x80                    # digital input
    b0[35] = 0x20                    # established timing: 640x480 at 60 Hz
    b0[126] = 1 if cta else 0
    edid_checksum(b0)
    blocks = b0
    if cta:
        dbc = []
        dbc += [(2 << 5) | len(vics)] + list(vics)                       # video data block
        if hdmi:
            dbc += [(3 << 5) | 5, 0x03, 0x0C, 0x00, 0x10, 0x00]          # HDMI VSDB, phys addr 1.0.0.0
        dbc += [(7 << 5) | 2, 0x00, 0x40 if qs else 0x00]                # VCDB
        d = 4 + len(dbc)
        b1 = [0x02, 0x03, d, 0x70] + dbc
        b1 += [0] * (128 - len(b1))
        edid_checksum(b1)
        blocks = b0 + b1
    else:
        blocks = b0 + b0             # a 128-byte EEPROM wraps around
    if corrupt:
        blocks[50] ^= 0x01
    return blocks
