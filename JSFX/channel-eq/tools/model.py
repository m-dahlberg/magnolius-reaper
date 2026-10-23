"""Reference model for Magnolius_ChannelEQ.jsfx.

Pure Python (stdlib only).  It does three jobs, and the .jsfx and this file
must be edited together:

  1. the knob laws and the analog prototypes of every section;
  2. the magnitude-matched digital design (poles mapped exactly, numerator
     fitted to the analog magnitude at DC, at a mid frequency and at Nyquist),
     which is what removes the cramping a plain bilinear transform has near
     Nyquist;
  3. a sample-exact mirror of the plugin's @sample loop (coefficient glide,
     direct form I, idle skipping), so a render can be compared to it.

Slider positions are what the plugin stores:
  gains  -1..1 (rotation r),  frequencies / Q  0..1 (t),
  HPF  0..1  (0 = OUT, the counter-clockwise stop),
  LPF  0..1  (1 = OUT, the clockwise stop).
"""
import cmath
import math

# --------------------------------------------------------------------------
# slider layout (order of the header in the .jsfx)
# --------------------------------------------------------------------------
NAMES = ["eq_in", "flt_in", "hpf", "lpf",
         "lf_g", "lf_f", "lmf_g", "lmf_f", "lmf_q", "lmf_d3",
         "hmf_g", "hmf_f", "hmf_q", "hmf_x3", "hf_g", "hf_f",
         "gain_law", "sat_amt", "sat_mode"]
DEFAULTS = dict(eq_in=1, flt_in=1, hpf=0.0, lpf=1.0,
                lf_g=0.0, lf_f=0.5, lmf_g=0.0, lmf_f=0.5, lmf_q=0.25, lmf_d3=0,
                hmf_g=0.0, hmf_f=0.5, hmf_q=0.25, hmf_x3=0, hf_g=0.0, hf_f=0.5,
                gain_law=0, sat_amt=0.0, sat_mode=0)

# --------------------------------------------------------------------------
# gain law.  Boost at the plateau / centre for rotation 0, 0.1 .. 1.0.
# Cut mirrors boost exactly.
# --------------------------------------------------------------------------
TAB_MID = [0, 2.4, 4.5, 6.5, 8.3, 10.2, 12.0, 13.9, 16.0, 18.3, 21.0]
TAB_HF = [0, 0.9, 1.8, 2.8, 3.9, 5.1, 6.6, 8.3, 10.7, 14.1, 20.3]
TAB_LF = [0, 0.9, 2.0, 3.0, 4.2, 5.5, 7.1, 8.8, 11.0, 14.0, 18.4]


def tab_interp(tab, k):
    k = min(1.0, max(0.0, k)) * 10.0
    i = min(9, int(k))
    return tab[i] + (tab[i + 1] - tab[i]) * (k - i)


def gain_db(tab, r, law):
    """Signed gain in dB for rotation r.  law 0 = circuit, 1 = linear in dB."""
    k = abs(r)
    g = k * tab[10] if law >= 0.5 else tab_interp(tab, k)
    return g if r >= 0 else -g


# --------------------------------------------------------------------------
# frequency / Q laws: printed numbers evenly spread round the knob, the law is
# piecewise log-linear through them, normalised to u = 0..1 between the first
# and the last number.
# --------------------------------------------------------------------------
LEG_LF = [30, 50, 100, 200, 300, 450]
LEG_LMF = [200, 300, 800, 1000, 1500, 2000, 2500]
LEG_HMF = [600, 800, 1500, 3000, 4500, 6000, 7000]
LEG_HF = [1500, 2000, 5000, 8000, 10000, 11000, 16000]
LEG_Q = [0.5, 1, 1.5, 2, 3]
LEG_HPF = [20, 70, 120, 200, 300, 350]          # at t = 1/6 .. 1
LEG_LPF = [3000, 3500, 4000, 5000, 8000, 12000]  # at t = 0 .. 5/6


def pw_log(t, xs, ys):
    """Piecewise-linear interpolation of ln(y) through (x, y), extrapolating the end segments."""
    n = len(xs)
    i = 0
    while i < n - 2 and t > xs[i + 1]:
        i += 1
    x0, x1 = xs[i], xs[i + 1]
    l0, l1 = math.log(ys[i]), math.log(ys[i + 1])
    return l0 + (l1 - l0) * (t - x0) / (x1 - x0)


