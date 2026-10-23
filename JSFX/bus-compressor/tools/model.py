#!/usr/bin/env python3
"""Pure-Python reference model of "Magnolius_BusCompressor.jsfx".

Mirrors @init / recalc() / @sample sample-for-sample, so the render tests can
assert an exact waveform instead of a hand-derived "about right".

    THE MODEL AND THE .jsfx MUST BE EDITED TOGETHER.  If you change the DSP in
    one and not the other, render_test.py's `model` test fails and that
    failure is the point -- do not "fix" it by loosening the tolerance.

Stdlib only; there is no numpy on this box.

This is a behavioural model of a feedback VCA bus compressor: the detector sees
the gain-REDUCED signal, so the static curve comes out of the loop instead of a
gain computer.  The numbers that are not on the drawings are INFERRED and
marked so; see README.md.

Signal flow (all of it per sample, at the host rate unless stated):

    key = input L/R, or the external key (ch 3/4)
    key -> 2nd-order Butterworth HPF (detector only)
    -> a = max(|L|,|R|) * (the gain of the previous sample)   [the feedback]
    -> rectifier  Vr = K * a^eta     (eta from the Ratio switch)
    -> RC timing network, state in dB of gain reduction
       fixed release : one 0.47 uF capacitor, attack R in, release R and the
                       3M3 bleed out; the diode only charges
       Auto release  : two coupled capacitors (0.47 uF || 91k) in series with
                       (6.8 uF || 750k)
    -> VCA gain on the input (gain = 10^(-V/20))
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
# The RC network.  Resistances in ohms, capacitances in farads.
C_T = 0.47e-6                    # timing capacitor
R_ATT = [820.0, 2700.0, 8200.0, 27000.0, 82000.0, 270000.0]
R_REL = [180000.0, 270000.0, 560000.0, 1200000.0]      # index 4 = Auto
R_BLEED = 3.3e6                  # always on the node
R_A1, C_A1 = 91000.0, 0.47e-6    # Auto, fast section
R_A2, C_A2 = 750000.0, 6.8e-6    # Auto, slow section
# INFERRED
U_REF = 1.0                      # dB of GR a steady sine at Threshold gives
VR_CAP = 100.0                   # dB, rectifier output limit
GR_MAX = 30.0                    # dB, the control line cannot go further
ETA_PER_RATIO = 1.15129254649702  # eta = (ratio - 1) / this: slope at 10 dB GR
A_FLOOR = 10.0 ** -10            # below this the rectifier reads nothing
SM_T = 0.020                     # s, makeup / mix / colour smoothing
RAMP_T = 0.010                   # s, bypass / listen / Colour-switch ramps
HP_BLK = 32                      # samples between HPF coefficient updates
HP_OFF_HZ = 10.0                 # the filter parks here while Off
HP_GLIDE_T = 0.020               # s, cutoff glide
SAT_A2 = 0.01                    # 2nd-order shaper term (a trimmed VCA nulls it)
SAT_A3 = 0.20                    # 3rd-order shaper term
SAT_BASE = 0.25                  # share of the drive present with no GR
SAT_GR_FULL = 10.0               # dB of GR at which the drive is full
SAT_REF2 = 0.20                  # squared amplitude the gain trim assumes
DC_HZ = 8.0                      # DC blocker corner after the shaper
MTR_T = 0.025                    # s, each of the two needle poles
MTR_PK = 0.300                   # s, in/out peak fall
KAISER_BETA = 8.0
M_N = 1024                       # points for the mean of |sin|^eta

RING = 64                        # power of two
MASK = RING - 1
HALF = 12                        # halfband half-length / 2: 49 taps
LAT = 24                         # samples, total oversampler latency

RATIOS = [2.0, 4.0, 10.0]
ATT_MS = [0.1, 0.3, 1.0, 3.0, 10.0, 30.0]     # labels only: the RC values set the time
REL_S = [0.1, 0.3, 0.6, 1.2]     # labels only; index 4 = Auto

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
        self.m_tab = [self._mean_sin_pow(self._eta(r)) for r in RATIOS]
        self.recalc()
        # @init state
        self.v = 0.0                  # the timing node, dB of gain reduction
        self.vc1 = 0.0                # Auto: the two capacitor voltages
        self.vc2 = 0.0
        self.gr = 0.0
        self.glin = 1.0
        self.lvl = -120.0
        self.c_a = -1                 # timing_design() has not run yet
        self.c_l = -1
        self.timing_design()
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
        self.mtr_gr1 = 0.0
        self.mtr_gr = 0.0
        self.mtr_in = 0.0
        self.mtr_out = 0.0

    # ---- recalc() ---------------------------------------------------------
    @staticmethod
    def _eta(ratio):
        return (ratio - 1.0) / ETA_PER_RATIO

    @staticmethod
    def _mean_sin_pow(eta):
        """Mean of |sin|^eta over a half cycle: what a slow detector averages
        a sine to.  A midpoint sum, the same one the .jsfx @init runs."""
        tot = 0.0
        for k in range(M_N):
            tot += math.sin(math.pi * (k + 0.5) / M_N) ** eta
        return tot / M_N

    def recalc(self):
        p, sr = self.p, self.srate
        self.r_k = min(max(int(math.floor(p["ratio_i"] + 0.5)), 0), 2)
        self.a_k = min(max(int(math.floor(p["att_i"] + 0.5)), 0), 5)
        self.l_k = min(max(int(math.floor(p["rel_i"] + 0.5)), 0), 4)
        self.eta = self._eta(RATIOS[self.r_k])
        # Vr = vr_k * exp(eta * (ln a - lref)): a steady sine of peak `thr_db`
        # averages to U_REF dB of Vr, with no divider.
        self.lref = DB2LOG * (p["thr_db"] - U_REF)
        self.vr_k = U_REF / self.m_tab[self.r_k]
        self.auto_t = 1.0 if self.l_k == 4 else 0.0
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
        self.m_a = 1.0 - math.exp(-1.0 / (MTR_T * sr))
        self.m_pk = math.exp(-1.0 / (MTR_PK * sr))

    # ---- the RC network, per mode, exactly integrated over one sample -----
    def timing_design(self):
        """Coefficients of the timing network for the current Attack/Release
        and sample rate.  AUDIO THREAD ONLY (in the .jsfx).  Also carries the
        node voltage across a fixed <-> Auto change, so a release switch never
        resets the envelope."""
        sr = self.srate
        h = 1.0 / sr
        ra = R_ATT[self.a_k]
        was_auto = self.c_l == 4
        now_auto = self.l_k == 4
        if was_auto and not now_auto:
            self.v = self.vc1 + self.vc2
        elif now_auto and not was_auto:
            self.vc1 = self.v * C_A2 / (C_A1 + C_A2)      # series: equal charge
            self.vc2 = self.v - self.vc1
        self.c_a = self.a_k
        self.c_l = self.l_k
        # --- fixed release: one state ---
        rr = R_REL[min(self.l_k, 3)]
        rp = rr * R_BLEED / (rr + R_BLEED)
        tau_on = ra * rp / (ra + rp) * C_T
        self.e_on = math.exp(-h / tau_on)
        self.f_on = (1.0 - self.e_on) * rp / (ra + rp)
        self.e_off = math.exp(-h / (rp * C_T))
        # --- Auto: x = [vc1, vc2], dx/dt = A x + b Vr (diode on) ---
        d1 = 1.0 / (R_A1 * C_A1)
        d2 = 1.0 / (R_A2 * C_A2)
        for mode in (0, 1):                               # 0 = diode on
            g = (1.0 / ra if mode == 0 else 0.0) + 1.0 / R_BLEED
            a11 = -g / C_A1 - d1
            a12 = -g / C_A1
            a21 = -g / C_A2
            a22 = -g / C_A2 - d2
            m = 0.5 * (a11 + a22)
            sg = math.sqrt((0.5 * (a11 - a22)) ** 2 + a12 * a21)
            ep = math.exp((m + sg) * h)
            em = math.exp((m - sg) * h)
            ch = 0.5 * (ep + em)
            sh = (ep - em) / (2.0 * sg)
            e11 = ch + sh * (a11 - m)
            e12 = sh * a12
            e21 = sh * a21
            e22 = ch + sh * (a22 - m)
            if mode == 0:
                b1, b2 = 1.0 / (ra * C_A1), 1.0 / (ra * C_A2)
                det = a11 * a22 - a12 * a21
                x1 = -(a22 * b1 - a12 * b2) / det         # steady state per Vr
                x2 = -(-a21 * b1 + a11 * b2) / det
                self.f1 = (1.0 - e11) * x1 - e12 * x2
                self.f2 = -e21 * x1 + (1.0 - e22) * x2
                self.on_e = (e11, e12, e21, e22)
            else:
                self.off_e = (e11, e12, e21, e22)

    def hp_design(self, f):
        f = min(f, self.srate * 0.45)
        k = math.tan(math.pi * f / self.srate)
        nrm = 1.0 / (1.0 + 1.41421356237309505 * k + k * k)
        self.hb0 = nrm
        self.hb1 = -2.0 * nrm
        self.hb2 = nrm
        self.ha1 = 2.0 * (k * k - 1.0) * nrm
        self.ha2 = (1.0 - 1.41421356237309505 * k + k * k) * nrm

    # ---- analytic steady state (used by the tests and the README) ---------
    def rho(self):
        """The divider R_p / (R_att + R_p) that sets how much of the
        rectifier output the timing capacitor reaches in steady state."""
        ra = R_ATT[self.a_k]
        if self.l_k == 4:
            rp = (R_A1 + R_A2) * R_BLEED / (R_A1 + R_A2 + R_BLEED)
        else:
            rr = R_REL[self.l_k]
            rp = rr * R_BLEED / (rr + R_BLEED)
        return rp / (ra + rp)

    def static_gr(self, level_db, sine=False):
        """Steady-state gain reduction in dB for a steady input of peak
        `level_db` dBFS: the fixed point of V = rho * Vr(a * g(V)).  A square
        wave reads the rectifier directly; a sine is averaged by a slow
        attack, so its rectifier output is scaled by the mean of |sin|^eta."""
        a0 = 10.0 ** (level_db / 20.0)
        k = self.vr_k * (self.m_tab[self.r_k] if sine else 1.0)
        rho = self.rho()
        lo, hi = 0.0, GR_MAX
        for _ in range(80):
            v = 0.5 * (lo + hi)
            vr = min(VR_CAP, k * math.exp(self.eta * (math.log(a0) - DB2LOG * v - self.lref)))
            if rho * vr > v:
                lo = v
            else:
                hi = v
        return 0.5 * (lo + hi)

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

        # feedback detector: the key times the gain of the previous sample
        if self.a_k != self.c_a or self.l_k != self.c_l:
            self.timing_design()
        a = max(abs(kf[0]), abs(kf[1])) * self.glin
        self.lvl = LOG2DB * math.log(max(a, TINY_A))
        if a > A_FLOOR:
            vr = min(VR_CAP, self.vr_k * math.exp(self.eta * (math.log(a) - self.lref)))
        else:
            vr = 0.0

        # timing network; the diode only charges
        if self.l_k == 4:
            on = vr > self.vc1 + self.vc2
            e11, e12, e21, e22 = self.on_e if on else self.off_e
            f1 = self.f1 if on else 0.0
            f2 = self.f2 if on else 0.0
            n1 = e11 * self.vc1 + e12 * self.vc2 + f1 * vr
            n2 = e21 * self.vc1 + e22 * self.vc2 + f2 * vr
            self.vc1, self.vc2 = n1, n2
            self.v = n1 + n2
            if self.v > GR_MAX:
                k = GR_MAX / self.v
                self.vc1 *= k
                self.vc2 *= k
                self.v = GR_MAX
            if self.v < 0.000000001 and abs(self.vc1) < 0.000000001:
                self.vc1 = self.vc2 = self.v = 0.0
        else:
            if vr > self.v:
                self.v = self.v * self.e_on + self.f_on * vr
            else:
                self.v *= self.e_off
            if self.v > GR_MAX:
                self.v = GR_MAX
            if self.v < 0.000000001:
                self.v = 0.0
        self.gr = self.v
        glin = math.exp(-self.gr * DB2LOG)
        self.glin = glin

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
        self.mtr_gr1 += (self.gr - self.mtr_gr1) * self.m_a
        self.mtr_gr += (self.mtr_gr1 - self.mtr_gr) * self.m_a
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
