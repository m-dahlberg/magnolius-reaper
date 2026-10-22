#!/usr/bin/env python3
"""Headless render tests for "Magnolius_BusCompressor.jsfx".

    ./render_test.py                 # everything
    ./render_test.py canary model    # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open.  Work files land in ~/.cache/buscomp-rendertest (BUSCOMP_WORK
overrides).  BUSCOMP_FX_NAME overrides the FX lookup name.

Prerequisite: "Magnolius_BusCompressor.jsfx" symlinked (never copied)
somewhere under <resource>/Effects/.

What these tests can and cannot show: there is no reference unit here, so they
prove (a) the plugin does what model.py says, sample for sample, and (b) the
behaviours the brief asks for -- the static curve and the 3 dB knee, the
labelled attack and release time constants, Auto release telling a transient
from sustained compression, no zipper noise, determinism, and that every path
(dry, bypass, Colour off) lines up with the 24 samples of reported latency.
They do NOT prove the INFERRED constants (knee width, detector release, Auto
times, Colour amount) match any hardware.

Most measurements use SQUARE waves.  |x| of a square is constant, so the
peak detector reads exactly the amplitude, and out/in sample by sample is the
instantaneous gain -- a gain-reduction trace with no windowing.  Colour is
off in those tests, so the wet path is a plain delay and the ratio is exact.
"""
import array
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model                                                    # noqa: E402
from render_harness import (Harness, bin_freq, db, dft_mag_hann,  # noqa: E402
                            maxdiff, parm_env, slider_line)

SR = 48000
LAT = model.LAT
TOL = 2e-5                # waveform agreement against model.py

H = Harness("buscomp",
            os.environ.get("BUSCOMP_FX_NAME", "Magnolius_BusCompressor.jsfx"),
            work=os.environ.get("BUSCOMP_WORK"))

# Order must match the header of "Magnolius_BusCompressor.jsfx".
LABELS = ["Threshold (dBFS)", "Ratio", "Attack (ms)", "Release (s)",
          "Makeup (dB)", "Sidechain HPF (Hz)", "External Key",
          "Listen to Key", "Colour (%)", "Dry Wet Mix (%)", "Bypass"]

GAIN_2X = 20 * math.log10(2.0)        # +6.0206 dB: exactly a factor of two


def S(**kw):
    bad = set(kw) - set(model.NAMES)
    if bad:
        raise KeyError("unknown slider(s): %s" % sorted(bad))
    v = dict(model.DEFAULTS, **kw)
    return slider_line([v[n] for n in model.NAMES])


# ---------------------------------------------------------------------------
# signal generation (stdlib only)
# ---------------------------------------------------------------------------

def f32(x):
    """Quantise to float32 so the model sees exactly what REAPER will read."""
    return list(array.array("f", x))


