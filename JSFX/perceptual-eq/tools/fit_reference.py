#!/usr/bin/env python3
"""Reference implementation of the PerceptualEQ v0.7 correction fit.

Mirrors the EEL2 code in Magnolius_PerceptualEQ.jsfx step for step (same constants,
same clamps, same iteration structure) so render_test.py can predict the
plugin's magnitude response analytically. Keep the two in sync!
"""
import math
import cmath

BANDS = [40, 80, 125, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000,
         8000, 12000, 16000]
NBANDS = len(BANDS)
ANCHOR_IDX = 6

NFIT = 43
NGRID = 128
FITBWS = 1.6
FITSIG = 0.12
FITKW = 3.0
FITRND = 3
FITIT = 2
RIDGE = 0.001


def fit_bank():
    fb = []
    for i in range(NBANDS - 1):
        fb.append(BANDS[i])
        r3 = (BANDS[i + 1] / BANDS[i]) ** (1 / 3)
        fb.append(BANDS[i] * r3)
        fb.append(BANDS[i] * r3 * r3)
    fb.append(BANDS[-1])
    bw = []
    for j in range(NFIT):
        if j == 0:
            b = math.log2(fb[1] / fb[0])
        elif j == NFIT - 1:
            b = math.log2(fb[NFIT - 1] / fb[NFIT - 2])
        else:
            b = 0.5 * math.log2(fb[j + 1] / fb[j - 1])
        bw.append(b * FITBWS)
    return fb, bw


FITF, FITBW = fit_bank()


def bell_coefs(fc, bw, g, sr):
    """RBJ peaking biquad, cookbook warped-bandwidth alpha (as the plugin)."""
    a = 10 ** (g / 40)
    w0 = 2 * math.pi * fc / sr
    alpha = math.sin(w0) * math.sinh(0.5 * math.log(2) * bw * w0 / math.sin(w0))
    cw = math.cos(w0)
    ib0 = 1 / (1 + alpha / a)
    return ((1 + alpha * a) * ib0, -2 * cw * ib0, (1 - alpha * a) * ib0,
            -2 * cw * ib0, (1 - alpha / a) * ib0)


def biquad_mag2(c, f, sr):
    b0, b1, b2, a1, a2 = c
    w = 2 * math.pi * f / sr
    z = cmath.exp(-1j * w)
    num = b0 + b1 * z + b2 * z * z
    den = 1 + a1 * z + a2 * z * z
    return abs(num) ** 2 / max(abs(den) ** 2, 1e-10)


