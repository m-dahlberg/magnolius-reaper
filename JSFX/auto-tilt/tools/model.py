"""Reference model for Magnolius_AutoTilt.jsfx.

This mirrors the plugin's filter design and its analysis (band mapping, power
normalisation, least-squares slope fit) closely enough to assert against a
render to a small fraction of a dB. It is NOT a sample-for-sample simulation:
the loop dynamics are deliberately not modelled - the render tests drive the
plugin to convergence and check where it lands.

model.py and Magnolius_AutoTilt.jsfx must be edited together.
"""
import cmath
import math

FFTSIZE = 8192
HALF = FFTSIZE // 2
NB = 32
TONE_RANGE = 0.5


# ---------------------------------------------------------------------------
# slider sanitising -- must match update_all() in @init
# ---------------------------------------------------------------------------

def ranges(ana_lo, ana_hi, tilt_fc, srate):
    flop = max(20.0, min(ana_lo, srate * 0.15))
    fhip = min(min(20000.0, srate * 0.45), max(ana_hi, flop * 4))
    fcp = max(flop * 1.5, min(tilt_fc, fhip * 0.6))
    return flop, fhip, fcp


# ---------------------------------------------------------------------------
# biquads -- must match lowshelf()/highshelf() in @init
# ---------------------------------------------------------------------------

def _shelf(f, g, s, srate, high):
    f = min(f, srate * 0.45)
    s = max(s, 0.05)
    A = 10 ** (g / 40.0)
    w = 2 * math.pi * f / srate
    cw, sw = math.cos(w), math.sin(w)
    al = sw * 0.5 * math.sqrt((A + 1 / A) * (1 / s - 1) + 2)
    t2 = 2 * math.sqrt(A) * al
    if high:
        b0 = A * ((A + 1) + (A - 1) * cw + t2)
        b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        b2 = A * ((A + 1) + (A - 1) * cw - t2)
        a0 = (A + 1) - (A - 1) * cw + t2
        a1 = 2 * ((A - 1) - (A + 1) * cw)
        a2 = (A + 1) - (A - 1) * cw - t2
    else:
        b0 = A * ((A + 1) - (A - 1) * cw + t2)
        b1 = 2 * A * ((A - 1) - (A + 1) * cw)
        b2 = A * ((A + 1) - (A - 1) * cw - t2)
        a0 = (A + 1) + (A - 1) * cw + t2
        a1 = -2 * ((A - 1) + (A + 1) * cw)
        a2 = (A + 1) + (A - 1) * cw - t2
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def lowshelf(f, g, s, srate):
    return _shelf(f, g, s, srate, False)


def highshelf(f, g, s, srate):
    return _shelf(f, g, s, srate, True)


def bqmagdb(c, f, srate):
    b0, b1, b2, a1, a2 = c
    w = 2 * math.pi * f / srate
    cw, sw = math.cos(w), math.sin(w)
    c2, s2 = math.cos(2 * w), math.sin(2 * w)
    nr = b0 + b1 * cw + b2 * c2
    ni = b1 * sw + b2 * s2
    dr = 1 + a1 * cw + a2 * c2
    di = a1 * sw + a2 * s2
    return 10 * math.log10((nr * nr + ni * ni) / (dr * dr + di * di))


def tilt_db(f, g, fcp, shelf_s, srate):
    """dB the tilt applies at f for a tilt gain of g dB."""
    return (bqmagdb(lowshelf(fcp, -g, shelf_s, srate), f, srate)
            + bqmagdb(highshelf(fcp, g, shelf_s, srate), f, srate))


# ---------------------------------------------------------------------------
# band mapping -- must match build_bands() in @init
# ---------------------------------------------------------------------------

class Bands:
    def __init__(self, flop, fhip, srate, fftsize=FFTSIZE, nb=NB):
        self.n = nb
        self.srate = srate
        self.fftsize = fftsize
        half = fftsize // 2
        lr = math.log(fhip / flop)
        self.fc = [flop * math.exp(lr * (b + 0.5) / nb) for b in range(nb)]
        x = [math.log(f, 2) for f in self.fc]
        xs = sum(x) / nb
        self.x = [v - xs for v in x]
        self.sxx = sum(v * v for v in self.x)
        self.binband = [-1] * (half + 1)
        self.w = [0] * nb
        self.fb = [-1] * nb
        for k in range(half + 1):
            f = k * srate / fftsize
            if k >= 1 and flop <= f <= fhip:
                b = min(int(math.floor(nb * math.log(f / flop) / lr)), nb - 1)
                self.binband[k] = b
                self.w[b] += 1
        for b in range(nb):
            if self.w[b] < 1:
                self.fb[b] = max(1, min(half - 1,
                                        int(math.floor(self.fc[b] * fftsize / srate + 0.5))))
                self.w[b] = 1

    def sens(self, fcp, shelf_s):
        """dB/oct of fitted slope per dB of tilt gain -- matches calc_shape()."""
        sh = [tilt_db(f, 1.0, fcp, shelf_s, self.srate) for f in self.fc]
        return max(sum(xi * si for xi, si in zip(self.x, sh)) / self.sxx, 0.02)

    def slope(self, band_db):
        return sum(xi * d for xi, d in zip(self.x, band_db)) / self.sxx


# ---------------------------------------------------------------------------
# analysis -- must match analyze() in @init
# ---------------------------------------------------------------------------

def _fft(a):
    """In-place iterative radix-2 FFT of a list of complex, len a power of 2."""
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    ln = 2
    while ln <= n:
        ang = -2 * math.pi / ln
        wl = cmath.exp(complex(0, ang))
        for i in range(0, n, ln):
            w = 1 + 0j
            for k in range(i, i + ln // 2):
                u = a[k]
                v = a[k + ln // 2] * w
                a[k] = u + v
                a[k + ln // 2] = u - v
                w *= wl
        ln <<= 1
    return a


def hann(n):
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / n) for i in range(n)]


def band_db(L, R, bands, off, win=None, fftsize=FFTSIZE):
    """Per-band power-density dB of one frame starting at `off`.

    Same L+jR packing, same window power normalisation and same per-bin band
    ownership as the plugin, so the resulting slope is directly comparable.
    """
    win = win or hann(fftsize)
    wsum2 = sum(w * w for w in win)
    nrm = 1.0 / (2 * fftsize * wsum2)
    buf = [complex(L[off + i] * win[i], R[off + i] * win[i]) for i in range(fftsize)]
    X = _fft(buf)
    p = [0.0] * bands.n
    for k in range(1, fftsize // 2):
        b = bands.binband[k]
        if b >= 0:
            p[b] += abs(X[k]) ** 2 + abs(X[fftsize - k]) ** 2
    for b in range(bands.n):
        if bands.fb[b] >= 0:
            k = bands.fb[b]
            p[b] = abs(X[k]) ** 2 + abs(X[fftsize - k]) ** 2
    return [10 * math.log10(p[b] * nrm / bands.w[b] + 1e-300) for b in range(bands.n)]


def avg_band_db(L, R, bands, start, nframes, hop=None, fftsize=FFTSIZE):
    """Band dB averaged in the POWER domain over several overlapping frames."""
    hop = hop or fftsize // 2
    win = hann(fftsize)
    acc = [0.0] * bands.n
    for f in range(nframes):
        d = band_db(L, R, bands, start + f * hop, win, fftsize)
        for b in range(bands.n):
            acc[b] += 10 ** (d[b] / 10)
    return [10 * math.log10(acc[b] / nframes + 1e-300) for b in range(bands.n)]
