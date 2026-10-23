#!/usr/bin/env python3
"""Pure-Python reference model of "Magnolius_ChannelDynamics.jsfx".

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

# Hidden constants -- the same names and values as the .jsfx @init block.
TAU_RMS = 80e-6                  # shared detector averaging time, s
# compressor
KNEE_A, KNEE_B, KNEE_C, KNEE_D = 0.45, 1.012, 9.8, 1.84
KNEE_OFF = KNEE_B * math.log(1.0 + math.exp(-KNEE_C / KNEE_D))   # makes the knee 0 at x = 0
ATK_TAU_AUTO = 0.033             # s
ATK_TAU_FAST = 0.001             # s
REL_FAST_K = 0.25                # FIT: fast release tau = REL_FAST_K * Release knob
REL_SLOW_X = 6.7                 # slow tau = 6.7 * fast tau (22 uF / 3.3 uF)
SLOW_ATK_X = 4.0                 # FIT: slow state charges this much slower
K_SLOW = 0.6                     # FIT: weight of the slow state
MU_K = 1.0                       # FIT: make-up scale (1 = Reference level stays put)
# gate / expander
GATE_HYS_CLOSE = 11.6            # dB below Threshold
GATE_HYS_OPEN = 2.2
GATE_EXP_SLOPE = 1.1
GATE_ATK_SLOW = 0.00068          # s
GATE_ATK_FAST = 0.00004          # s (FIT)
GATE_REL_MIN = 0.068             # s, tau at the 0.1 s end of the knob
GATE_REL_MAX = 1.768             # s, tau at the 4 s end

# Order matches the slider numbers in the .jsfx header.
NAMES = ["thr_db", "ratio", "rel_s", "out_db", "fast_att", "auto_mu",
         "link_mode", "ref_db", "gate_on", "gate_mode", "gate_thr",
         "gate_range", "gate_rel", "gate_fast"]
DEFAULTS = dict(thr_db=0.0, ratio=4.0, rel_s=0.4, out_db=0.0, fast_att=0,
                auto_mu=1, link_mode=0, ref_db=-18.0, gate_on=0, gate_mode=0,
                gate_thr=-20.0, gate_range=20.0, gate_rel=0.4, gate_fast=0)


def knee(x):
    """Compressor gain computer: x = overshoot * (1 - 1/ratio), dB -> GR dB."""
    if x <= 0:
        return 0.0
    return max(0.0, KNEE_A * x + KNEE_B * math.log(1.0 + math.exp((x - KNEE_C) / KNEE_D)) - KNEE_OFF)


class ChannelDynamics:
    """One stereo instance.  Call step(l, r) per sample, in order."""

    def __init__(self, srate=48000.0, **sliders):
        bad = set(sliders) - set(DEFAULTS)
        if bad:
            raise KeyError("unknown slider(s): %s" % sorted(bad))
        self.p = dict(DEFAULTS, **sliders)
        self.srate = float(srate)
        # @init
        self.ms = 0.0
        self.fast_gr = 0.0
        self.slow_gr = 0.0
        self.comp_gr = 0.0
        self.c9 = 0.0
        self.closed = 0
        self.gate_gr = 0.0
        self.lvl = -120.0
        self.recalc()

    # ---- recalc() ---------------------------------------------------------
    def recalc(self):
        p, sr = self.p, self.srate
        self.slope = 1.0 if p["ratio"] >= 19.995 else 1.0 - 1.0 / max(p["ratio"], 1.0)
        self.thr_eff = p["ref_db"] + p["thr_db"]
        self.mk_db = MU_K * knee(max(0.0, -p["thr_db"]) * self.slope) if p["auto_mu"] > 0.5 else 0.0
        self.gain_db0 = p["out_db"] + self.mk_db
        self.use_avg = p["link_mode"] > 0.5
        self.rms_a = 1.0 - math.exp(-1.0 / (TAU_RMS * sr))
        atk = ATK_TAU_FAST if p["fast_att"] > 0.5 else ATK_TAU_AUTO
        self.atk_c = math.exp(-1.0 / (atk * sr))
        self.atk_cs = math.exp(-1.0 / (atk * SLOW_ATK_X * sr))
        tf = max(p["rel_s"], 0.001) * REL_FAST_K
        self.rel_cf = math.exp(-1.0 / (tf * sr))
        self.rel_cs = math.exp(-1.0 / (tf * REL_SLOW_X * sr))
        # gate
        self.g_on = p["gate_on"] > 0.5
        self.g_gate = p["gate_mode"] > 0.5
        self.g_thr = p["ref_db"] + p["gate_thr"]
        self.g_range = p["gate_range"]
        gp = math.log(max(p["gate_rel"], 0.1) / 0.1) / math.log(40.0)
        gtau = GATE_REL_MIN * math.exp(gp * math.log(GATE_REL_MAX / GATE_REL_MIN))
        self.g_rel_c = math.exp(-1.0 / (gtau * sr))
        gatk = GATE_ATK_FAST if p["gate_fast"] > 0.5 else GATE_ATK_SLOW
        self.g_atk_c = math.exp(-1.0 / (gatk * sr))

    # ---- gain computer: dB level in -> dB gain reduction out (>= 0) -------
    def gr_calc(self, x):
        return knee(max(0.0, x - self.thr_eff) * self.slope)

    def static_out_db(self, x):
        """Steady-state output level for a steady input level x (dB), compressor only."""
        return x - self.gr_calc(x) + self.gain_db0

    # ---- @sample ----------------------------------------------------------
    def step(self, l, r):
        ae = (l * l + r * r) * 0.5 if self.use_avg else max(l * l, r * r)
        self.ms += self.rms_a * (ae - self.ms)
        self.ms = max(self.ms, TINY_E)
        lvl = 0.5 * LOG2DB * math.log(self.ms)
        self.lvl = lvl

        # compressor: RC attack, two-state release
        t = self.gr_calc(lvl)
        if t > self.fast_gr:
            self.fast_gr = t + (self.fast_gr - t) * self.atk_c
        else:
            self.fast_gr = t + (self.fast_gr - t) * self.rel_cf
        if t > self.slow_gr:
            self.slow_gr = t + (self.slow_gr - t) * self.atk_cs
        else:
            self.slow_gr = t + (self.slow_gr - t) * self.rel_cs
        if self.fast_gr < 1e-9:
            self.fast_gr = 0.0
        if self.slow_gr < 1e-9:
            self.slow_gr = 0.0
        self.comp_gr = max(self.fast_gr, self.slow_gr * K_SLOW)

        # gate / expander
        if self.g_on:
            if self.g_gate:
                if self.closed:
                    if lvl > self.g_thr - GATE_HYS_OPEN:
                        self.closed = 0
                elif lvl < self.g_thr - GATE_HYS_CLOSE:
                    self.closed = 1
                tgt = 1000.0 if self.closed else 0.0
            else:
                self.closed = 0
                tgt = max(0.0, self.g_thr - lvl) * GATE_EXP_SLOPE
            self.c9 = self.g_range + (self.c9 - self.g_range) * self.g_rel_c
            if self.c9 > tgt:
                self.c9 = tgt + (self.c9 - tgt) * self.g_atk_c
            if self.c9 < 1e-9:
                self.c9 = 0.0
            self.gate_gr = max(0.0, self.c9)
        else:
            self.closed = 0
            self.c9 = 0.0
            self.gate_gr = 0.0

        gr = max(self.comp_gr, self.gate_gr)
        g = math.exp((self.gain_db0 - gr) * DB2LOG)
        return l * g, r * g


def run(chans, srate=48000.0, trace=False, **sliders):
    """Run the model over [left, right]. Returns ([L, R], info).

    info["gr"] / info["gate"] / info["lvl"] are per-sample traces when
    trace=True.
    """
    c = ChannelDynamics(srate, **sliders)
    L, R = chans
    oL, oR, grt, gat, lvt = [], [], [], [], []
    for l, r in zip(L, R):
        a, b = c.step(l, r)
        oL.append(a)
        oR.append(b)
        if trace:
            grt.append(c.comp_gr)
            gat.append(c.gate_gr)
            lvt.append(c.lvl)
    return [oL, oR], dict(gr=grt, gate=gat, lvl=lvt, model=c)