class FitReference:
    def __init__(self, sr=48000, maxboost=12.0, strength=100.0):
        self.sr = sr
        self.maxboost = maxboost
        self.strength = strength
        self.na = sum(1 for f in FITF if f <= 0.45 * sr)
        self.nk = sum(1 for f in BANDS if f <= 0.45 * sr)
        self.nrows = NGRID + self.nk
        self.xlo = math.log(40)
        self.xhi = math.log(min(16000, 0.45 * sr))
        self.gx = [self.xlo + (self.xhi - self.xlo) * k / (NGRID - 1)
                   for k in range(NGRID)]
        self.gf = [math.exp(x) for x in self.gx]
        self.kx = [math.log(f) for f in BANDS]
        self.step = (self.xhi - self.xlo) / (NGRID - 1) / math.log(2)
        self.krad = max(1, int(3 * FITSIG / self.step))
        kern = [math.exp(-0.5 * (k * self.step / FITSIG) ** 2)
                for k in range(-self.krad, self.krad + 1)]
        s = sum(kern)
        self.kern = [k / s for k in kern]
        # unit-gain shape matrix (dB), grid rows then weighted knot rows
        unit = [[10 * math.log10(max(biquad_mag2(
            bell_coefs(FITF[a], FITBW[a], 1.0, sr), f, sr), 1e-10))
            for a in range(self.na)] for f in self.gf]
        unit += [[FITKW * 10 * math.log10(max(biquad_mag2(
            bell_coefs(FITF[a], FITBW[a], 1.0, sr), BANDS[i], sr), 1e-10))
            for a in range(self.na)] for i in range(self.nk)]
        self.M = unit
        na = self.na
        A = [[sum(self.M[r][a] * self.M[r][b] for r in range(self.nrows))
              + (RIDGE if a == b else 0) for b in range(na)] for a in range(na)]
        L = [[0.0] * na for _ in range(na)]
        for a in range(na):
            for b in range(a + 1):
                s = A[a][b] - sum(L[a][k] * L[b][k] for k in range(b))
                L[a][b] = math.sqrt(max(s, 1e-10)) if a == b else s / L[b][b]
        self.L = L

    # -- PCHIP on the knots (Fritsch-Carlson, clamped one-sided endpoints) --
    def _slopes(self, y):
        n = NBANDS
        x = self.kx
        d = [0.0] * n
        for i in range(1, n - 1):
            h1 = x[i] - x[i - 1]
            h2 = x[i + 1] - x[i]
            s1 = (y[i] - y[i - 1]) / h1
            s2 = (y[i + 1] - y[i]) / h2
            if s1 * s2 <= 0:
                d[i] = 0.0
            else:
                w1 = 2 * h2 + h1
                w2 = h2 + 2 * h1
                d[i] = (w1 + w2) / (w1 / s1 + w2 / s2)
        h1 = x[1] - x[0]
        h2 = x[2] - x[1]
        s1 = (y[1] - y[0]) / h1
        s2 = (y[2] - y[1]) / h2
        d0 = ((2 * h1 + h2) * s1 - h1 * s2) / (h1 + h2)
        if d0 * s1 <= 0:
            d0 = 0.0
        elif s1 * s2 <= 0 and abs(d0) > 3 * abs(s1):
            d0 = 3 * s1
        d[0] = d0
        h1 = x[n - 1] - x[n - 2]
        h2 = x[n - 2] - x[n - 3]
        s1 = (y[n - 1] - y[n - 2]) / h1
        s2 = (y[n - 2] - y[n - 3]) / h2
        d0 = ((2 * h1 + h2) * s1 - h1 * s2) / (h1 + h2)
        if d0 * s1 <= 0:
            d0 = 0.0
        elif s1 * s2 <= 0 and abs(d0) > 3 * abs(s1):
            d0 = 3 * s1
        d[n - 1] = d0
        return d

    def _peval(self, y, d, x):
        kx = self.kx
        if x <= kx[0]:
            return y[0]
        if x >= kx[-1]:
            return y[-1]
        i = 0
        while x > kx[i + 1]:
            i += 1
        h = kx[i + 1] - kx[i]
        t = (x - kx[i]) / h
        t1 = 1 - t
        return ((1 + 2 * t) * t1 * t1 * y[i] + t * t1 * t1 * h * d[i]
                + t * t * (3 - 2 * t) * y[i + 1] + t * t * (t - 1) * h * d[i + 1])

    def _lin_at(self, T, x):
        p = (x - self.xlo) / (self.xhi - self.xlo) * (NGRID - 1)
        p = min(max(p, 0), NGRID - 1)
        k0 = min(int(p), NGRID - 2)
        fr = p - k0
        return T[k0] * (1 - fr) + T[k0 + 1] * fr

    def _smooth(self, vals):
        out = []
        for k in range(NGRID):
            acc = 0.0
            for i in range(-self.krad, self.krad + 1):
                acc += self.kern[i + self.krad] * vals[min(NGRID - 1, max(0, k + i))]
            out.append(acc)
        return out

    def target_curve(self, points):
        T = [0.0] * NGRID
        resid = list(points)
        for _ in range(FITRND):
            d = self._slopes(resid)
            add = self._smooth([self._peval(resid, d, x) for x in self.gx])
            T = [T[k] + add[k] for k in range(NGRID)]
            resid = [points[i] - self._lin_at(T, self.kx[i]) if i < self.nk else 0.0
                     for i in range(NBANDS)]
        return [max(-18.0, min(self.maxboost, t)) for t in T]

    def _solve(self, b):
        na = self.na
        L = self.L
        y = [0.0] * na
        for a in range(na):
            y[a] = (b[a] - sum(L[a][k] * y[k] for k in range(a))) / L[a][a]
        x = [0.0] * na
        for a in range(na - 1, -1, -1):
            x[a] = (y[a] - sum(L[k][a] * x[k] for k in range(a + 1, na))) / L[a][a]
        return x

    def cascade_db(self, gains, f):
        prod = 1.0
        for j in range(NFIT):
            if abs(gains[j]) < 0.001 or FITF[j] > 0.45 * self.sr:
                continue
            prod *= biquad_mag2(
                bell_coefs(FITF[j], FITBW[j], gains[j], self.sr), f, self.sr)
        return 10 * math.log10(max(prod, 1e-300))

    def point_targets(self, deviations):
        """deviations: 15 raw deviations (MEAS - ISOREL); anchor ignored."""
        pts = []
        for i, dv in enumerate(deviations):
            if i == ANCHOR_IDX:
                pts.append(0.0)
            else:
                pts.append(max(-18.0, min(self.maxboost,
                                          self.strength * 0.01 * dv)))
        return pts

    def fit(self, deviations):
        """Returns (gains, target_curve, peak_boost)."""
        pts = self.point_targets(deviations)
        if all(abs(p) <= 0.001 for p in pts):
            return [0.0] * NFIT, [0.0] * NGRID, 0.0
        T = self.target_curve(pts)
        g = [max(-18.0, min(self.maxboost, self._lin_at(T, math.log(FITF[j]))))
             if FITF[j] <= 0.45 * self.sr else 0.0 for j in range(NFIT)]
        for _ in range(FITIT):
            r = [T[k] - self.cascade_db(g, self.gf[k]) for k in range(NGRID)]
            r += [FITKW * (pts[i] - self.cascade_db(g, BANDS[i]))
                  for i in range(self.nk)]
            b = [sum(self.M[row][a] * r[row] for row in range(self.nrows))
                 for a in range(self.na)]
            dg = self._solve(b)
            for j in range(self.na):
                g[j] = max(-24.0, min(self.maxboost + 6, g[j] + dg[j]))
        peak = max(0.0, max(self.cascade_db(g, f) for f in self.gf))
        return g, T, peak


if __name__ == "__main__":
    dev = [-4.6, -0.4, 0.8, 0.4, 1.4, 1.6, 0.0, -0.6, 1.2, -1.4, -0.8,
           -3.2, -3.4, -2.4, 1.6]
    ref = FitReference()
    g, T, peak = ref.fit(dev)
    pts = ref.point_targets(dev)
    worst_c = max(abs(ref.cascade_db(g, BANDS[i]) - pts[i])
                  for i in range(NBANDS))
    worst_m = 0.0
    for i in range(NBANDS - 1):
        fm = math.sqrt(BANDS[i] * BANDS[i + 1])
        worst_m = max(worst_m, abs(ref.cascade_db(g, fm)
                                   - ref._lin_at(T, math.log(fm))))
    print(f"worst center err {worst_c:.4f} dB, worst midpoint err "
          f"{worst_m:.4f} dB, peak boost {peak:+.2f} dB")