def legend_u(t, leg):
    n = len(leg)
    xs = [k / (n - 1) for k in range(n)]
    lo, hi = math.log(leg[0]), math.log(leg[-1])
    return (pw_log(min(1.0, max(0.0, t)), xs, leg) - lo) / (hi - lo)


def q0_of(t):
    """Network Q of the mid bands for knob position t (printed 0.5 .. 3)."""
    uq = (pw_log(t, [k / 4 for k in range(5)], LEG_Q) - math.log(0.5)) / math.log(6.0)
    return Q0_MIN * (Q0_MAX / Q0_MIN) ** uq


Q0_MIN, Q0_MAX = 0.73, 2.95

# circuit end-stops
HMF_RANGE = (605.0, 6200.0)
HMF_X3 = 5.02 / 1.72                 # capacitor ratio, normal -> x3
LMF_RANGE = (202.0, 2070.0)
LMF_D3 = (15.0 + 47.0) / 15.0        # drawn values: /4.13 (the label says 3, see README)
HF_C = 26.7e-9
HF_R1_0, HF_R1_P = 2400.0, 23500.0   # feedback leg: fixed + pot
HF_R2_0, HF_R2_P = 5100.0, 47000.0   # ground leg
LF_W1, LF_W2 = 0.467, 0.019
LF_C1, LF_C2 = 15e-9, 470e-9
LF_R_MAX, LF_R_MIN = 48480.0, 4165.0  # calibrated so the full-boost corner spans 31 .. 361 Hz
LF_KAPPA = (1.01056685, 0.000220316, 6.712891e-06)   # makes the response PEAK equal the table gain

HPF_MIN, HPF_MAX = 14.8, 402.0
HPF_OUT_T = 0.03
LPF_MIN, LPF_MAX = 3200.0, 72000.0
LPF_OUT_T = 0.97
LPF_Q = 0.5 * math.sqrt(6.8 / 3.3)


def hf_omega(u):
    w_lo = 1.0 / (HF_C * math.sqrt((HF_R1_0 + HF_R1_P) * (HF_R2_0 + HF_R2_P)))
    w_hi = 1.0 / (HF_C * math.sqrt(HF_R1_0 * HF_R2_0))
    return w_lo * (w_hi / w_lo) ** u


def hf_legs(w0):
    """Pot fraction y (0 = max frequency) and the two network resistors for a given omega0."""
    K = (1.0 / (HF_C * w0)) ** 2
    a = HF_R1_P * HF_R2_P
    b = HF_R1_0 * HF_R2_P + HF_R1_P * HF_R2_0
    c0 = HF_R1_0 * HF_R2_0 - K
    y = (-b + math.sqrt(b * b - 4 * a * c0)) / (2 * a)
    y = min(1.0, max(0.0, y))
    return HF_R1_0 + HF_R1_P * y, HF_R2_0 + HF_R2_P * y


def lf_r(u):
    return LF_R_MAX * (LF_R_MIN / LF_R_MAX) ** u


# --------------------------------------------------------------------------
# analog prototypes: (n2, n1, n0, d2, d1, d0) in S (rad/s)
# --------------------------------------------------------------------------
def bell_proto(w0, q0, g_db):
    A = 10 ** (abs(g_db) / 20.0) - 1.0
    n = (1.0, (1.0 + A) * w0 / q0, w0 * w0)
    d = (1.0, w0 / q0, w0 * w0)
    return (n + d) if g_db >= 0 else (d + n)


def hf_proto(w0, g_db):
    """Shelf from the 2nd-order high-pass network.  T = D0 / (D0 - c S^2) for boost."""
    R1, R2 = hf_legs(w0)
    G = 10 ** (abs(g_db) / 20.0)
    c = 1.0 - 1.0 / G
    d0 = (1.0, 2.0 / (R2 * HF_C), 1.0 / (R1 * R2 * HF_C * HF_C))
    dc = ((1.0 - c), d0[1], d0[2])
    return (d0 + dc) if g_db >= 0 else (dc + d0)


