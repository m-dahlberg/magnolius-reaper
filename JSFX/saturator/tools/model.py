#!/usr/bin/env python3
"""Pure-Python reference model of "Magnolius_Saturator.jsfx".

Mirrors @init / recalc() / @sample sample-for-sample, so the render tests can
assert an exact waveform instead of a hand-derived "about right".

    THE MODEL AND THE .jsfx MUST BE EDITED TOGETHER.  If you change the DSP in
    one and not the other, render_test.py's `model` test fails and that
    failure is the point -- do not "fix" it by loosening the tolerance.

Stdlib only; there is no numpy on this box.

Signal flow, per channel (see the .jsfx header for the reasoning):

    x -> Input gain -> [upsample 1x/2x/4x]
      -> Slew      y += sign(d) sin(min(|d| sR, pi/2)) / (sR),  d = x - y
      -> Asymmetric (1-A)x + A (sin(g x + b) - sin b)/(g cos b)
      -> Symmetric  (1-S)x + S f_k(g x)/g,  f_k(u) = sin(u|u|^k)/|u|^k
      -> residual DC blocker: out = dry + HPF(stages - dry)
      -> auto gain, Mix against the aligned dry  -> [ADAA droop EQ]
      -> [downsample] -> Output gain

At 2x and 4x both curves run first-order ADAA (antiderivative anti-aliasing),
which delays the curves' linear part by half an OS sample each.  The "aligned
dry" gets exactly the same (x + x[-1])/2 twice, so the residual is purely the
nonlinear part and Mix never comb-filters; a fixed FIR then undoes the
cos^2(w/2) droop that this leaves on everything.
"""
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
JSFX = os.path.join(HERE, "..", "Magnolius_Saturator.jsfx")

DB2LOG = 0.11512925464970229     # ln(10)/20
HALF_PI = 1.5707963267948966

# ---- the same names and values as the .jsfx @init block --------------------
SM_T = 0.020            # s, one-pole smoothing of every continuous control
KNEE_T = 0.020          # s, Knee crossfade
SNAP = 10.0 ** -9       # a smoothed value this close to its target lands on it
SLEW_MAX = 5.0          # sigma at Slew 100 %          (tuned by measurement)
SLEW_REF = 48000.0      # Hz; R = OS rate / SLEW_REF   (derived: Desk ran at 48k)
ASYM_DRIVE = 1.0        # g = 1 + ASYM_DRIVE*A          (brief)
B_MAX = 0.7             # rad, bias at Asymmetric 100 % (brief: 0.6..0.8)
SYM_DRIVE = 2.0         # g = 1 + SYM_DRIVE*S           (brief)
KNEE_K = (0.25, 1.0, 4.0)   # Soft Mojo, Medium Spiral, Hard Dyno (brief)
DC_HZ = 5.0             # residual DC blocker corner    (brief)
ADAA_EPS = 10.0 ** -5   # below this |du| ADAA falls back to the midpoint
FT_N = 512              # antiderivative table intervals per knee
FT_SUB = 16             # Simpson sub-steps per table interval
K1, BETA1 = 20, 9.0     # stage-1 halfband: 4*K1+1 = 81 taps, Kaiser beta
K2, BETA2 = 5, 8.0      # stage-2 halfband (4x only): 21 taps
AG_BLK = 32             # samples between auto-gain table lookups
AG_NG, AG_NS, AG_NA, AG_NY = 7, 5, 5, 5   # Input, Slew, Asym, Sym grid points
AG_GMIN, AG_GSTEP = -18.0, 6.0            # Input grid, dB

# ADAA droop compensation (tools/design_comp.py).
COMP2 = (1.642011249509201, -0.275565674839325, -0.090029061094229,
         0.034179753494105, 0.030165175766037, -0.019755818081189)
COMP4 = (1.629164785203114, -0.275058902597427, -0.083032688526127,
         0.043509198521997)