class LCG:
    def __init__(self, seed=12345):
        self.s = seed

    def uni(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s / 0x3FFFFFFF - 1.0


def lin(level_db):
    return 10 ** (level_db / 20.0)


def square(levels_db, seg_s, f=200.0, srate=SR):
    """A phase-continuous +-a square wave stepping through `levels_db`
    (peak dBFS, the level the peak detector reads).  `seg_s` is one duration
    or one per level."""
    segs = seg_s if isinstance(seg_s, (list, tuple)) else [seg_s] * len(levels_db)
    out, n = [], 0
    for lv, sd in zip(levels_db, segs):
        a = lin(lv)
        for _ in range(int(sd * srate)):
            ph = (n * f / srate) % 1.0
            out.append(a if ph < 0.5 else -a)
            n += 1
    return f32(out)


def sine(f, a, n, srate=SR):
    return f32([a * math.sin(2 * math.pi * f * i / srate) for i in range(n)])


def program(n, seed=3, srate=SR):
    """Loud/quiet alternating stereo material so the ballistics travel.

    0.4 s blocks stepping -6, -46, -20, -60, -12 dBFS, tone plus a little
    noise so the detector never sees a pure sine, then a silent tail.  L and
    R differ.
    """
    r = LCG(seed)
    steps = [-6.0, -46.0, -20.0, -60.0, -12.0]
    blk = int(0.4 * srate)
    left, right = [], []
    for k in range(n):
        lvl = steps[min(k // blk, len(steps) - 1)]
        a = 10 ** (lvl / 20.0)
        if k > int(2.2 * srate):
            a *= 0.0
        t = 2 * math.pi * k / srate
        left.append(a * (0.8 * math.sin(t * 220.0) + 0.2 * r.uni()))
        right.append(0.5 * a * (0.8 * math.sin(t * 330.0 + 0.7) + 0.2 * r.uni()))
    return [f32(left), f32(right)]


def render(name, sliders_kw, chans, srate=SR, parmenv=None, nchan=0):
    H.write_input(name + "_in.wav", chans, srate)
    out, _ = H.render(name, S(**sliders_kw), input_name=name + "_in.wav",
                      length=len(chans[0]) / srate,
                      in_len=len(chans[0]) / srate, srate=srate,
                      parmenv=parmenv, nchan=nchan)
    return out


def stereo(x):
    return [x, list(x)]


def gr_trace(inp, out, lo=0, hi=None):
    """Instantaneous gain reduction in dB per sample, from out/in.  None where
    the input is too small to divide by."""
    hi = len(inp) if hi is None else hi
    return [(-20 * math.log10(abs(out[i]) / abs(inp[i]))
             if abs(inp[i]) > 1e-4 and abs(out[i]) > 0 else None)
            for i in range(lo, hi)]


def gain_trace(inp, out, lo=0, hi=None):
    """out/in as a linear ratio per sample (None where |in| is tiny)."""
    hi = len(inp) if hi is None else hi
    return [out[i] / inp[i] if abs(inp[i]) > 1e-4 else None for i in range(lo, hi)]


def first_below(tr, thresh, start=0):
    for i in range(start, len(tr)):
        if tr[i] is not None and tr[i] <= thresh:
            return i
    return None


def first_above(tr, thresh, start=0):
    for i in range(start, len(tr)):
        if tr[i] is not None and tr[i] >= thresh:
            return i
    return None


def rms(x, lo=0, hi=None):
    seg = x[lo:hi]
    return math.sqrt(sum(v * v for v in seg) / len(seg))


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

def t_params():
    names, _ = H.probe_params()
    got = [names.get(i) for i in range(len(LABELS))]
    bad = [(i, got[i], LABELS[i]) for i in range(len(LABELS)) if got[i] != LABELS[i]]
    H.report("params", not bad, "all %d sliders parsed" % len(LABELS) if not bad
             else "mismatch (index, got, want): %s" % bad)


def t_canary():
    """+6.0206 dB of Makeup must be EXACTLY 2x, and +20 dB exactly 10x.

    Passthrough cannot fake this, so a dead @init fails here instead of
    passing every 'nothing changed' assertion vacuously.
    """
    ch = program(SR * 2)
    out = render("canary", dict(thr_db=0.0, makeup_db=GAIN_2X), ch)
    d = max(maxdiff(out[0], [2 * v for v in ch[0]]),
            maxdiff(out[1], [2 * v for v in ch[1]]))
    H.report("canary", d < 1e-6, "+6.02 dB = exactly 2x, maxdiff %.2e" % d)
    out = render("canary20", dict(thr_db=0.0, makeup_db=20.0), ch)
    d = maxdiff(out[0], [10 * v for v in ch[0]])
    H.report("canary20", d < 1e-6, "+20 dB = exactly 10x, maxdiff %.2e" % d)


def t_unity():
    """Engaged but not triggering: the render must be BIT-IDENTICAL to the
    input.  That single assertion proves actual latency == reported PDC."""
    ch = program(SR * 2)
    out = render("unity", dict(thr_db=0.0), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("unity", d == 0.0, "no GR, Colour 0: bit-identical, maxdiff %.2e" % d)
    # key HPF and a different release must not change that
    out = render("unity_hpf", dict(thr_db=0.0, hpf_hz=150, att_i=0, rel_i=4), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("unity_hpf", d == 0.0, "HPF 150 Hz + Auto, still no GR: maxdiff %.2e" % d)


def t_paths():
    """Mix 0 and Bypass are exactly the delayed input however hard the
    compressor is being driven; Mix 100 with heavy GR is not."""
    ch = program(SR * 2)
    hard = dict(thr_db=-40.0, ratio_i=2, att_i=0, rel_i=0, makeup_db=15.0,
                colour=60.0)
    wet = render("path_wet", hard, ch)
    d_wet = maxdiff(wet[0], ch[0])
    out = render("path_mix0", dict(hard, mix=0.0), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("path:mix0", d == 0.0 and d_wet > 0.1,
             "Mix 0 is bit-identical to the input (%.2e); the wet path "
             "is not (%.2f)" % (d, d_wet))
    out = render("path_bypass", dict(hard, bypass=1), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("path:bypass", d == 0.0, "Bypass is bit-identical, maxdiff %.2e" % d)


START = 32     # samples skipped at the start of a model comparison, see t_model


def t_model():
    """The render must agree with model.py sample for sample (the render is
    PDC-compensated, so it is the model's output shifted by LAT).

    The first START samples are skipped.  When a loud signal begins exactly on
    sample 0 and Colour is on, the first dozen output samples differ from the
    model by up to ~7e-5 (-84 dB), then agree to 1e-8.  A signal that starts
    after 2000 samples of silence matches to 1.5e-8 from its first sample, so
    this is a start-of-item effect in how REAPER primes a PDC plugin, not a
    DSP difference; the cause was not pinned down."""
    n3 = SR * 3 // 2
    cases = [
        ("default", {}, SR),
        ("ratio10", dict(ratio_i=2, att_i=0, rel_i=0, thr_db=-25.0), SR),
        ("auto", dict(rel_i=4, att_i=3, thr_db=-18.0, makeup_db=4.0), SR),
        ("hpf", dict(hpf_hz=120, thr_db=-20.0, ratio_i=0, rel_i=2), SR),
        ("colour", dict(colour=100.0, thr_db=-20.0, att_i=2, makeup_db=3.0), SR),
        ("mix", dict(mix=40.0, makeup_db=6.0, thr_db=-22.0, colour=35.0), SR),
        ("bypass", dict(bypass=1, thr_db=-22.0), SR),
        ("listen", dict(key_listen=1, hpf_hz=200, thr_db=-22.0), SR),
        ("sr441", dict(thr_db=-15.0, colour=50.0, hpf_hz=60), 44100),
        ("sr96", dict(thr_db=-15.0, colour=50.0, rel_i=4), 96000),
    ]
    for name, kw, sr in cases:
        ch = program(int(sr * 3 // 2), srate=sr)
        out = render("model_" + name, kw, ch, srate=sr)
        ref, _ = model.run(ch, sr, **kw)
        n = len(ch[0]) - LAT
        d = max(maxdiff(out[0], ref[0][LAT:], START, n), maxdiff(out[1], ref[1][LAT:], START, n))
        H.report("model:" + name, d < TOL, "maxdiff %.2e (tol %g)" % (d, TOL))


def t_static():
    """Static curve of a settled square wave vs the analytic gain computer,
    for each ratio, across the 3 dB knee.  Peak level in, gain reduction out."""
    thr = -20.0
    levels = [-50, -40, -30, -25, -22, -21, -20.5, -20, -19.5, -19, -18,
              -15, -10, -5, -1]
    seg = 0.5
    ch = stereo(square(levels, seg))
    for ri in range(3):
        kw = dict(thr_db=thr, ratio_i=ri, att_i=3, rel_i=0)
        out = render("static_%d" % ri, kw, ch)
        m = model.BusComp(SR, **kw)
        tr = gr_trace(ch[0], out[0])
        worst, rows = 0.0, []
        for i, lv in enumerate(levels):
            lo = int((i * seg + seg - 0.1) * SR)
            vals = [v for v in tr[lo:lo + 4000] if v is not None]
            meas = sum(vals) / len(vals)
            want = m.gr_calc(lv)
            worst = max(worst, abs(meas - want))
            rows.append((lv, round(meas, 2), round(want, 2)))
        H.report("static:%d:1" % model.RATIOS[ri], worst < 0.05,
                 "worst %.3f dB (tol 0.05)" % worst)
        if worst >= 0.05:
            print("   (level, measured GR, wanted GR):", rows)
    # the knee: firm.  GR at threshold = slope * 3/8, and zero 1.5 dB below.
    m = model.BusComp(SR, thr_db=thr, ratio_i=1)
    ok = (abs(m.gr_calc(thr) - 0.75 * 3 / 8) < 1e-12 and m.gr_calc(thr - 1.5) == 0.0
          and abs(m.gr_calc(thr + 1.5) - 0.75 * 1.5) < 1e-12)
    H.report("knee", ok, "3 dB quadratic: GR(thr)=%.3f, 0 at -1.5 dB, linear at +1.5 dB"
             % m.gr_calc(thr))


def t_attack():
    """Time to 63% of the final gain reduction equals the labelled time."""
    lo_n = int(0.1 * SR)
    ch1 = square([-60.0, -10.0], [0.1, 0.4])
    ch = stereo(ch1)
    worst, rows = 0.0, []
    ok = True
    for ai, ms in enumerate(model.ATT_MS):
        kw = dict(thr_db=-40.0, ratio_i=2, att_i=ai, rel_i=3)
        out = render("attack_%d" % ai, kw, ch)
        tr = gr_trace(ch[0], out[0])
        fin = model.BusComp(SR, **kw).gr_calc(-10.0)
        i = first_above(tr, 0.632 * fin, lo_n)
        t = (i - lo_n) / SR * 1000.0 if i is not None else None
        good = t is not None and abs(t - ms) <= 0.15 * ms + 0.03
        ok &= good
        rows.append("%g ms -> %s" % (ms, "none" if t is None else "%.3f" % t))
    H.report("attack", ok, "t(63%%): %s" % "; ".join(rows))


def t_release():
    """Fixed release: the time for the gain reduction to fall to 1/e equals
    the labelled time (the detector's own 2 ms fall delays the start, hence
    the small allowance)."""
    ok, rows = True, []
    for ri, sec in enumerate(model.REL_S):
        ch = stereo(square([-10.0, -60.0], [0.5, sec * 6 + 0.5]))
        kw = dict(thr_db=-40.0, ratio_i=2, att_i=2, rel_i=ri)
        out = render("release_%d" % ri, kw, ch)
        tr = gr_trace(ch[0], out[0])
        end = int(0.5 * SR)
        g0 = next(v for v in reversed(tr[end - 2000:end]) if v is not None)
        i = first_below(tr, g0 / math.e, end)
        t = (i - end) / SR if i is not None else None
        good = t is not None and abs(t - sec) <= 0.06 * sec + 0.004
        ok &= good
        rows.append("%g s -> %s" % (sec, "none" if t is None else "%.3f" % t))
    H.report("release", ok, "t(1/e): %s" % "; ".join(rows))


def t_shared():
    """One shared element: release is never effectively faster than attack.
    With the slowest attack (30 ms) and the fastest release (0.1 s) the
    release time constant stays 0.1 s, and a long attack still takes 30 ms."""
    ch = stereo(square([-10.0, -60.0], [0.5, 1.0]))
    kw = dict(thr_db=-40.0, ratio_i=2, att_i=5, rel_i=0)
    out = render("shared", kw, ch)
    tr = gr_trace(ch[0], out[0])
    end = int(0.5 * SR)
    g0 = next(v for v in reversed(tr[end - 2000:end]) if v is not None)
    i = first_below(tr, g0 / math.e, end)
    t = (i - end) / SR if i is not None else None
    m = model.BusComp(SR, **kw)
    H.report("shared", t is not None and abs(t - max(0.1, 0.03)) < 0.01
             and m.a_rel >= 1 - math.exp(-1 / (0.1 * SR)) - 1e-12,
             "30 ms attack / 0.1 s release: t(1/e) = %s s" % t)


def t_auto():
    """Auto release tells a transient from sustained compression, gradually.

    A burst of loud material followed by quiet: the time for the gain
    reduction to fall to 10% of its value grows with the burst length -- a
    20 ms transient recovers fast, 3 s of sustained compression slowly.
    """
    durs = [0.02, 0.1, 0.5, 3.0]
    times = []
    for d in durs:
        ch = stereo(square([-10.0, -60.0], [d, 5.0]))
        kw = dict(thr_db=-40.0, ratio_i=2, att_i=3, rel_i=4)
        out = render("auto_%g" % d, kw, ch)
        tr = gr_trace(ch[0], out[0])
        end = int(d * SR)
        g0 = next(v for v in reversed(tr[max(end - 2000, 0):end]) if v is not None)
        i = first_below(tr, 0.1 * g0, end)
        times.append((i - end) / SR if i is not None else float("inf"))
    mono = all(b >= a - 0.02 for a, b in zip(times, times[1:]))
    ok = times[0] < 0.35 and times[-1] > 1.5 and mono
    H.report("auto", ok, "t(10%%) after a %s s burst: %s (want first < 0.35 s, "
             "last > 1.5 s, rising)" % ("/".join("%g" % d for d in durs),
                                      " ".join("%.2f" % t for t in times)))
    # Auto is only engaged on the last detent: 1.2 s must recover differently
    ch = stereo(square([-10.0, -60.0], [0.02, 3.0]))
    out = render("auto_off", dict(thr_db=-40.0, ratio_i=2, att_i=3, rel_i=0), ch)
    tr = gr_trace(ch[0], out[0])
    end = int(0.02 * SR)
    g0 = next(v for v in reversed(tr[end - 500:end]) if v is not None)
    i = first_below(tr, 0.1 * g0, end)
    t = (i - end) / SR
    H.report("auto:fixed", 0.15 < t < 0.35,
             "Release 0.1 s (not Auto) after a 20 ms burst: t(10%%) = %.2f s "
             "(2.3 tau = 0.23)" % t)


def t_hpf():
    """The key HPF is a 2nd-order Butterworth on the detector only."""
    # response, read through Listen (the filtered key comes out as audio)
    a = 0.25
    n = 16384
    rows, ok = [], True
    for fc in (60, 150):
        for mult, want in ((1.0, -3.01), (0.25, -24.1), (4.0, 0.0)):
            f = bin_freq(fc * mult, SR, n)
            ch = stereo(sine(f, a, n + 4800))
            out = render("hpf_%d_%g" % (fc, mult), dict(key_listen=1, hpf_hz=fc,
                                                       thr_db=0.0), ch)
            got = db(dft_mag_hann(out[0][4800:4800 + n], f) / a)
            # the filter is bilinear: allow a little warping at the low end
            good = abs(got - want) < 0.6
            ok &= good
            rows.append("%d Hz at %g fc: %.2f (want %.2f)" % (fc, mult, got, want))
    H.report("hpf:response", ok, "; ".join(rows))
    # it keeps a low tone from driving the compressor, and never filters audio
    f = bin_freq(40.0, SR, n)
    ch = stereo(sine(f, 0.5, SR * 2))
    kw = dict(thr_db=-24.0, ratio_i=2, att_i=3, rel_i=1)
    gr = {}
    for hz in (0, 150):
        out = render("hpf_gr_%d" % hz, dict(kw, hpf_hz=hz), ch)
        gr[hz] = db(rms(ch[0], SR, SR + n)) - db(rms(out[0], SR, SR + n))
    H.report("hpf:key", gr[0] - gr[150] > 6.0 and gr[150] < 2.0,
             "40 Hz tone at -6 dBFS: GR %.1f dB with HPF off, %.1f dB at 150 Hz; "
             "output level follows the GR (the audio itself is not filtered)"
             % (gr[0], gr[150]))


def t_ext():
    """External key on channels 3/4: a loud key compresses a quiet programme;
    a quiet key leaves a loud programme alone; with Ext off the key is ignored."""
    n = SR * 2
    quiet = sine(1000.0, lin(-30.0), n)
    loud = sine(777.0, lin(-3.0), n)
    kw = dict(thr_db=-20.0, ratio_i=2, att_i=2, rel_i=0)
    # programme quiet, key loud
    ch4 = [quiet, list(quiet), loud, list(loud)]
    out = render("ext_on", dict(kw, ext_key=1), ch4, nchan=4)
    g_on = db(rms(quiet, SR, SR + 9600)) - db(rms(out[0], SR, SR + 9600))
    out = render("ext_off", dict(kw, ext_key=0), ch4, nchan=4)
    g_off = db(rms(quiet, SR, SR + 9600)) - db(rms(out[0], SR, SR + 9600))
    # programme loud, key silent
    ch4 = [loud, list(loud), [0.0] * n, [0.0] * n]
    out = render("ext_silent", dict(kw, ext_key=1), ch4, nchan=4)
    d = maxdiff(out[0], loud)
    H.report("ext", g_on > 10.0 and abs(g_off) < 0.1 and d < 1e-7,
             "quiet programme, loud key: GR %.1f dB (Ext on), %.2f dB (Ext off); "
             "loud programme, silent key: maxdiff %.1e" % (g_on, g_off, d))


def t_colour():
    """Colour: off is transparent, on adds 2nd/3rd harmonics that grow with
    the gain reduction, stays roughly level-neutral, and does not alias."""
    n = 16384
    f = bin_freq(1000.0, SR, n)
    hs = {}

    def harmonics(name, a, kw):
        ch = stereo(sine(f, a, SR * 2))
        out = render(name, kw, ch)
        seg = out[0][SR:SR + n]
        h1 = dft_mag_hann(seg, f)
        return (h1, db(dft_mag_hann(seg, 2 * f) / h1),
                db(dft_mag_hann(seg, 3 * f) / h1))

    base = dict(thr_db=-30.0, ratio_i=1, att_i=2, rel_i=1)
    a = lin(-6.0)
    off = harmonics("colour_off", a, dict(base, colour=0.0))
    on = harmonics("colour_on", a, dict(base, colour=100.0))
    light = harmonics("colour_light", a, dict(dict(base, thr_db=-8.0), colour=100.0))
    ok = (-45.0 < on[1] < -25.0 and -50.0 < on[2] < -25.0
          and on[1] > off[1] + 10.0 and on[1] > light[1] + 3.0)
    H.report("colour:harmonics", ok,
             "-6 dBFS, ~18 dB GR: 2nd %.1f / 3rd %.1f dBc (Colour 0: %.1f / %.1f; "
             "with 1 dB GR: %.1f / %.1f)" % (on[1], on[2], off[1], off[2],
                                            light[1], light[2]))
    worst = 0.0
    for lv in (-24.0, -12.0, -6.0):
        o0 = harmonics("colour_n0_%d" % lv, lin(lv), dict(base, colour=0.0))
        o1 = harmonics("colour_n1_%d" % lv, lin(lv), dict(base, colour=100.0))
        worst = max(worst, abs(db(o1[0] / o0[0])))
    H.report("colour:level", worst < 0.5,
             "fundamental changes by at most %.2f dB (tol 0.5) at -24/-12/-6 dBFS" % worst)
    # alias floor: a 17 kHz tone's 2nd/3rd harmonics would fold to 14 and 3 kHz
    f17 = bin_freq(17000.0, SR, n)
    ch = stereo(sine(f17, lin(-6.0), SR * 2))
    out = render("colour_alias", dict(base, colour=100.0, thr_db=-30.0), ch)
    seg = out[0][SR:SR + n]
    h1 = dft_mag_hann(seg, f17)
    fa = [bin_freq(abs(SR - 2 * f17), SR, n), bin_freq(abs(3 * f17 - SR), SR, n)]
    al = [db(dft_mag_hann(seg, x) / h1) for x in fa]
    H.report("colour:alias", max(al) < -75.0,
             "17 kHz tone, Colour 100: aliases at %.0f / %.0f Hz are %.1f / %.1f dBc "
             "(want < -75)" % (fa[0], fa[1], al[0], al[1]))
    # alignment: with Colour on but no GR the output still lines up with the
    # input (PDC), to within the shaper's own small distortion
    ch = stereo(sine(bin_freq(5000.0, SR, n), 0.25, SR))
    out = render("colour_align", dict(thr_db=0.0, colour=100.0), ch)
    d = maxdiff(out[0], ch[0], 4800, SR - 4800)
    H.report("colour:align", d < 0.01, "Colour 100, no GR: maxdiff %.4f (a 1-sample "
             "misalignment would be 0.16)" % d)


def t_smooth():
    """No zipper noise: makeup, mix and threshold automation move the gain a
    fraction of a percent per sample, never in a step."""
    ch1 = square([-20.0], 2.0)
    ch = stereo(ch1)

    def worst_step(tr, lo, hi):
        w = 0.0
        prev = None
        for v in tr[lo:hi]:
            if v is not None and prev is not None:
                w = max(w, abs(v / prev - 1.0))
            if v is not None:
                prev = v
        return w

    # makeup 0 -> +20 dB at t = 1 s
    env = parm_env(4, "Makeup (dB)", [(0.0, 0.0), (1.0, 20.0)])
    out = render("sm_makeup", dict(thr_db=0.0), ch, parmenv=env)
    tr = gain_trace(ch[0], out[0])
    w = worst_step(tr, SR - 100, SR + 20000)
    fin = tr[-5000] if tr[-5000] is not None else tr[-5001]
    H.report("smooth:makeup", w < 0.004 and abs(fin - 10.0) < 0.01,
             "0 -> +20 dB step: worst per-sample change %.3f%% (tol 0.4%%), "
             "settles at x%.3f" % (w * 100, fin))
    # mix 100 -> 0 at t = 1 s, with makeup so wet differs from dry
    env = parm_env(9, "Dry Wet Mix (%)", [(0.0, 100.0), (1.0, 0.0)])
    out = render("sm_mix", dict(thr_db=0.0, makeup_db=20.0), ch, parmenv=env)
    tr = gain_trace(ch[0], out[0])
    w = worst_step(tr, SR - 100, SR + 20000)
    fin = tr[-5000] if tr[-5000] is not None else tr[-5001]
    H.report("smooth:mix", w < 0.004 and abs(fin - 1.0) < 0.001,
             "mix 100 -> 0: worst per-sample change %.3f%% (tol 0.4%%), "
             "settles at x%.4f" % (w * 100, fin))
    # threshold -5 -> -40 dB at t = 1 s: the timing element carries it
    env = parm_env(0, "Threshold (dBFS)", [(0.0, -5.0), (1.0, -40.0)])
    out = render("sm_thr", dict(thr_db=-5.0, ratio_i=2, att_i=4, rel_i=1), ch, parmenv=env)
    tr = gain_trace(ch[0], out[0])
    w = worst_step(tr, SR - 100, SR + 20000)
    H.report("smooth:threshold", w < 0.01,
             "threshold -5 -> -40 dBFS: worst per-sample change %.3f%% (tol 1%%)" % (w * 100))


def t_determinism():
    """Identical input must give identical output: two renders, same bits."""
    ch = program(SR * 2)
    kw = dict(thr_db=-24.0, rel_i=4, colour=50.0, hpf_hz=90, makeup_db=3.0)
    a = render("det_a", kw, ch)
    b = render("det_b", kw, ch)
    d = max(maxdiff(a[0], b[0]), maxdiff(a[1], b[1]))
    H.report("determinism", d == 0.0, "two renders, maxdiff %.2e" % d)


def t_filter():
    """The key HPF is stable at every sample rate and cutoff (|a2| < 1,
    |a1| < 1 + a2)."""
    bad = []
    for sr in (8000, 11025, 22050, 44100, 48000, 96000, 192000):
        m = model.BusComp(sr, hpf_hz=500)
        for f in (10.0, 20.0, 60.0, 150.0, 500.0, sr):
            m.hp_design(f)
            if not (abs(m.ha2) < 1 and abs(m.ha1) < 1 + m.ha2):
                bad.append((sr, f))
    H.report("filter", not bad, "HPF poles inside the unit circle at 8k..192k"
             if not bad else "unstable at %s" % bad)


TESTS = [("params", t_params), ("canary", t_canary), ("unity", t_unity),
         ("paths", t_paths), ("model", t_model), ("static", t_static),
         ("attack", t_attack), ("release", t_release), ("shared", t_shared),
         ("auto", t_auto), ("hpf", t_hpf), ("ext", t_ext), ("colour", t_colour),
         ("smooth", t_smooth), ("determinism", t_determinism),
         ("filter", t_filter)]

if __name__ == "__main__":
    H.run(TESTS)
