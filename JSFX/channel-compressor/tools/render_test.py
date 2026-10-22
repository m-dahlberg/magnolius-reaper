#!/usr/bin/env python3
"""Headless render tests for "Magnolius_ChannelCompressor.jsfx".

    ./render_test.py                 # everything
    ./render_test.py canary model    # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open.  Work files land in ~/.cache/chcomp-rendertest (CHCOMP_WORK
overrides).  CHCOMP_FX_NAME overrides the FX lookup name.

Prerequisite: "Magnolius_ChannelCompressor.jsfx" symlinked (never copied)
somewhere under <resource>/Effects/.

What these tests can and cannot show: there is no reference unit here, so they
prove (a) the plugin does what model.py says, sample for sample, and (b) the
behaviours the SSL manual states -- attack time per 20 dB, the log/linear
release shapes, the +6 dB Lin Rel shift, the make-up keeping the reference
level steady.  They do NOT prove the INFERRED constants (RMS time, knee width,
peak ballistics, make-up law) match hardware.
"""
import array
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model                                                    # noqa: E402
from render_harness import (Harness, bin_freq, db, dft_mag,     # noqa: E402
                            maxdiff, slider_line)

SR = 48000
N = 16384
TOL = 2e-5                # waveform agreement against model.py

H = Harness("chcomp",
            os.environ.get("CHCOMP_FX_NAME", "Magnolius_ChannelCompressor.jsfx"),
            work=os.environ.get("CHCOMP_WORK"))

# Order must match the header of "Magnolius_ChannelCompressor.jsfx".
LABELS = ["Threshold (dB)", "Ratio (20 is infinity)", "Release (s)",
          "Output (dB)", "Fast Attack", "Hard Knee", "Linear Release",
          "Auto Make-up", "Stereo Link", "Reference (dBFS)"]

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


def amp(level_db):
    """Peak amplitude of a sine whose RMS is level_db."""
    return math.sqrt(2.0) * 10 ** (level_db / 20.0)


def steps_tone(levels, seg_s, f=1000.0, srate=SR):
    """One tone, phase-continuous, stepping through `levels` (RMS dBFS)."""
    seg = int(seg_s * srate)
    out = []
    for i, lv in enumerate(levels):
        a = amp(lv)
        for k in range(seg):
            n = i * seg + k
            out.append(a * math.sin(2 * math.pi * f * n / srate))
    return f32(out)