OS_FACTOR = (1, 2, 4)
# latency in base samples: halfbands + (ADAA 1 OS sample + comp FIR) / OS
LAT = (0, 2 * K1 + (1 + 5) // 2, 2 * K1 + K2 + (1 + 3) // 4)

NAMES = ["input_db", "slew", "asym", "sym", "knee", "output_db",
         "auto_gain", "mix", "os_i"]
DEFAULTS = dict(input_db=0.0, slew=0.0, asym=0.0, sym=0.0, knee=1,
                output_db=0.0, auto_gain=1, mix=100.0, os_i=1)
LABELS = ["Input (dB)", "Slew (%)", "Asymmetric (%)", "Symmetric (%)",
          "Knee", "Output (dB)", "Auto Gain", "Mix (%)", "Oversampling"]


# ---------------------------------------------------------------------------
# design helpers (@init)
# ---------------------------------------------------------------------------

def kaiser_i0(x):
    s = t = 1.0
    for k in range(1, 26):
        t *= (x * 0.5 / k) ** 2
        s += t
    return s


def halfband(K, beta):
    """Odd-offset taps c[1..K] of a Kaiser halfband with 4K+1 taps; the
    centre tap is 0.5 and the taps sum to a DC gain of exactly 1."""
    b0 = kaiser_i0(beta)
    c = [0.0] * (K + 1)
    tot = 0.0
    for i in range(1, K + 1):
        j = 2 * i - 1
        w = kaiser_i0(beta * math.sqrt(1 - (j / (2.0 * K)) ** 2)) / b0
        c[i] = math.sin(math.pi * j * 0.5) / (math.pi * j) * w
        tot += c[i]
    return [v * 0.25 / tot for v in c]


def knee_vstar(k):
    """The peak of f_k: tan(v)/v = (k+1)/k, v = u|u|^k.  Clamping u there (not
    at v = pi/2, where f_k is already falling) is what flattens the curve
    with a continuous slope instead of folding it over."""
    t = (k + 1.0) / k
    lo, hi = 0.01, HALF_PI
    for _ in range(60):
        m = 0.5 * (lo + hi)
        if math.tan(m) / m < t:
            lo = m
        else:
            hi = m
    return 0.5 * (lo + hi)


class Knee:
    """f_k, its clamp and a Hermite table of its antiderivative F_k (even)."""

    def __init__(self, k):
        self.k = k
        v = knee_vstar(k)
        self.us = v ** (1.0 / (k + 1.0))
        self.fs = math.sin(v) / self.us ** k
        self.h = self.us / FT_N
        self.inv_h = FT_N / self.us
        self.fv = [self.f_raw(i * self.h) for i in range(FT_N + 1)]
        self.Fv = [0.0] * (FT_N + 1)
        acc = 0.0
        hs = self.h / FT_SUB
        for i in range(FT_N):
            u0 = i * self.h
            j = 0
            while j < FT_SUB:
                a = u0 + j * hs
                acc += hs / 6.0 * (self.f_raw(a) + 4.0 * self.f_raw(a + 0.5 * hs)
                                   + self.f_raw(a + hs))
                j += 1
            self.Fv[i + 1] = acc
        self.Fs = self.Fv[FT_N]

    def f_raw(self, a):
        """f_k for 0 <= a <= u*."""
        if a < 10.0 ** -12:
            return a
        p = a ** self.k
        return math.sin(a * p) / p

    def f(self, u):
        a = abs(u)
        if a >= self.us:
            r = self.fs
        elif a < 10.0 ** -12:
            return u
        else:
            p = a ** self.k
            r = math.sin(a * p) / p
        return r if u >= 0 else -r

    def F(self, u):
        a = abs(u)
        if a >= self.us:
            return self.Fs + self.fs * (a - self.us)
        t = a * self.inv_h
        i = int(t)
        if i > FT_N - 1:
            i = FT_N - 1
        t -= i
        t2 = t * t
        t3 = t2 * t
        return ((2 * t3 - 3 * t2 + 1) * self.Fv[i] + (t3 - 2 * t2 + t) * self.h * self.fv[i]
                + (3 * t2 - 2 * t3) * self.Fv[i + 1] + (t3 - t2) * self.h * self.fv[i + 1])


KNEES = None


def knees():
    global KNEES
    if KNEES is None:
        KNEES = [Knee(k) for k in KNEE_K]
    return KNEES


def read_ag_table(path=JSFX):
    """The auto-gain table lives in the .jsfx (written by calibrate.py), so the
    model reads it from there: one source of truth."""
    n = 3 * AG_NG * AG_NS * AG_NA * AG_NY
    tab = [0.0] * n
    if not os.path.exists(path):
        return tab
    src = open(path).read()
    m = re.search(r"// >>> AUTOGAIN TABLE(.*?)// <<< AUTOGAIN TABLE", src, re.S)
    if not m:
        return tab
    for row in re.finditer(r"ag_row\((\d+),([^)]*)\)", m.group(1)):
        base = int(row.group(1)) * AG_NY
        for j, v in enumerate(row.group(2).split(",")):
            tab[base + j] = float(v)
    return tab


# ---------------------------------------------------------------------------
# the plugin
# ---------------------------------------------------------------------------

class Channel:
    def __init__(self, p):
        self.p = p
        self.reset()

    def reset(self):
        self.up1 = [0.0] * 64
        self.up2 = [0.0] * 64
        self.d2e = [0.0] * 64
        self.d2o = [0.0] * 64
        self.d1e = [0.0] * 64
        self.d1o = [0.0] * 64
        self.cr = [0.0] * 16
        self.i1 = self.i2 = self.ic = 0
        self.s_y = 0.0          # slew output memory
        self.a_xp = 0.0         # asym ADAA previous input
        self.y_xp = 0.0         # sym ADAA previous input
        self.d_p1 = self.d_p2 = 0.0   # aligned dry
        self.r_p = self.h_p = 0.0     # residual DC blocker

    # one OS-rate sample through slew -> asym -> sym -> DC -> mix -> comp
    def os_sample(self, v):
        p = self.p
        adaa = p.adaa
        # slew
        if p.sR > 0:
            d = v - self.s_y
            st = math.sin(min(abs(d) * p.sR, HALF_PI)) * p.inv_sR
            self.s_y += st if d >= 0 else -st
        else:
            self.s_y = v
        s = self.s_y
        # asymmetric
        A = p.A
        if adaa:
            xp = self.a_xp
            self.a_xp = s
            if A > 0:
                dx = s - xp
                if abs(dx * p.ga) > ADAA_EPS:
                    c = (p.asym_C(s) - p.asym_C(xp)) / dx
                else:
                    c = p.asym_c((s + xp) * 0.5)
                a = (1 - A) * ((s + xp) * 0.5) + A * c
            else:
                a = (s + xp) * 0.5
        else:
            a = (1 - A) * s + A * p.asym_c(s) if A > 0 else s
        # symmetric
        S = p.S
        if adaa:
            xp = self.y_xp
            self.y_xp = a
            if S > 0:
                u1 = p.gs * a
                u0 = p.gs * xp
                du = u1 - u0
                f = 0.0
                if abs(du) > ADAA_EPS:
                    for kn, w in zip(knees(), p.kw):
                        if w > 0:
                            f += w * (kn.F(u1) - kn.F(u0))
                    f = f / du * p.gsinv
                else:
                    um = (u1 + u0) * 0.5
                    for kn, w in zip(knees(), p.kw):
                        if w > 0:
                            f += w * kn.f(um)
                    f *= p.gsinv
                y = (1 - S) * ((a + xp) * 0.5) + S * f
            else:
                y = (a + xp) * 0.5
        else:
            if S > 0:
                u = p.gs * a
                f = 0.0
                for kn, w in zip(knees(), p.kw):
                    if w > 0:
                        f += w * kn.f(u)
                y = (1 - S) * a + S * f * p.gsinv
            else:
                y = a
        # aligned dry: the curves' linear part, exactly
        if adaa:
            d1 = (v + self.d_p1) * 0.5
            dd = (d1 + self.d_p2) * 0.5
            self.d_p1 = v
            self.d_p2 = d1
        else:
            dd = v
        # residual DC blocker
        r = y - dd
        h = r - self.r_p + p.r_dc * self.h_p
        self.r_p = r
        self.h_p = h
        o = dd * p.dry_k + (dd + h) * p.wet_k
        if not adaa:
            return o
        # ADAA droop compensation (symmetric FIR, ring of 16)
        cr = self.cr
        ic = self.ic
        cr[ic] = o
        t = p.comp
        L = len(t) - 1
        acc = t[0] * cr[(ic - L) & 15]
        for k in range(1, L + 1):
            acc += t[k] * (cr[(ic - L + k) & 15] + cr[(ic - L - k) & 15])
        self.ic = (ic + 1) & 15
        return acc

    def up(self, ring, idx, x, c, K):
        ring[idx & 63] = x
        e = ring[(idx - K) & 63]
        o = 0.0
        for i in range(1, K + 1):
            o += c[i] * (ring[(idx - (K - 1) - i) & 63] + ring[(idx - K + i) & 63])
        return e, 2.0 * o

    def dec(self, re_, ro, idx, c, K):
        y = 0.5 * re_[(idx - K) & 63]
        for i in range(1, K + 1):
            y += c[i] * (ro[(idx - K - i) & 63] + ro[(idx - K - 1 + i) & 63])
        return y

    def process(self, x):
        p = self.p
        v = x * p.gin
        f = p.os_cur
        if f == 1:
            return self.os_sample(v)
        i1 = self.i1
        e1, o1 = self.up(self.up1, i1, v, p.c1, K1)
        if f == 2:
            self.d1e[i1 & 63] = self.os_sample(e1)
            self.d1o[i1 & 63] = self.os_sample(o1)
        else:
            for w, ring in ((e1, self.d1e), (o1, self.d1o)):
                i2 = self.i2
                e2, o2 = self.up(self.up2, i2, w, p.c2, K2)
                self.d2e[i2 & 63] = self.os_sample(e2)
                self.d2o[i2 & 63] = self.os_sample(o2)
                ring[i1 & 63] = self.dec(self.d2e, self.d2o, i2, p.c2, K2)
                self.i2 = i2 + 1
        y = self.dec(self.d1e, self.d1o, i1, p.c1, K1)
        self.i1 = i1 + 1
        return y


class Model:
    def __init__(self, srate=48000, ag_table=None, **sliders):
        self.srate = float(srate)
        self.c1 = halfband(K1, BETA1)
        self.c2 = halfband(K2, BETA2)
        knees()
        self.ag = ag_table if ag_table is not None else read_ag_table()
        self.v = dict(DEFAULTS)
        self.v.update(sliders)
        self.chL = Channel(self)
        self.chR = Channel(self)
        self.os_cur = OS_FACTOR[int(self.v["os_i"])]
        self.recalc()
        self.snap()

    # -- recalc(): everything derived from the sliders -----------------------
    def recalc(self):
        v = self.v
        self.gin_t = v["input_db"]
        self.out_t = v["output_db"]
        self.sl_t = v["slew"] * 0.01
        self.a_t = v["asym"] * 0.01
        self.s_t = v["sym"] * 0.01
        self.knee_t = min(max(int(math.floor(v["knee"] + 0.5)), 0), 2)
        self.aw_t = 1.0 if v["auto_gain"] > 0.5 else 0.0
        self.m_t = v["mix"] * 0.01
        self.os_t = OS_FACTOR[min(max(int(math.floor(v["os_i"] + 0.5)), 0), 2)]
        self.sm_a = 1 - math.exp(-1 / (SM_T * self.srate))
        self.kn_step = 1 / (KNEE_T * self.srate)

    def set(self, **sliders):
        self.v.update(sliders)
        self.recalc()

    def snap(self):
        self.gin_db = self.gin_t
        self.out_db = self.out_t
        self.sl = self.sl_t
        self.A = self.a_t
        self.S = self.s_t
        self.aw = self.aw_t
        self.mix = self.m_t
        self.kw = [0.0, 0.0, 0.0]
        self.kw[self.knee_t] = 1.0
        self.os_cur = self.os_t
        self.rate_params()
        self.ag_db = self.ag_lookup()
        self.ag_step = 0.0
        self.ag_cnt = 0

    def rate_params(self):
        f = self.os_cur
        self.adaa = f > 1
        self.r_dc = math.exp(-2 * math.pi * DC_HZ / (self.srate * f))
        self.rr = self.srate * f / SLEW_REF
        self.comp = COMP2 if f == 2 else COMP4

    # -- auto-gain table -------------------------------------------------------
    def ag_interp(self, k):
        tab = self.ag
        cg = min(max((self.gin_db - AG_GMIN) / AG_GSTEP, 0.0), AG_NG - 1.0)
        cs = min(max(self.sl * (AG_NS - 1), 0.0), AG_NS - 1.0)
        ca = min(max(self.A * (AG_NA - 1), 0.0), AG_NA - 1.0)
        cy = min(max(self.S * (AG_NY - 1), 0.0), AG_NY - 1.0)
        ig = min(int(cg), AG_NG - 2); fg = cg - ig
        is_ = min(int(cs), AG_NS - 2); fs = cs - is_
        ia = min(int(ca), AG_NA - 2); fa = ca - ia
        iy = min(int(cy), AG_NY - 2); fy = cy - iy
        acc = 0.0
        for jg in (0, 1):
            wg = fg if jg else 1 - fg
            for js in (0, 1):
                ws = wg * (fs if js else 1 - fs)
                for ja in (0, 1):
                    wa = ws * (fa if ja else 1 - fa)
                    base = (((k * AG_NG + ig + jg) * AG_NS + is_ + js) * AG_NA + ia + ja) * AG_NY + iy
                    acc += wa * ((1 - fy) * tab[base] + fy * tab[base + 1])
        return acc

    def ag_lookup(self):
        acc = 0.0
        for k in range(3):
            if self.kw[k] > 0:
                acc += self.kw[k] * self.ag_interp(k)
        return acc

    # -- curves (parameters set per base sample) ------------------------------
    def asym_c(self, x):
        if x > self.xu:
            return self.c_hi
        if x < self.xl:
            return self.c_lo
        return (math.sin(self.ga * x + self.b) - self.sb) * self.ainv

    def asym_C(self, x):
        if x > self.xu:
            return self.C_hi + self.c_hi * (x - self.xu)
        if x < self.xl:
            return self.C_lo + self.c_lo * (x - self.xl)
        return (-math.cos(self.ga * x + self.b) * self.gainv - x * self.sb) * self.ainv

    # -- one base sample ----------------------------------------------------
    def tick(self):
        a = self.sm_a

        def sm(x, t):
            x += a * (t - x)
            return t if abs(t - x) < SNAP else x
        self.gin_db = sm(self.gin_db, self.gin_t)
        self.out_db = sm(self.out_db, self.out_t)
        self.sl = sm(self.sl, self.sl_t)
        self.A = sm(self.A, self.a_t)
        self.S = sm(self.S, self.s_t)
        self.aw = sm(self.aw, self.aw_t)
        self.mix = sm(self.mix, self.m_t)
        # Knee: the target weight ramps up, the others share what is left
        kw = self.kw
        kt = self.knee_t
        if kw[kt] < 1:
            old = kw[kt]
            new = min(1.0, old + self.kn_step)
            sc = (1 - new) / (1 - old)
            for k in range(3):
                kw[k] = new if k == kt else kw[k] * sc
        # oversampling change: a setup control, so a plain reset
        if self.os_t != self.os_cur:
            self.os_cur = self.os_t
            self.chL.reset()
            self.chR.reset()
            self.rate_params()
        # per-sample parameters shared by both channels
        self.gin = math.exp(self.gin_db * DB2LOG)
        ginv = math.exp(-self.gin_db * DB2LOG)
        self.gout = math.exp(self.out_db * DB2LOG)
        sig = SLEW_MAX * self.sl * self.sl
        self.sR = sig * self.rr
        self.inv_sR = 1 / self.sR if self.sR > 0 else 0.0
        A = self.A
        self.ga = 1 + ASYM_DRIVE * A
        self.gainv = 1 / self.ga
        self.b = A * B_MAX
        self.sb = math.sin(self.b)
        cb = math.cos(self.b)
        self.ainv = 1 / (self.ga * cb)
        self.xu = (HALF_PI - self.b) * self.gainv
        self.xl = (-HALF_PI - self.b) * self.gainv
        self.c_hi = (1 - self.sb) * self.ainv
        self.c_lo = (-1 - self.sb) * self.ainv
        self.C_hi = -self.xu * self.sb * self.ainv
        self.C_lo = -self.xl * self.sb * self.ainv
        self.gs = 1 + SYM_DRIVE * self.S
        self.gsinv = 1 / self.gs
        # auto gain: table every AG_BLK samples, linear ramp in between
        if self.ag_cnt <= 0:
            self.ag_step = (self.ag_lookup() - self.ag_db) / AG_BLK
            self.ag_cnt = AG_BLK
        self.ag_cnt -= 1
        self.ag_db += self.ag_step
        gw = 1 - self.aw + self.aw * ginv * math.exp(self.ag_db * DB2LOG)
        self.dry_k = (1 - self.mix) * ginv
        self.wet_k = self.mix * gw

    def process(self, left, right=None, changes=None):
        """changes: {sample_index: {slider: value}} applied before that sample."""
        right = left if right is None else right
        ol, orr = [], []
        for n in range(len(left)):
            if changes and n in changes:
                self.set(**changes[n])
            self.tick()
            ol.append(self.chL.process(left[n]) * self.gout)
            orr.append(self.chR.process(right[n]) * self.gout)
        return ol, orr

    def latency(self):
        return LAT[OS_FACTOR.index(self.os_cur)]