def lf_proto(r_pot, g_db):
    T1, T2 = r_pot * LF_C1, r_pot * LF_C2
    G = 10 ** (abs(g_db) / 20.0)
    ga = abs(g_db)
    c = (1.0 - 1.0 / G) / (LF_W1 + LF_W2) * (LF_KAPPA[0] + ga * (LF_KAPPA[1] + ga * LF_KAPPA[2]))
    d = (T1 * T2, T1 + T2, 1.0)
    dc = (T1 * T2, T1 + T2 - c * T2 * (LF_W1 + LF_W2), 1.0 - c * LF_W1)
    return (d + dc) if g_db >= 0 else (dc + d)


def analog_sections(p, fs):
    """List of (name, kind, proto) for the current parameters, before any digital design.

    kind: 'hp1' (n1, n0, d1, d0 inside a 6-tuple), 'biq'.  Frequencies are clamped to 0.45 fs.
    """
    out = []
    fmax = 0.45 * fs
    law = p["gain_law"]
    # filters
    if p["flt_in"] >= 0.5:
        t = p["hpf"]
        if t >= HPF_OUT_T:
            xs = [(k + 1) / 6 for k in range(6)]
            f = math.exp(pw_log(t, xs, LEG_HPF))
            f = min(min(HPF_MAX, fmax), max(HPF_MIN, f))
            w = 2 * math.pi * f
            out.append(("hpf1", "hp1", (0.0, 1.0, 0.0, 0.0, 1.0, w)))
            out.append(("hpf2", "biq", (1.0, 0.0, 0.0, 1.0, w, w * w)))
        t = p["lpf"]
        if t <= LPF_OUT_T:
            xs = [k / 6 for k in range(6)]
            f = math.exp(pw_log(t, xs, LEG_LPF))
            f = min(min(LPF_MAX, fmax), max(LPF_MIN, f))
            w = 2 * math.pi * f
            out.append(("lpf", "biq", (0.0, 0.0, w * w, 1.0, w / LPF_Q, w * w)))
    # bands, card order HF -> HMF -> LF -> LMF
    if p["eq_in"] >= 0.5:
        g = gain_db(TAB_HF, p["hf_g"], law)
        if abs(g) > 1e-9:
            w = min(hf_omega(legend_u(p["hf_f"], LEG_HF)), 2 * math.pi * fmax)
            out.append(("hf", "biq", hf_proto(w, g)))
        g = gain_db(TAB_MID, p["hmf_g"], law)
        if abs(g) > 1e-9:
            f = HMF_RANGE[0] * (HMF_RANGE[1] / HMF_RANGE[0]) ** legend_u(p["hmf_f"], LEG_HMF)
            f = min(f * (HMF_X3 if p["hmf_x3"] >= 0.5 else 1.0), fmax)
            out.append(("hmf", "biq", bell_proto(2 * math.pi * f, q0_of(p["hmf_q"]), g)))
        g = gain_db(TAB_LF, p["lf_g"], law)
        if abs(g) > 1e-9:
            out.append(("lf", "biq", lf_proto(lf_r(legend_u(p["lf_f"], LEG_LF)), g)))
        g = gain_db(TAB_MID, p["lmf_g"], law)
        if abs(g) > 1e-9:
            f = LMF_RANGE[0] * (LMF_RANGE[1] / LMF_RANGE[0]) ** legend_u(p["lmf_f"], LEG_LMF)
            f = min(f / (LMF_D3 if p["lmf_d3"] >= 0.5 else 1.0), fmax)
            out.append(("lmf", "biq", bell_proto(2 * math.pi * f, q0_of(p["lmf_q"]), g)))
    return out


def analog_mag(proto, f):
    n2, n1, n0, d2, d1, d0 = proto
    s = 2j * math.pi * f
    return abs((n2 * s * s + n1 * s + n0) / (d2 * s * s + d1 * s + d0))


def analog_total(p, fs, f):
    m = 1.0
    for _, _, proto in analog_sections(p, fs):
        m *= analog_mag(proto, f)
    return m


