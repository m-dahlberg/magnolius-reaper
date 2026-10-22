#!/usr/bin/env python3
"""Pure-Python reference model of "Magnolius_BusCompressor.jsfx".

Mirrors @init / recalc() / @sample sample-for-sample, so the render tests can
assert an exact waveform instead of a hand-derived "about right".

    THE MODEL AND THE .jsfx MUST BE EDITED TOGETHER.  If you change the DSP in
    one and not the other, render_test.py's `model` test fails and that
    failure is the point -- do not "fix" it by loosening the tolerance.

Stdlib only; there is no numpy on this box.

Signal flow (all of it per sample, at the host rate unless stated):

    key = input L/R, or the external key (ch 3/4)
    key -> 2nd-order Butterworth HPF (detector only)
    -> peak envelope of max(|L|,|R|), instant attack, DET_REL release
    -> dB -> gain computer (3 dB quadratic knee) -> target GR in dB
    -> shared timing element (one-pole in the GR domain)
       fixed release : a single state, attack tau / release tau
       Auto release  : a fast state plus a slow state, GR = max of the two
    -> VCA gain on the input
    -> Colour: 2x oversampled polynomial shaper (halfband FIR up and down),
       drive follows the gain reduction; crossfaded against a plain delay
    -> makeup (wet path only) -> dry/wet -> bypass -> key listen

Latency is a constant LAT samples (the oversampler), whatever the settings.
The dry path, the bypass path and the Colour-off path are delayed by LAT.
"""
import math

LOG2DB = 8.6858896380650366
DB2LOG = 0.11512925464970229
TINY_A = 10.0 ** -6              # amplitude floor, -120 dB.  NOT 1e-6.

# ---- hidden constants; the same names and values as the .jsfx @init block --
KNEE_W = 3.0                     # dB, quadratic knee
DET_REL = 0.002                  # s, detector peak-envelope release
AUTO_TF = 0.12                   # s, Auto: fast element release
AUTO_TSC = 1.0                   # s, Auto: slow element charge
AUTO_TSR = 2.0                   # s, Auto: slow element release
SM_T = 0.020                     # s, makeup / mix / colour smoothing
RAMP_T = 0.010                   # s, bypass / listen / Colour-switch ramps
HP_BLK = 32                      # samples between HPF coefficient updates
HP_OFF_HZ = 10.0                 # the filter parks here while Off
HP_GLIDE_T = 0.020               # s, cutoff glide
SAT_A2 = 0.08                    # 2nd-order shaper term
SAT_A3 = 0.20                    # 3rd-order shaper term
SAT_BASE = 0.25                  # share of the drive present with no GR
SAT_GR_FULL = 10.0               # dB of GR at which the drive is full
SAT_REF2 = 0.20                  # squared amplitude the gain trim assumes
DC_HZ = 8.0                      # DC blocker corner after the shaper
MTR_RISE = 0.015                 # s, GR needle
MTR_FALL = 0.250
MTR_PK = 0.300                   # s, in/out peak fall
KAISER_BETA = 8.0

RING = 64                        # power of two
MASK = RING - 1
HALF = 12                        # halfband half-length / 2: 49 taps
LAT = 24                         # samples, total oversampler latency

RATIOS = [2.0, 4.0, 10.0]
ATT_MS = [0.1, 0.3, 1.0, 3.0, 10.0, 30.0]
REL_S = [0.1, 0.3, 0.6, 1.2]     # index 4 = Auto

# Order matches the slider numbers in the .jsfx header.
NAMES = ["thr_db", "ratio_i", "att_i", "rel_i", "makeup_db", "hpf_hz",
         "ext_key", "key_listen", "colour", "mix", "bypass"]
DEFAULTS = dict(thr_db=-10.0, ratio_i=1, att_i=4, rel_i=1, makeup_db=0.0,
                hpf_hz=0.0, ext_key=0, key_listen=0, colour=0.0, mix=100.0,
                bypass=0)


