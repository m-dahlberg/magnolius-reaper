"""Pure-Python reference implementation of "Magnolius_LoudnessSimulator.jsfx".

Mirrors @init/@slider/@sample sample-for-sample so render_test.py can compare a
real REAPER render against it instead of against hand-derived expectations.
Keep this in lockstep with the .jsfx file - if one changes, the other must.
"""
import math

# ---- fixed design constants (must match @init in the .jsfx) ----
LOW_F = 200.0        # contour low-shelf corner
HIGH_F = 6500.0      # contour high-shelf corner
LOW_MAX = 10.0       # contour low-shelf dB at slider1 = 100
HIGH_MAX = 4.0       # contour high-shelf dB at slider1 = 100
DET_LO_F = 250.0     # detector band split, low
DET_HI_F = 5000.0    # detector band split, high
GATE_DB = -70.0      # below this the lift tapers away (hiss stays put)
GATE_W = 6.0
RMS_MS = 30.0
ATK_L, REL_L = 40.0, 200.0   # low-band ballistics (ms)
ATK_H, REL_H = 15.0, 120.0   # high-band ballistics (ms)
REFRESH = 32         # shelf coefficients recomputed every N samples
TINY = 10.0 ** -20


def _norm(b0, b1, b2, a0, a1, a2):
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def low_shelf(f, g, sr):
    f = min(f, sr * 0.45)
    A = 10.0 ** (g / 40.0)
    w = 2 * math.pi * f / sr
    cw, sw = math.cos(w), math.sin(w)
    al = sw * 0.5 * math.sqrt(2.0)
    s2 = 2 * math.sqrt(A) * al
    return _norm(A * ((A + 1) - (A - 1) * cw + s2),
                 2 * A * ((A - 1) - (A + 1) * cw),
                 A * ((A + 1) - (A - 1) * cw - s2),
                 (A + 1) + (A - 1) * cw + s2,
                 -2 * ((A - 1) + (A + 1) * cw),
                 (A + 1) + (A - 1) * cw - s2)


def high_shelf(f, g, sr):
    f = min(f, sr * 0.45)
    A = 10.0 ** (g / 40.0)
    w = 2 * math.pi * f / sr
    cw, sw = math.cos(w), math.sin(w)
    al = sw * 0.5 * math.sqrt(2.0)
    s2 = 2 * math.sqrt(A) * al
    return _norm(A * ((A + 1) + (A - 1) * cw + s2),
                 -2 * A * ((A - 1) + (A + 1) * cw),
                 A * ((A + 1) + (A - 1) * cw - s2),
                 (A + 1) - (A - 1) * cw + s2,
                 2 * ((A - 1) - (A + 1) * cw),
                 (A + 1) - (A - 1) * cw - s2)


def lpf(f, sr):
    f = min(f, sr * 0.45)
    w = 2 * math.pi * f / sr
    cw, sw = math.cos(w), math.sin(w)
    al = sw / (2 * 0.7071)
    return _norm((1 - cw) * 0.5, 1 - cw, (1 - cw) * 0.5, 1 + al, -2 * cw, 1 - al)


def hpf(f, sr):
    f = min(f, sr * 0.45)
    w = 2 * math.pi * f / sr
    cw, sw = math.cos(w), math.sin(w)
    al = sw / (2 * 0.7071)
    return _norm((1 + cw) * 0.5, -(1 + cw), (1 + cw) * 0.5, 1 + al, -2 * cw, 1 - al)


def tcoef(ms, sr):
    return math.exp(-1.0 / (max(ms, 0.01) * 0.001 * sr))


def bq_response(c, f, sr):
    """Complex response of a normalised biquad at f."""
    w = 2 * math.pi * f / sr
    z = complex(math.cos(-w), math.sin(-w))
    return (c[0] + c[1] * z + c[2] * z * z) / (1 + c[3] * z + c[4] * z * z)


class Biquad:
    """Direct Form I, same state layout and update order as bq() in the .jsfx."""

    __slots__ = ("c", "x1", "x2", "y1", "y2")

    def __init__(self, c):
        self.c = c
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def __call__(self, x):
        c = self.c
        o = (c[0] * x + c[1] * self.x1 + c[2] * self.x2
             - c[3] * self.y1 - c[4] * self.y2)
        self.x2 = self.x1
        self.x1 = x
        self.y2 = self.y1
        self.y1 = o
        return o


def bs2b_coefs(fcut, feed_db, sr):
    """libbs2b init(), verbatim. feed_db in dB (libbs2b's valid range 1..15)."""
    fd = min(max(feed_db, 1.0), 15.0)
    gb_lo = fd * (-5.0 / 6.0) - 3.0
    gb_hi = fd / 6.0 - 3.0
    g_lo = 10.0 ** (gb_lo / 20.0)
    g_hi = 1.0 - 10.0 ** (gb_hi / 20.0)
    fc_hi = min(fcut * 2.0 ** ((gb_lo - 20.0 * math.log10(g_hi)) / 12.0),
                sr * 0.45)
    x = math.exp(-2.0 * math.pi * min(fcut, sr * 0.45) / sr)
    b1_lo, a0_lo = x, g_lo * (1.0 - x)
    x = math.exp(-2.0 * math.pi * fc_hi / sr)
    b1_hi, a0_hi, a1_hi = x, 1.0 - g_hi * (1.0 - x), -x
    gain = 1.0 / (1.0 - g_hi + g_lo)
    return a0_lo, b1_lo, a0_hi, a1_hi, b1_hi, gain