def program(n, seed=3, srate=SR):
    """Loud/quiet alternating stereo material so the ballistics travel.

    0.4 s blocks stepping -6, -46, -20, -60, -12 dBFS, tone plus a little
    noise so neither detector ever sees a pure sine, then a silent tail.
    L and R differ so the Max / Avg link modes diverge.
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


def render(name, sliders_kw, chans, srate=SR):
    H.write_input(name + "_in.wav", chans, srate)
    out, _ = H.render(name, S(**sliders_kw), input_name=name + "_in.wav",
                      length=len(chans[0]) / srate,
                      in_len=len(chans[0]) / srate, srate=srate)
    return out


def win_rms(x, lo, n):
    seg = x[lo:lo + n]
    return math.sqrt(sum(v * v for v in seg) / len(seg))


def gr_at(in_ch, out_ch, t, win=48, srate=SR):
    """Gain reduction in dB at time t, as in/out RMS over one window.

    With auto make-up off and Output at 0 dB, in/out IS the applied GR.
    """
    lo = int(t * srate)
    return db(win_rms(in_ch, lo, win)) - db(win_rms(out_ch, lo, win))


def t_reach(in_ch, out_ch, t0, frac_db, tmax, win=48, hop=8, srate=SR):
    """Seconds after t0 until GR first reaches frac_db."""
    k = int(t0 * srate)
    end = int((t0 + tmax) * srate)
    while k < end:
        if gr_at(in_ch, out_ch, k / srate, win, srate) >= frac_db:
            return k / srate - t0
        k += hop
    return None


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
    """Ratio 1:1 is inactive: +6.0206 dB of Output must be EXACTLY 2x.

    Passthrough cannot fake this, so a dead @init fails here instead of
    passing every 'nothing changed' assertion vacuously.
    """
    ch = program(SR * 2)
    out = render("canary", dict(ratio=1.0, out_db=GAIN_2X), ch)
    d = max(maxdiff(out[0], [2 * v for v in ch[0]]),
            maxdiff(out[1], [2 * v for v in ch[1]]))
    H.report("canary", d < 1e-6, "+6.02 dB = exactly 2x, maxdiff %.2e" % d)
    out = render("unity", dict(ratio=1.0), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("unity", d < 1e-7, "ratio 1:1 is bit-transparent, maxdiff %.2e" % d)


def t_model():
    """The render must agree with model.py sample for sample."""
    cases = [
        ("default", {}, SR),
        ("hardfast", dict(hard_knee=1, fast_att=1, ratio=10.0, thr_db=-15.0), SR),
        ("linavg", dict(lin_rel=1, link_mode=1, auto_mu=0, rel_s=1.0, out_db=-3.0), SR),
        ("inf", dict(ratio=20.0, thr_db=-25.0, rel_s=0.1, ref_db=-12.0), SR),
        ("sr441", dict(thr_db=-10.0, ratio=6.0), 44100),
        ("sr96", dict(hard_knee=1, thr_db=-10.0, ratio=3.0), 96000),
    ]
    for name, kw, sr in cases:
        ch = program(int(sr * 3.0), srate=sr)
        out = render("model_" + name, kw, ch, srate=sr)
        ref, _ = model.run(ch, sr, **kw)
        d = max(maxdiff(out[0], ref[0]), maxdiff(out[1], ref[1]))
        H.report("model:" + name, d < TOL, "maxdiff %.2e (tol %g)" % (d, TOL))


def t_static():
    """Static curve of a settled tone vs the analytic gain computer.

    One render per variant: a tone stepping through levels, 0.6 s each, read
    over the last 0.1 s.  Also checks the make-up keeps the Reference level
    steady for a compressed signal (the manual's 'steady output level').
    """
    levels = [-60, -50, -42, -36, -32, -30, -28, -24, -20, -18, -12, -6]
    variants = [
        ("over_easy", dict(thr_db=-12.0, ratio=4.0, rel_s=0.1), 0.15),
        ("hard", dict(thr_db=-12.0, ratio=4.0, rel_s=0.1, hard_knee=1), 0.35),
        ("hard_lin", dict(thr_db=-6.0, ratio=8.0, rel_s=0.1, hard_knee=1, lin_rel=1), 0.35),
        ("inf_nomu", dict(thr_db=-20.0, ratio=20.0, rel_s=0.1, auto_mu=0), 0.15),
    ]
    seg = 0.6
    ch1 = steps_tone(levels, seg)
    ch = [ch1, list(ch1)]
    for name, kw, tol in variants:
        out = render("static_" + name, kw, ch)
        m = model.ChannelComp(SR, **kw)
        worst, rows = 0.0, []
        for i, lv in enumerate(levels):
            lo = int((i * seg + seg - 0.12) * SR)
            meas = db(win_rms(out[0], lo, 4800)) - db(win_rms(ch[0], lo, 4800))
            want = m.static_out_db(lv) - lv
            worst = max(worst, abs(meas - want))
            rows.append((lv, round(meas, 2), round(want, 2)))
        H.report("static:" + name, worst < tol, "worst %.2f dB (tol %g)" % (worst, tol))
        if worst >= tol:
            print("   (level, measured gain, wanted gain):", rows)
    # make-up keeps the reference level steady: -18 dBFS in -> -18 dBFS out
    kw = dict(thr_db=-12.0, ratio=4.0, rel_s=0.1)
    m = model.ChannelComp(SR, **kw)
    o = m.static_out_db(-18.0)
    H.report("makeup_ref", abs(o + 18.0) < 1e-9,
             "model: -18 dBFS in -> %.3f dBFS out (Reference level held)" % o)


def t_attack():
    """Attack is a slew: time to 90%% of the GR scales with the overshoot, and
    is ~30 ms per 20 dB (Fast Att: ~3 ms per 20 dB) -- the manual's figures."""
    for fast in (0, 1):
        res = {}
        for over in (10, 20, 30):
            t0 = 0.3
            lv = [-70, -48 + over]
            seg_n = int(0.3 * SR)
            ch1 = steps_tone(lv, 0.3)[:2 * seg_n]
            ch = [ch1, list(ch1)]
            kw = dict(thr_db=-30.0, ratio=20.0, auto_mu=0, hard_knee=1,
                      rel_s=0.4, fast_att=fast)
            out = render("attack_%d_%d" % (fast, over), kw, ch)
            res[over] = t_reach(ch[0], out[0], t0, 0.9 * over, 0.25)
        exp_rate = 20.0 / (0.003 if fast else 0.030)          # dB per second
        ok, detail = True, []
        for over, t in res.items():
            want = 0.9 * over / exp_rate
            tol = 0.0015 if fast else 0.004
            good = t is not None and abs(t - want) < tol
            ok &= good
            detail.append("%d dB: %s ms (want %.1f)" % (
                over, "none" if t is None else "%.1f" % (t * 1e3), want * 1e3))
        if ok and res[10] and res[30]:
            ratio = res[30] / res[10]
            ok &= 2.4 < ratio < 3.6
            detail.append("t90(30)/t90(10)=%.2f (slew: 3)" % ratio)
        H.report("attack:" + ("fast" if fast else "normal"), ok, "; ".join(detail))


def t_release():
    """Log release is exponential in dB (time constant = Release); linear
    release is a straight line at 20 dB per Release time.

    The RMS detector's own fall (about 60 ms from -18 dBFS to below the knee)
    delays the START of release, so the log curve is checked by its SHAPE --
    successive-point ratios exp(-dt/tau) -- which that delay does not change.
    The linear curve is rate-limited and is checked in absolute dB.
    """
    rel = 0.4
    t_end = 0.9

    def burst(level):
        a = steps_tone([-80], 0.3)[:int(0.3 * SR)]
        b = steps_tone([level], 0.6)[:int(0.6 * SR)]
        c = steps_tone([-80], 0.7)[:int(0.7 * SR)]
        return a + b + c

    # log: GR at t, t+0.1, t+0.2, t+0.4 after the burst ends
    kw = dict(thr_db=-20.0, ratio=20.0, auto_mu=0, rel_s=rel)
    ch1 = burst(-18)
    ch = [ch1, list(ch1)]
    out = render("release_log", kw, ch)
    ts = (0.1, 0.2, 0.4)
    g = [gr_at(ch[0], out[0], t_end + t) for t in ts]
    r1, r2 = g[1] / g[0], g[2] / g[1]
    w1, w2 = math.exp(-0.1 / rel), math.exp(-0.2 / rel)
    H.report("release:log", abs(r1 - w1) < 0.03 and abs(r2 - w2) < 0.03,
             "GR %.2f %.2f %.2f dB; ratios %.3f %.3f (want %.3f %.3f)"
             % (g[0], g[1], g[2], r1, r2, w1, w2))

    # linear: absolute dB.  Lin Rel adds 6 dB to the threshold, so 14 dB of GR
    kw = dict(thr_db=-20.0, ratio=20.0, auto_mu=0, rel_s=rel, lin_rel=1)
    out = render("release_linear", kw, ch)
    worst, rows = 0.0, []
    for t in (0.05, 0.1, 0.2):
        got = gr_at(ch[0], out[0], t_end + t)
        want = 14.0 - 50.0 * t
        worst = max(worst, abs(got - want))
        rows.append("t=%.2f: %.2f dB (want %.2f)" % (t, got, want))
    H.report("release:linear", worst < 0.3, "; ".join(rows))


def t_linrel_shift():
    """Lin Rel raises the threshold by 6 dB (manual): at a level well above
    the threshold, the GR drops by 6 dB x slope."""
    ch1 = steps_tone([-10], 1.0)
    ch = [ch1, list(ch1)]
    base = dict(thr_db=0.0, ratio=4.0, auto_mu=0, hard_knee=1, rel_s=0.1)
    gr = {}
    for lin in (0, 1):
        out = render("linshift_%d" % lin, dict(base, lin_rel=lin), ch)
        gr[lin] = gr_at(ch[0], out[0], 0.8, win=4800)
    shift = gr[0] - gr[1]
    want = 6.0 * 0.75
    H.report("linrel_shift", abs(shift - want) < 0.5,
             "GR %.2f -> %.2f dB, shift %.2f (want %.2f)" % (gr[0], gr[1], shift, want))


def t_link():
    """Max uses the louder channel; Avg averages the powers, so a one-sided
    signal reads 3 dB lower and compresses less."""
    ch1 = steps_tone([-12], 1.0)
    ch = [ch1, [0.0] * len(ch1)]
    base = dict(thr_db=-6.0, ratio=4.0, auto_mu=0, rel_s=0.1)
    gr = {}
    for mode in (0, 1):
        out = render("link_%d" % mode, dict(base, link_mode=mode), ch)
        gr[mode] = gr_at(ch[0], out[0], 0.8, win=4800)
    # Max: level -12, T -24: o=12, GR = .75*12 = 9.  Avg: -15 dB -> o=9, GR 6.75.
    H.report("link", abs(gr[0] - 9.0) < 0.3 and abs(gr[1] - 6.75) < 0.3,
             "Max GR %.2f (want 9.00), Avg GR %.2f (want 6.75)" % (gr[0], gr[1]))


TESTS = [("params", t_params), ("canary", t_canary), ("model", t_model),
         ("static", t_static), ("attack", t_attack), ("release", t_release),
         ("linrel", t_linrel_shift), ("link", t_link)]

if __name__ == "__main__":
    H.run(TESTS)
