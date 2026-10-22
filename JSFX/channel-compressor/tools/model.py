#!/usr/bin/env python3
"""Pure-Python reference model of "Magnolius_ChannelCompressor.jsfx".

Mirrors @init / recalc() / @sample sample-for-sample, so the render tests can
assert an exact waveform instead of a hand-derived "about right".

    THE MODEL AND THE .jsfx MUST BE EDITED TOGETHER.  If you change the DSP in
    one and not the other, render_test.py's `model` test fails and that
    failure is the point -- do not "fix" it by loosening the tolerance.

Stdlib only; there is no numpy on this box.
"""
import math

LOG2DB = 8.6858896380650366
DB2LOG = 0.11512925464970229
TINY_E = 10.0 ** -12
TINY_A = 10.0 ** -6

# Hidden constants -- the same names and values as the .jsfx @init block.
TAU_RMS = 0.010
KNEE_W = 12.0
PK_ATT = 0.0001
PK_REL = 0.030
PK_OFF_DB = -2.76
ATK_RC = 0.0
MU_K = 1.0
ATT_DBPS_N = 20.0 / 0.030
ATT_DBPS_F = 20.0 / 0.003
LIN_REL_THR = 6.0

# Order matches the slider numbers in the .jsfx header.
NAMES = ["thr_db", "ratio", "rel_s", "out_db", "fast_att", "hard_knee",
         "lin_rel", "auto_mu", "link_mode", "ref_db"]
DEFAULTS = dict(thr_db=0.0, ratio=4.0, rel_s=0.4, out_db=0.0, fast_att=0,
                hard_knee=0, lin_rel=0, auto_mu=1, link_mode=0, ref_db=-18.0)


class ChannelComp:
    """One stereo instance.  Call step(l, r) per sample, in order."""

    def __init__(self, srate=48000.0, **sliders):
        bad = set(sliders) - set(DEFAULTS)
        if bad:
            raise KeyError("unknown slider(s): %s" % sorted(bad))
        self.p = dict(DEFAULTS, **sliders)
        self.srate = float(srate)
        # @init
        self.ms = 0.0
        self.pk = 0.0
        self.gr = 0.0
        self.ts = 0.0
        self.lvl = -120.0
        self.recalc()

    # ---- recalc() ---------------------------------------------------------
    def recalc(self):
        p, sr = self.p, self.srate
        self.slope = 1.0 if p["ratio"] >= 19.995 else 1.0 - 1.0 / max(p["ratio"], 1.0)
        self.thr_eff = p["ref_db"] + p["thr_db"] + (LIN_REL_THR if p["lin_rel"] > 0.5 else 0.0)
        self.knee_w = 0.0 if p["hard_knee"] > 0.5 else KNEE_W
        self.mk_db = (MU_K * self.slope * max(0.0, -p["thr_db"])) if p["auto_mu"] > 0.5 else 0.0
        self.gain_db0 = p["out_db"] + self.mk_db
        self.att_step = (ATT_DBPS_F if p["fast_att"] > 0.5 else ATT_DBPS_N) / sr
        rs = max(p["rel_s"], 0.001)
        self.rel_coef = math.exp(-1.0 / (rs * sr))
        self.rel_step = 20.0 / (rs * sr)
        self.use_peak = p["hard_knee"] > 0.5
        self.use_lin = p["lin_rel"] > 0.5
        self.use_avg = p["link_mode"] > 0.5
        self.rms_a = 1.0 - math.exp(-1.0 / (TAU_RMS * sr))
        self.pk_a = 1.0 - math.exp(-1.0 / (PK_ATT * sr))
        self.pk_r = math.exp(-1.0 / (PK_REL * sr))
        self.atk_a = 1.0 - math.exp(-1.0 / (ATK_RC * sr)) if ATK_RC > 0 else 1.0

    # ---- gain computer: dB level in -> dB gain reduction out (>= 0) -------
    def gr_calc(self, x):
        o = x - self.thr_eff
        w = self.knee_w
        if w > 0:
            if 2 * o < -w:
                return 0.0
            if 2 * abs(o) <= w:
                return self.slope * (o + w * 0.5) ** 2 / (2 * w)
            return self.slope * o
        return self.slope * o if o > 0 else 0.0

    def static_out_db(self, x):
        """Steady-state output level for a steady input level x (dB)."""
        return x - self.gr_calc(x) + self.gain_db0

    # ---- @sample ----------------------------------------------------------
    def step(self, l, r):
        if self.use_avg:
            ae = (abs(l) + abs(r)) * 0.5
        else:
            ae = max(abs(l), abs(r))
        self.pk = self.pk + self.pk_a * (ae - self.pk) if ae > self.pk else self.pk * self.pk_r
        self.pk = max(self.pk, TINY_A)
        ae = (l * l + r * r) * 0.5 if self.use_avg else max(l * l, r * r)
        self.ms += self.rms_a * (ae - self.ms)
        self.ms = max(self.ms, TINY_E)

        if self.use_peak:
            lvl = LOG2DB * math.log(self.pk) + PK_OFF_DB
        else:
            lvl = 0.5 * LOG2DB * math.log(self.ms)
        self.lvl = lvl

        tgt = self.gr_calc(lvl)
        if self.atk_a < 1:
            self.ts += self.atk_a * (tgt - self.ts)
        else:
            self.ts = tgt

        if self.ts > self.gr:
            self.gr = min(self.ts, self.gr + self.att_step)
        elif self.use_lin:
            self.gr = max(self.ts, self.gr - self.rel_step)
        else:
            self.gr = self.ts + (self.gr - self.ts) * self.rel_coef
        if self.gr < 0.000000001:
            self.gr = 0.0

        g = math.exp((self.gain_db0 - self.gr) * DB2LOG)
        return l * g, r * g


def run(chans, srate=48000.0, trace=False, **sliders):
    """Run the model over [left, right]. Returns ([L, R], info).

    info["gr"] / info["lvl"] are per-sample traces when trace=True.
    """
    c = ChannelComp(srate, **sliders)
    L, R = chans
    oL, oR, grt, lvt = [], [], [], []
    for l, r in zip(L, R):
        a, b = c.step(l, r)
        oL.append(a)
        oR.append(b)
        if trace:
            grt.append(c.gr)
            lvt.append(c.lvl)
    return [oL, oR], dict(gr=grt, lvl=lvt, model=c)