# --------------------------------------------------------------------------
# magnitude-matched digital design
# --------------------------------------------------------------------------
IDENT = (1.0, 0.0, 0.0, 0.0, 0.0)           # b0 b1 b2 a1 a2


def _roots(c2, c1, c0):
    if abs(c2) < 1e-300:
        return [-c0 / c1]
    disc = cmath.sqrt(c1 * c1 - 4 * c2 * c0)
    return [(-c1 + disc) / (2 * c2), (-c1 - disc) / (2 * c2)]


def _pwr(poly, w):
    s = 1j * w
    v = poly[0] * s * s + poly[1] * s + poly[2]
    return v.real * v.real + v.imag * v.imag


def matched_biquad(proto, fs):
    """Poles mapped exactly; b0..b2 from the analog |H|^2 at DC, mid and Nyquist."""
    n = proto[:3]
    d = proto[3:]
    T = 1.0 / fs
    wN = math.pi * fs
    pz = [cmath.exp(r * T) for r in _roots(*d)]
    a1 = -(pz[0] + pz[1]).real
    a2 = (pz[0] * pz[1]).real
    A0 = (1 + a1 + a2) ** 2
    A1 = (1 - a1 + a2) ** 2
    A2 = -4 * a2

    def mag2(w):
        return _pwr(n, w) / _pwr(d, w)

    # mid frequency: geometric mean of the non-zero analog root magnitudes
    mags = [abs(r) for r in _roots(*d) + (_roots(*n) if abs(n[0]) + abs(n[1]) > 0 else [])
            if abs(r) > 1e-9]
    wm = math.exp(sum(math.log(m) for m in mags) / len(mags))
    wm = min(wm, 0.9 * wN)
    B0 = mag2(0.0) * A0
    B1 = mag2(wN) * A1
    ph1 = math.sin(wm * T / 2) ** 2
    ph0 = 1 - ph1
    ph2 = 4 * ph0 * ph1
    den_m = A0 * ph0 + A1 * ph1 + A2 * ph2
    B2 = (mag2(wm) * den_m - B0 * ph0 - B1 * ph1) / ph2
    W = (math.sqrt(B0) + math.sqrt(B1)) / 2
    disc = W * W + B2
    if disc < 0:
        return bilinear(proto, fs, wm), True
    b1 = (math.sqrt(B0) - math.sqrt(B1)) / 2
    sd = math.sqrt(disc)
    r1, r2 = (W + sd) / 2, (W - sd) / 2
    b0, b2 = (r1, r2) if abs(r1) >= abs(r2) else (r2, r1)
    return (b0, b1, b2, a1, a2), False


def matched_onepole_hp(w, fs):
    """S / (S + w): exact pole, zero at DC, gain fitted at Nyquist."""
    T = 1.0 / fs
    wN = math.pi * fs
    p = math.exp(-w * T)
    m = wN / math.sqrt(wN * wN + w * w)
    b0 = m * (1 + p) / 2
    return (b0, -b0, 0.0, -p, 0.0)


def bilinear(proto, fs, wp):
    """Plain bilinear transform prewarped at wp (fallback only)."""
    K = wp / math.tan(wp / fs / 2)
    n2, n1, n0, d2, d1, d0 = proto
    b = (n2 * K * K + n1 * K + n0, 2 * (n0 - n2 * K * K), n2 * K * K - n1 * K + n0)
    a = (d2 * K * K + d1 * K + d0, 2 * (d0 - d2 * K * K), d2 * K * K - d1 * K + d0)
    return (b[0] / a[0], b[1] / a[0], b[2] / a[0], a[1] / a[0], a[2] / a[0])


# --------------------------------------------------------------------------
# refinement: a short Levenberg-Marquardt fit of all five coefficients to the
# analog log-magnitude.  The matched design above is the starting point (it is
# exact at three frequencies); the fit then removes what three points cannot
# capture, e.g. a pole near or above Nyquist, which a 2nd-order digital section
# can only approximate.  Weight 1 up to 15 kHz, 0.3 from there to 20 kHz.
# --------------------------------------------------------------------------
NPT = 40               # log-spaced points, 20 Hz .. FH1
NEXTRA = 6             # linear points FH1 .. FH2, lighter weight
FH1, FH2 = 15000.0, 20000.0
W_EXTRA = 0.1
LM_ITERS = 20
STAB_MARGIN = 1e-5


