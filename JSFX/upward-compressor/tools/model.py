#!/usr/bin/env python3
"""Pure-Python reference model of "Magnolius_UpwardCompressor.jsfx".

This mirrors @init / @slider / @sample sample-for-sample.  It exists so the
render tests can assert an exact waveform rather than a hand-derived "about
right", which is how the mix/makeup ordering bug survived as long as it did.

    THE MODEL AND THE .jsfx MUST BE EDITED TOGETHER.  If you change the DSP
    in one and not the other, render_test.py's `model` test fails and that
    failure is the point -- do not "fix" it by loosening the tolerance.

Stdlib only; there is no numpy on this box.
"""
import math

LOG2DB = 8.6858896380650366
DB2LOG = 0.11512925464970229
TINY = 10.0 ** -30
DENORM = 10.0 ** -20
GATE_WIDTH = 6.0

DEFAULTS = dict(thresh_db=-30.0, ratio=2.0, range_db=12.0, knee_db=6.0,
                atk_ms=20.0, rel_ms=200.0, gate_db=-70.0, sc_hz=20.0,
                det_mode=1, link_pct=100.0, makeup_db=0.0, mix_pct=100.0,
                hist_s=6.0)


def db2lin(d):
    return math.exp(d * DB2LOG)


def lin2db(l):
    return math.log(max(l, TINY)) * LOG2DB


class UpwardComp:
    """One instance, stereo.  Call step(l, r) per sample, in order."""

    def __init__(self, srate=48000.0, **sliders):
        bad = set(sliders) - set(DEFAULTS)
        if bad:
            raise KeyError("unknown slider(s): %s" % sorted(bad))
        self.p = dict(DEFAULTS, **sliders)
        self.srate = float(srate)
        # @init
        self.gdb0 = self.gdb1 = 0.0
        self.det0 = self.det1 = 0.0
        self.rms0 = self.rms1 = 0.0
        self.hp0 = self.hp1 = 0.0
        self.adn = DENORM
        self.meter = 0.0
        self.recalc()

    # ---- @slider / the recalc() function in @init -------------------------
    def recalc(self):
        p, sr = self.p, self.srate
        self.slope = 1.0 - 1.0 / max(p["ratio"], 1.0)
        self.knee_half = max(p["knee_db"], 0.01) * 0.5
        self.atk_coef = math.exp(-1.0 / (max(p["atk_ms"], 0.01) * 0.001 * sr))
        self.rel_coef = math.exp(-1.0 / (max(p["rel_ms"], 0.01) * 0.001 * sr))
        self.det_rel = math.exp(-1.0 / (0.020 * sr))
        self.rms_coef = math.exp(-1.0 / (0.030 * sr))
        self.meter_coef = math.exp(-1.0 / (0.150 * sr))
        self.hp_a = 1.0 - math.exp(-2.0 * math.pi
                                   * min(p["sc_hz"], sr * 0.45) / sr)
        self.link = p["link_pct"] * 0.01
        self.makeup = db2lin(p["makeup_db"])
        self.wet = p["mix_pct"] * 0.01
        self.dry = 1.0 - self.wet

    # ---- the lift_db() function in @init ----------------------------------
    def lift_db(self, ldb):
        p = self.p
        x = p["thresh_db"] - ldb
        hk = self.knee_half
        if x <= -hk:
            g = 0.0
        elif x < hk:
            g = self.slope * (x + hk) ** 2 / (4.0 * hk)
        else:
            g = self.slope * x
        return g * min(max((ldb - p["gate_db"]) / GATE_WIDTH, 0.0), 1.0)

    # ---- @sample ----------------------------------------------------------
    def step(self, in0, in1):
        p = self.p
        self.adn = -self.adn
        adn = self.adn

        self.hp0 += self.hp_a * (in0 + adn - self.hp0)
        sc0 = in0 - self.hp0
        self.hp1 += self.hp_a * (in1 + adn - self.hp1)
        sc1 = in1 - self.hp1

        if p["det_mode"] < 0.5:
            a0, a1 = abs(sc0), abs(sc1)
            self.det0 = a0 if a0 > self.det0 else a0 + (self.det0 - a0) * self.det_rel
            self.det1 = a1 if a1 > self.det1 else a1 + (self.det1 - a1) * self.det_rel
        else:
            s0, s1 = sc0 * sc0, sc1 * sc1
            self.rms0 = s0 + (self.rms0 - s0) * self.rms_coef
            self.rms1 = s1 + (self.rms1 - s1) * self.rms_coef
            self.det0 = math.sqrt(max(self.rms0, 0.0))
            self.det1 = math.sqrt(max(self.rms1, 0.0))

        dmax = max(self.det0, self.det1)
        d0 = self.det0 + self.link * (dmax - self.det0)
        d1 = self.det1 + self.link * (dmax - self.det1)

        t0 = min(self.lift_db(lin2db(d0)), p["range_db"])
        t1 = min(self.lift_db(lin2db(d1)), p["range_db"])

        c = self.atk_coef if t0 > self.gdb0 else self.rel_coef
        self.gdb0 = t0 + (self.gdb0 - t0) * c
        c = self.atk_coef if t1 > self.gdb1 else self.rel_coef
        self.gdb1 = t1 + (self.gdb1 - t1) * c

        out0 = self.dry * in0 + self.wet * in0 * db2lin(self.gdb0) * self.makeup
        out1 = self.dry * in1 + self.wet * in1 * db2lin(self.gdb1) * self.makeup

        m = max(self.gdb0, self.gdb1)
        self.meter = m if m > self.meter else m + (self.meter - m) * self.meter_coef
        return out0, out1


def run(chans, srate=48000.0, **sliders):
    """Process [left, right] and return ([left, right], final instance)."""
    m = UpwardComp(srate, **sliders)
    l, r = chans[0], chans[1] if len(chans) > 1 else chans[0]
    ol, orr = [], []
    for a, b in zip(l, r):
        x, y = m.step(a, b)
        ol.append(x)
        orr.append(y)
    return [ol, orr], m


def settled_lift_db(level_db, srate=48000.0, **sliders):
    """Lift a steady tone at `level_db` RMS settles on, in dB.

    Closed form -- the static curve with the Range clamp, no ballistics.
    Independent of run(): a test that compares the two is checking the
    ballistics converge to the static curve, which is the whole contract.
    """
    m = UpwardComp(srate, **sliders)
    return min(m.lift_db(level_db), m.p["range_db"])