class LoudnessSim:
    """One instance == one FX instance. process() consumes/returns stereo."""

    # Defaults are the NEUTRAL settings, not the plugin's slider defaults -
    # render_test.DEFAULTS is the single source of truth for what a test runs.
    def __init__(self, sr=48000.0, loudness=0.0, makeup_db=0.0,
                 xf_hz=700.0, xf_db=0.0, thresh_db=-24.0, ratio=2.0,
                 range_db=8.0, knee_db=6.0):
        self.sr = sr
        self.amt = loudness * 0.01
        self.ctr_lo = self.amt * LOW_MAX
        self.ctr_hi = self.amt * HIGH_MAX
        self.mk = 10.0 ** (makeup_db / 20.0)

        self.thr_l = thresh_db
        self.thr_h = thresh_db - 6.0
        self.slope = 1.0 - 1.0 / max(ratio, 1.0)
        self.knee_half = max(knee_db, 0.01) * 0.5
        self.range_l = self.amt * range_db
        self.range_h = self.amt * range_db * 0.5

        self.rms_coef = tcoef(RMS_MS, sr)
        self.atk_l, self.rel_l = tcoef(ATK_L, sr), tcoef(REL_L, sr)
        self.atk_h, self.rel_h = tcoef(ATK_H, sr), tcoef(REL_H, sr)

        self.det_lo = [Biquad(lpf(DET_LO_F, sr)), Biquad(lpf(DET_LO_F, sr))]
        self.det_hi = [Biquad(hpf(DET_HI_F, sr)), Biquad(hpf(DET_HI_F, sr))]
        self.shelf_lo = [Biquad(low_shelf(LOW_F, self.ctr_lo, sr)) for _ in range(2)]
        self.shelf_hi = [Biquad(high_shelf(HIGH_F, self.ctr_hi, sr)) for _ in range(2)]

        self.rms_l = self.rms_h = 0.0
        self.g_ldb = self.g_hdb = 0.0
        self.ctr = 0

        self.xf_on = xf_db >= 0.05
        if self.xf_on:
            (self.a0_lo, self.b1_lo, self.a0_hi, self.a1_hi,
             self.b1_hi, self.cf_gain) = bs2b_coefs(xf_hz, xf_db, sr)
        self.lo_l = self.lo_r = self.hi_l = self.hi_r = 0.0
        self.as_l = self.as_r = 0.0

    def lift_db(self, ldb, thr):
        x = thr - ldb
        hk = self.knee_half
        if x <= -hk:
            g = 0.0
        elif x < hk:
            g = self.slope * (x + hk) * (x + hk) / (4 * hk)
        else:
            g = self.slope * x
        return g * min(max((ldb - GATE_DB) / GATE_W, 0.0), 1.0)

    def _refresh(self):
        cl = low_shelf(LOW_F, self.ctr_lo + self.g_ldb, self.sr)
        ch = high_shelf(HIGH_F, self.ctr_hi + self.g_hdb, self.sr)
        self.shelf_lo[0].c = self.shelf_lo[1].c = cl
        self.shelf_hi[0].c = self.shelf_hi[1].c = ch

    def process(self, left, right):
        out_l, out_r = [], []
        self._refresh()
        for a, b in zip(left, right):
            # ---- detector taps the RAW input (feed-forward, no loop) ----
            d0 = self.det_lo[0](a)
            d1 = self.det_lo[1](b)
            s = (d0 * d0 + d1 * d1) * 0.5
            self.rms_l = s + (self.rms_l - s) * self.rms_coef
            lv_l = 10.0 * math.log10(max(self.rms_l, TINY))
            t = min(self.lift_db(lv_l, self.thr_l), self.range_l)
            c = self.atk_l if t > self.g_ldb else self.rel_l
            self.g_ldb = t + (self.g_ldb - t) * c

            e0 = self.det_hi[0](a)
            e1 = self.det_hi[1](b)
            s = (e0 * e0 + e1 * e1) * 0.5
            self.rms_h = s + (self.rms_h - s) * self.rms_coef
            lv_h = 10.0 * math.log10(max(self.rms_h, TINY))
            t = min(self.lift_db(lv_h, self.thr_h), self.range_h)
            c = self.atk_h if t > self.g_hdb else self.rel_h
            self.g_hdb = t + (self.g_hdb - t) * c

            self.ctr += 1
            if self.ctr >= REFRESH:
                self.ctr = 0
                self._refresh()

            # ---- contour + lift, folded into one shelf pair per channel ----
            ol = self.shelf_hi[0](self.shelf_lo[0](a)) * self.mk
            orr = self.shelf_hi[1](self.shelf_lo[1](b)) * self.mk

            if self.xf_on:
                self.lo_l = self.a0_lo * ol + self.b1_lo * self.lo_l
                self.lo_r = self.a0_lo * orr + self.b1_lo * self.lo_r
                self.hi_l = (self.a0_hi * ol + self.a1_hi * self.as_l
                             + self.b1_hi * self.hi_l)
                self.hi_r = (self.a0_hi * orr + self.a1_hi * self.as_r
                             + self.b1_hi * self.hi_r)
                self.as_l, self.as_r = ol, orr
                ol = (self.hi_l + self.lo_r) * self.cf_gain
                orr = (self.hi_r + self.lo_l) * self.cf_gain

            out_l.append(ol)
            out_r.append(orr)
        return out_l, out_r


def static_contour_db(loudness, f, sr=48000.0):
    """Contour-only magnitude in dB at f (no lift, no makeup)."""
    amt = loudness * 0.01
    cl = low_shelf(LOW_F, amt * LOW_MAX, sr)
    ch = high_shelf(HIGH_F, amt * HIGH_MAX, sr)
    return 20 * math.log10(abs(bq_response(cl, f, sr) * bq_response(ch, f, sr)))