def _solve5(A, b):
    n = 5
    for i in range(n):
        p = i
        for r in range(i + 1, n):
            if abs(A[r][i]) > abs(A[p][i]):
                p = r
        if abs(A[p][i]) < 1e-30:
            return None
        A[i], A[p] = A[p], A[i]
        b[i], b[p] = b[p], b[i]
        for r in range(i + 1, n):
            f = A[r][i] / A[i][i]
            for c in range(i, n):
                A[r][c] -= f * A[i][c]
            b[r] -= f * b[i]
    x = [0.0] * n
    for i in range(n - 1, -1, -1):
        v = b[i]
        for j in range(i + 1, n):
            v -= A[i][j] * x[j]
        x[i] = v / A[i][i]
    return x


def _fit_grid(proto, fs):
    T = 1.0 / fs
    fh1 = min(FH1, 0.45 * fs)
    fh2 = min(FH2, 0.45 * fs)
    freqs, wts = [], []
    for i in range(NPT):
        freqs.append(20.0 * (fh1 / 20.0) ** (i / (NPT - 1)))
        wts.append(1.0)
    for i in range(1, NEXTRA + 1):
        freqs.append(fh1 + (fh2 - fh1) * i / NEXTRA)
        wts.append(W_EXTRA)
    pts = []
    for f, wg in zip(freqs, wts):
        w = 2 * math.pi * f
        tgt = 0.5 * math.log(_pwr(proto[:3], w) / _pwr(proto[3:], w))
        pts.append((math.cos(w * T), -math.sin(w * T), math.cos(2 * w * T), -math.sin(2 * w * T), tgt, wg))
    return pts


def _cost_resid(x, pts):
    b0, b1, b2, a1, a2 = x
    res = []
    for c1, s1, c2, s2, tgt, wg in pts:
        Nr = b0 + b1 * c1 + b2 * c2
        Ni = b1 * s1 + b2 * s2
        Dr = 1 + a1 * c1 + a2 * c2
        Di = a1 * s1 + a2 * s2
        res.append(wg * (0.5 * math.log((Nr * Nr + Ni * Ni) / (Dr * Dr + Di * Di)) - tgt))
    return res


def refine(proto, fs, x0):
    pts = _fit_grid(proto, fs)
    x = list(x0)
    res = _cost_resid(x, pts)
    cost = sum(v * v for v in res)
    lam = 1e-3
    for _ in range(LM_ITERS):
        AtA = [[0.0] * 5 for _ in range(5)]
        Atr = [0.0] * 5
        b0, b1, b2, a1, a2 = x
        for (c1, s1, c2, s2, tgt, wg), r in zip(pts, res):
            Nr = b0 + b1 * c1 + b2 * c2
            Ni = b1 * s1 + b2 * s2
            Dr = 1 + a1 * c1 + a2 * c2
            Di = a1 * s1 + a2 * s2
            n2 = Nr * Nr + Ni * Ni
            d2 = Dr * Dr + Di * Di
            J = (wg * Nr / n2, wg * (c1 * Nr + s1 * Ni) / n2, wg * (c2 * Nr + s2 * Ni) / n2,
                 -wg * (c1 * Dr + s1 * Di) / d2, -wg * (c2 * Dr + s2 * Di) / d2)
            for i in range(5):
                Atr[i] += J[i] * r
                for j in range(5):
                    AtA[i][j] += J[i] * J[j]
        improved = False
        for _try in range(8):
            A = [row[:] for row in AtA]
            for i in range(5):
                A[i][i] += lam * AtA[i][i] + 1e-30
            dx = _solve5(A, [-v for v in Atr])
            if dx is not None:
                xn = [x[i] + dx[i] for i in range(5)]
                if abs(xn[4]) < 1 - STAB_MARGIN and abs(xn[3]) < 1 + xn[4] - STAB_MARGIN:
                    rn = _cost_resid(xn, pts)
                    cn = sum(v * v for v in rn)
                    if cn < cost:
                        improved = cost - cn > 1e-9 * cost
                        x, res, cost = xn, rn, cn
                        lam = max(lam / 3, 1e-9)
                        break
            lam *= 10
        if not improved:
            break
    return tuple(x)