def halfband():
    """The 12 distinct odd-offset taps of the 49-tap Kaiser halfband.

    h[24 +- (2i-1)] = c[i], i = 1..12; the centre tap is 0.5 and every other
    tap is zero.  Scaled so the DC gain is exactly 1.
    """
    def i0(x):
        s = t = 1.0
        for k in range(1, 26):
            t *= (x * 0.5 / k) ** 2
            s += t
        return s
    b0 = i0(KAISER_BETA)
    c = [0.0]
    for i in range(1, HALF + 1):
        j = 2 * i - 1
        w = i0(KAISER_BETA * math.sqrt(1.0 - (j / 24.0) ** 2)) / b0
        c.append(math.sin(math.pi * j * 0.5) / (math.pi * j) * w)
    tot = sum(c)
    return [v * 0.25 / tot for v in c]


class BusComp:
    """One stereo instance.  Call step(l, r[, kl, kr]) per sample, in order."""

    def __init__(self, srate=48000.0, **sliders):
        bad = set(sliders) - set(DEFAULTS)
        if bad:
            raise KeyError("unknown slider(s): %s" % sorted(bad))
        self.p = dict(DEFAULTS, **sliders)
        self.srate = float(srate)
        self.c = halfband()
        self.recalc()
        # @init state
        self.det = 0.0
        self.g = 0.0
        self.s = 0.0
        self.gr = 0.0
        self.lvl = -120.0
        self.wa = self.auto_t
        self.mk_sm = self.mk_t
        self.mix_sm = self.mix_t
        self.col_sm = self.col_t
        self.bp_sw = self.bp_t
        self.ls_sw = self.ls_t
        self.sat_sw = self.sat_t
        self.hp_lf = self.hp_tgt
        self.hp_cnt = 0
        self.hz1 = [0.0, 0.0]
        self.hz2 = [0.0, 0.0]
        self.hb0 = self.hb1 = self.hb2 = self.ha1 = self.ha2 = 0.0
        self.hp_design(math.exp(self.hp_lf))
        self.dcx = [0.0, 0.0]
        self.dcy = [0.0, 0.0]
        self.wp = 0
        z = lambda: [0.0] * RING                                  # noqa: E731
        self.dry = [z(), z()]
        self.xg = [z(), z()]
        self.ze = [z(), z()]
        self.zo = [z(), z()]
        self.dd = z()
        self.sc = [1.0] * RING                                    # 1/gain; 1 = no GR
        self.mtr_gr = 0.0
        self.mtr_in = 0.0
        self.mtr_out = 0.0

    # ---- recalc() ---------------------------------------------------------
    def recalc(self):
        p, sr = self.p, self.srate
        ri = min(max(int(math.floor(p["ratio_i"] + 0.5)), 0), 2)
        ai = min(max(int(math.floor(p["att_i"] + 0.5)), 0), 5)
        li = min(max(int(math.floor(p["rel_i"] + 0.5)), 0), 4)
        self.thr = p["thr_db"]
        self.slope = 1.0 - 1.0 / RATIOS[ri]
        tau_a = ATT_MS[ai] * 0.001
        self.a_att = 1.0 - math.exp(-1.0 / (tau_a * sr))
        self.auto_t = 1.0 if li == 4 else 0.0
        tau_r = AUTO_TF if li == 4 else REL_S[li]
        self.a_rel = 1.0 - math.exp(-1.0 / (max(tau_r, tau_a) * sr))
        self.a_sc = 1.0 - math.exp(-1.0 / (AUTO_TSC * sr))
        self.a_sr = 1.0 - math.exp(-1.0 / (AUTO_TSR * sr))
        self.det_r = math.exp(-1.0 / (DET_REL * sr))
        self.sm_a = 1.0 - math.exp(-1.0 / (SM_T * sr))
        self.ramp_s = 1.0 / (RAMP_T * sr)
        self.mk_t = p["makeup_db"]
        self.mix_t = p["mix"] * 0.01
        self.col_t = p["colour"] * 0.01
        self.sat_t = 1.0 if p["colour"] > 0.0 else 0.0
        self.bp_t = 1.0 if p["bypass"] > 0.5 else 0.0
        self.ls_t = 1.0 if p["key_listen"] > 0.5 else 0.0
        self.ext = p["ext_key"] > 0.5
        self.hp_on = p["hpf_hz"] >= 20.0
        self.hp_tgt = math.log(p["hpf_hz"] if self.hp_on else HP_OFF_HZ)
        self.hp_a = 1.0 - math.exp(-1.0 / (HP_GLIDE_T * sr / HP_BLK))
        self.dc_r = 1.0 - 2.0 * math.pi * DC_HZ / sr
        self.m_rise = 1.0 - math.exp(-1.0 / (MTR_RISE * sr))
        self.m_fall = 1.0 - math.exp(-1.0 / (MTR_FALL * sr))
        self.m_pk = math.exp(-1.0 / (MTR_PK * sr))

    def hp_design(self, f):
        f = min(f, self.srate * 0.45)
        k = math.tan(math.pi * f / self.srate)
        nrm = 1.0 / (1.0 + 1.41421356237309505 * k + k * k)
        self.hb0 = nrm
        self.hb1 = -2.0 * nrm
        self.hb2 = nrm
        self.ha1 = 2.0 * (k * k - 1.0) * nrm
        self.ha2 = (1.0 - 1.41421356237309505 * k + k * k) * nrm

    # ---- gain computer: dB level in -> dB gain reduction out (>= 0) -------
    def gr_calc(self, x):
        o = x - self.thr
        w = KNEE_W
        if 2 * o < -w:
            return 0.0
        if 2 * abs(o) <= w:
            return self.slope * (o + w * 0.5) ** 2 / (2 * w)
        return self.slope * o

    def static_out_db(self, x):
        """Steady-state output level for a steady input level x (dB)."""
        return x - self.gr_calc(x) + self.mk_t

    # ---- helpers ----------------------------------------------------------
    @staticmethod
    def _snap(x, t, eps):
        return t if abs(t - x) < eps else x

    def _ramp(self, x, t):
        if x < t:
            return min(x + self.ramp_s, t)
        return max(x - self.ramp_s, t)

    def _fir(self, buf, wi, p, q):
        c = self.c
        s = 0.0
        for i in range(1, HALF + 1):
            s += c[i] * (buf[(wi + RING - p - i) & MASK] + buf[(wi + RING - q + i) & MASK])
        return s

    @staticmethod
    def _shape(x, d, sc):
        """Shaper at the PRE-compression level: x is the post-VCA signal, sc
        = 1/gain undoes the gain reduction for the polynomial and puts it
        back afterwards, so Colour depends on the input level and the drive d
        alone follows the gain reduction."""
        xs = x * sc
        xc = max(-1.0, min(1.0, xs))
        return (xs + d * (SAT_A2 * xc * xc - SAT_A3 * xc * xc * xc)) / sc

    # ---- @sample ----------------------------------------------------------
    def step(self, l, r, kl=0.0, kr=0.0):
        """Returns (out_l, out_r).  kl/kr are the external key, used only
        when ext_key is on."""
        al, ar = l, r
        if self.ext:
            kin = (kl, kr)
        else:
            kin = (al, ar)

        # key HPF, coefficients glided every HP_BLK samples
        self.hp_cnt -= 1
        if self.hp_cnt <= 0:
            self.hp_cnt = HP_BLK
            self.hp_lf += self.hp_a * (self.hp_tgt - self.hp_lf)
            self.hp_design(math.exp(self.hp_lf))
        kf = [0.0, 0.0]
        for ch in (0, 1):
            x = kin[ch]
            y = self.hb0 * x + self.hz1[ch]
            self.hz1[ch] = self.hb1 * x - self.ha1 * y + self.hz2[ch]
            self.hz2[ch] = self.hb2 * x - self.ha2 * y
            kf[ch] = y if self.hp_on else x

        # detector -> gain computer
        dtc = max(abs(kf[0]), abs(kf[1]))
        if dtc > self.det:
            self.det = dtc
        else:
            self.det = dtc + (self.det - dtc) * self.det_r
        lvl = LOG2DB * math.log(max(self.det, TINY_A))
        self.lvl = lvl
        tgt = self.gr_calc(lvl)

        # shared timing element; the slow element only matters in Auto
        self.g += (tgt - self.g) * (self.a_att if tgt > self.g else self.a_rel)
        self.s += (tgt - self.s) * (self.a_sc if tgt > self.s else self.a_sr)
        if self.g < 0.000000001:
            self.g = 0.0
        if self.s < 0.000000001:
            self.s = 0.0
        self.wa = self._ramp(self.wa, self.auto_t)
        grm = max(self.g, self.s)
        self.gr = self.g + self.wa * (grm - self.g)
        glin = math.exp(-self.gr * DB2LOG)

        # smoothed controls and ramps
        self.mk_sm += self.sm_a * (self.mk_t - self.mk_sm)
        self.mk_sm = self._snap(self.mk_sm, self.mk_t, 1e-6)
        self.mix_sm += self.sm_a * (self.mix_t - self.mix_sm)
        self.mix_sm = self._snap(self.mix_sm, self.mix_t, 1e-7)
        self.col_sm += self.sm_a * (self.col_t - self.col_sm)
        self.col_sm = self._snap(self.col_sm, self.col_t, 1e-7)
        self.bp_sw = self._ramp(self.bp_sw, self.bp_t)
        self.ls_sw = self._ramp(self.ls_sw, self.ls_t)
        self.sat_sw = self._ramp(self.sat_sw, self.sat_t)

        # write the rings
        wi = self.wp
        d = self.col_sm * (SAT_BASE + (1.0 - SAT_BASE) * min(1.0, self.gr / SAT_GR_FULL))
        self.dd[wi] = d
        self.sc[wi] = 1.0 / glin
        dsel = self.dd[(wi + RING - HALF) & MASK]
        ssel = self.sc[(wi + RING - HALF) & MASK]
        comp = 1.0 / (1.0 - 0.75 * SAT_A3 * dsel * SAT_REF2)
        mk = math.exp(self.mk_sm * DB2LOG)
        al_ar = (al, ar)
        out = [0.0, 0.0]
        mx = 0.0
        for ch in (0, 1):
            self.dry[ch][wi] = al_ar[ch]
            self.xg[ch][wi] = al_ar[ch] * glin
            xg = self.xg[ch]
            e = xg[(wi + RING - HALF) & MASK]
            o = 2.0 * self._fir(xg, wi, 11, 12)
            self.ze[ch][wi] = self._shape(e, dsel, ssel)
            self.zo[ch][wi] = self._shape(o, dsel, ssel)
            sat = 0.5 * self.ze[ch][(wi + RING - HALF) & MASK] \
                + self._fir(self.zo[ch], wi, 12, 13)
            sat *= comp
            # DC blocker on the shaper output
            y = sat - self.dcx[ch] + self.dc_r * self.dcy[ch]
            self.dcx[ch] = sat
            self.dcy[ch] = y
            wd = xg[(wi + RING - LAT) & MASK]
            wet = wd + self.sat_sw * (y - wd)
            wet *= mk
            dry_d = self.dry[ch][(wi + RING - LAT) & MASK]
            pr = dry_d * (1.0 - self.mix_sm) + wet * self.mix_sm
            o_ = pr * (1.0 - self.bp_sw) + dry_d * self.bp_sw
            o_ = o_ * (1.0 - self.ls_sw) + kf[ch] * self.ls_sw
            out[ch] = o_
            mx = max(mx, abs(o_))
        self.wp = (wi + 1) & MASK

        # meters
        mi = max(abs(al), abs(ar))
        self.mtr_in = mi if mi > self.mtr_in else self.mtr_in * self.m_pk
        self.mtr_out = mx if mx > self.mtr_out else self.mtr_out * self.m_pk
        self.mtr_gr += (self.gr - self.mtr_gr) * (
            self.m_rise if self.gr > self.mtr_gr else self.m_fall)
        return out[0], out[1]


def run(chans, srate=48000.0, trace=False, key=None, **sliders):
    """Run the model over [left, right]. Returns ([L, R], info).

    key: optional [kl, kr] external key.  info["gr"] / info["lvl"] are
    per-sample traces when trace=True.
    """
    c = BusComp(srate, **sliders)
    L, R = chans
    n = len(L)
    kL, kR = key if key else ([0.0] * n, [0.0] * n)
    oL, oR, grt, lvt = [], [], [], []
    for i in range(n):
        a, b = c.step(L[i], R[i], kL[i], kR[i])
        oL.append(a)
        oR.append(b)
        if trace:
            grt.append(c.gr)
            lvt.append(c.lvl)
    return [oL, oR], dict(gr=grt, lvl=lvt, model=c)