def design_biquad(proto, fs):
    x0, _ = matched_biquad(proto, fs)
    return refine(proto, fs, x0)


NSEC = 7
SEC_NAMES = ["hpf1", "hpf2", "lpf", "hf", "hmf", "lf", "lmf"]


def targets(p, fs):
    """Coefficient targets for the 7 fixed slots, identity when a section is off."""
    t = {n: IDENT for n in SEC_NAMES}
    for name, kind, proto in analog_sections(p, fs):
        if kind == "hp1":
            t[name] = matched_onepole_hp(proto[5], fs)
        else:
            t[name] = design_biquad(proto, fs)
    return [t[n] for n in SEC_NAMES]


def digital_mag(c, fs, f):
    b0, b1, b2, a1, a2 = c
    z1 = cmath.exp(-2j * math.pi * f / fs)
    z2 = z1 * z1
    return abs((b0 + b1 * z1 + b2 * z2) / (1 + a1 * z1 + a2 * z2))


def digital_total(p, fs, f):
    m = 1.0
    for c in targets(p, fs):
        m *= digital_mag(c, fs, f)
    return m


def stable(c):
    a1, a2 = c[3], c[4]
    return abs(a2) < 1 and abs(a1) < 1 + a2


# --------------------------------------------------------------------------
# sample-exact mirror of the plugin
# --------------------------------------------------------------------------
GLIDE_TAU = 0.010
SNAP = 1e-9


class Engine:
    """Mirrors @init / @sample.  Parameters are fixed per instance (the plugin
    recomputes at block boundaries; the render tests keep them constant)."""

    def __init__(self, params, fs):
        self.fs = fs
        self.kg = 1 - math.exp(-1.0 / (GLIDE_TAU * fs))
        self.tgt = [list(c) for c in targets(params, fs)]
        self.cur = [list(c) for c in self.tgt]
        self.idle = [self.tgt[s] == list(IDENT) for s in range(NSEC)]
        self.gl = [False] * NSEC
        self.st = [[[0.0] * 4 for _ in range(NSEC)] for _ in range(2)]   # x1 x2 y1 y2

    def set_params(self, params):
        for s, c in enumerate(targets(params, self.fs)):
            self.tgt[s] = list(c)
            if self.tgt[s] != self.cur[s]:
                self.gl[s] = True
                self.idle[s] = False

    def process(self, chans):
        n = len(chans[0])
        out = [list(chans[0]), list(chans[1])]
        kg = self.kg
        for i in range(n):
            for s in range(NSEC):
                cur, tgt = self.cur[s], self.tgt[s]
                if not self.idle[s]:
                    if self.gl[s]:
                        big = 0.0
                        for k in range(5):
                            cur[k] += (tgt[k] - cur[k]) * kg
                            big = max(big, abs(tgt[k] - cur[k]))
                        if big < SNAP:
                            cur[:] = tgt
                            self.gl[s] = False
                            if tgt == list(IDENT):
                                self.idle[s] = True
                for ch in range(2):
                    x = out[ch][i]
                    st = self.st[ch][s]
                    if self.idle[s]:
                        y = x
                    else:
                        y = cur[0] * x + cur[1] * st[0] + cur[2] * st[1] - cur[3] * st[2] - cur[4] * st[3]
                    st[1] = st[0]
                    st[0] = x
                    st[3] = st[2]
                    st[2] = y
                    out[ch][i] = y
        return out


def response_error_db(p, fs, freqs):
    """Largest |digital - analog| (dB) of the whole chain over freqs, designing once."""
    cs = targets(p, fs)
    secs = analog_sections(p, fs)
    worst = 0.0
    for f in freqs:
        if f >= 0.45 * fs:
            continue
        d = 1.0
        for c in cs:
            d *= digital_mag(c, fs, f)
        a = 1.0
        for _, _, proto in secs:
            a *= analog_mag(proto, f)
        worst = max(worst, abs(20 * math.log10(d) - 20 * math.log10(a)))
    return worst
