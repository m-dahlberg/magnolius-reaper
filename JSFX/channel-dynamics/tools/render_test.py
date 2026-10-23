#!/usr/bin/env python3
"""Headless render tests for "Magnolius_ChannelDynamics.jsfx".

    ./render_test.py                 # everything
    ./render_test.py canary model    # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open.  Work files land in ~/.cache/chdyn-rendertest (CHDYN_WORK
overrides).  CHDYN_FX_NAME overrides the FX lookup name.

Prerequisite: "Magnolius_ChannelDynamics.jsfx" symlinked (never copied)
somewhere under <resource>/Effects/.

What these tests can and cannot show: there is no reference unit here, so they
prove (a) the plugin does what model.py says, sample for sample, and (b) the
behaviours the design fixes -- the knee table, the RC attack times, the
two-state release, the make-up keeping the reference level steady, the gate's
hysteresis, timing and Range, and that the two sections combine by max and
share one detector.  They do NOT prove the values marked FIT in the plugin
(release weighting, make-up scale, fast gate attack) match hardware.

The ballistics tests use a 10 kHz tone: the detector averages over only 80 us,
so a low-frequency tone ripples through the gain computers and would blur the
time constants being measured.  Gain is read sample-exactly as out/in.
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
TOL = 2e-5                # waveform agreement against model.py
HF = 10000.0              # ballistics test tone, Hz (exactly 4.8 samples per cycle)

H = Harness("chdyn",
            os.environ.get("CHDYN_FX_NAME", "Magnolius_ChannelDynamics.jsfx"),
            work=os.environ.get("CHDYN_WORK"))

# Order must match the header of "Magnolius_ChannelDynamics.jsfx".
LABELS = ["Threshold (dB)", "Ratio (20 is infinity)", "Release (s)",
          "Output (dB)", "Fast Attack", "Auto Make-up", "Stereo Link",
          "Reference (dBFS)", "Gate In", "Gate Mode", "Gate Threshold (dB)",
          "Gate Range (dB)", "Gate Release (s)", "Gate Fast Attack"]

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


def timed_tone(parts, f=HF, srate=SR):
    """Phase-continuous tone from [(level_dBFS_rms, seconds), ...]."""
    out, n = [], 0
    for lv, secs in parts:
        a = amp(lv)
        for _ in range(int(secs * srate)):
            out.append(a * math.sin(2 * math.pi * f * n / srate))
            n += 1
    return f32(out)


def ramp_tone(l0, l1, secs, f=HF, srate=SR):
    """Tone whose level ramps linearly in dB from l0 to l1."""
    n = int(secs * srate)
    return f32([amp(l0 + (l1 - l0) * k / n) * math.sin(2 * math.pi * f * k / srate)
                for k in range(n)])


def program(n, seed=3, srate=SR):
    """Loud/quiet alternating stereo material so the ballistics travel.

    0.4 s blocks stepping -6, -46, -20, -60, -12 dBFS, tone plus a little
    noise so the detector never sees a pure sine, then a silent tail.
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


def mono(x):
    return [x, list(x)]


def win_rms(x, lo, n):
    seg = x[lo:lo + n]
    return math.sqrt(sum(v * v for v in seg) / len(seg))


def gr_at(in_ch, out_ch, t, win=48, srate=SR):
    """Gain reduction in dB at time t, as in/out RMS over one window.

    With auto make-up off and Output at 0 dB, in/out IS the applied GR.
    """
    lo = int(t * srate)
    return db(win_rms(in_ch, lo, win)) - db(win_rms(out_ch, lo, win))


def gr_pts(inp, out, lo, hi, srate=SR):
    """[(t, GR dB)] at every sample where |in| is big enough for out/in to be
    exact (near a zero crossing the ratio is meaningless)."""
    pts = []
    for i in range(lo, hi):
        loc = max(abs(v) for v in inp[max(0, i - 3):i + 4])
        if loc > 1e-9 and abs(inp[i]) > 0.5 * loc:
            pts.append((i / srate, -db(out[i] / inp[i])))
    return pts


def t_cross(pts, t0, target, falling):
    """Seconds after t0 until GR first falls to (or rises to) target."""
    for t, g in pts:
        if t >= t0 and (g <= target if falling else g >= target):
            return t - t0
    return None


def gr_mean(pts, t0, t1):
    v = [g for t, g in pts if t0 <= t < t1]
    return sum(v) / len(v)


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
        ("fast", dict(fast_att=1, ratio=10.0, thr_db=-15.0), SR),
        ("avg", dict(link_mode=1, auto_mu=0, rel_s=1.0, out_db=-3.0), SR),
        ("inf", dict(ratio=20.0, thr_db=-25.0, rel_s=0.1, ref_db=-12.0), SR),
        ("expand", dict(ratio=1.0, gate_on=1, gate_thr=-5.0, gate_range=30.0,
                        gate_rel=0.3), SR),
        ("gate", dict(ratio=1.0, gate_on=1, gate_mode=1, gate_thr=-8.0,
                      gate_range=40.0, gate_fast=1, gate_rel=0.1), SR),
        ("both", dict(thr_db=-14.0, ratio=6.0, gate_on=1, gate_mode=1,
                      gate_thr=-6.0, gate_range=25.0), SR),
        ("sr441", dict(thr_db=-10.0, ratio=6.0, gate_on=1, gate_thr=-4.0), 44100),
        ("sr96", dict(thr_db=-10.0, ratio=3.0, gate_on=1, gate_mode=1,
                      gate_thr=-6.0), 96000),
    ]
    for name, kw, sr in cases:
        ch = program(int(sr * 3.0), srate=sr)
        if kw.get("gate_on"):
            # REAPER feeds the plugin silence before the item starts, and an
            # expander/gate on silence charges its timing cap toward Range, so
            # the first few hundred samples depend on how long that lasted.
            # A long silent lead-in lets the model and the render converge.
            lead = [0.0] * int(sr * 3.0)
            ch = [lead + ch[0], lead + ch[1]]
        out = render("model_" + name, kw, ch, srate=sr)
        ref, _ = model.run(ch, sr, **kw)
        d = max(maxdiff(out[0], ref[0]), maxdiff(out[1], ref[1]))
        H.report("model:" + name, d < TOL, "maxdiff %.2e (tol %g)" % (d, TOL))


def t_knee():
    """The closed-form knee against the table simulated from the circuit."""
    table = [(2, 0.9), (6, 2.8), (10, 5.2), (15, 9.5), (20, 14.4), (30, 24.4)]
    worst = max(abs(model.knee(x) - want) for x, want in table)
    H.report("knee", worst < 0.3 and model.knee(0.0) == 0.0,
             "worst %.2f dB against the table (tol 0.3); knee(0) = %g"
             % (worst, model.knee(0.0)))


def t_static():
    """Static curve of a settled tone vs the analytic gain computer.

    A tone stepping through levels, 0.6 s each, read over the last 0.1 s.  The
    detector is nearly instantaneous, so a 1 kHz tone ripples and the attack
    follows the ripple's peaks: the settled GR sits a little above the knee
    evaluated at the RMS level (measured: up to 0.74 dB, worst just above the
    knee), hence the looser bound.  The 10 kHz variants have almost no ripple
    and must land on the curve.
    """
    levels = [-60, -50, -42, -36, -32, -30, -28, -24, -20, -18, -12, -6]
    variants = [
        ("1k", 1000.0, dict(thr_db=-12.0, ratio=4.0, rel_s=0.1), 0.8),
        ("10k", HF, dict(thr_db=-12.0, ratio=4.0, rel_s=0.1), 0.25),
        ("inf_nomu", HF, dict(thr_db=-20.0, ratio=20.0, rel_s=0.1, auto_mu=0), 0.25),
        ("r2_nomu", HF, dict(thr_db=-24.0, ratio=2.0, rel_s=0.1, auto_mu=0), 0.25),
    ]
    seg = 0.6
    for name, f, kw, tol in variants:
        ch = mono(steps_tone(levels, seg, f=f))
        out = render("static_" + name, kw, ch)
        m = model.ChannelDynamics(SR, **kw)
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


def t_makeup():
    """Make-up keeps the Reference level steady: -18 dBFS in -> -18 dBFS out."""
    for thr, ratio in ((-12.0, 4.0), (-20.0, 2.0), (-8.0, 20.0)):
        m = model.ChannelDynamics(SR, thr_db=thr, ratio=ratio)
        o = m.static_out_db(-18.0)
        H.report("makeup:model %g/%g" % (thr, ratio), abs(o + 18.0) < 1e-9,
                 "-18 dBFS in -> %.3f dBFS out" % o)
    ch = mono(steps_tone([-18], 1.0, f=HF))
    out = render("makeup_render", dict(thr_db=-12.0, ratio=4.0, rel_s=0.1), ch)
    got = db(win_rms(out[0], int(0.7 * SR), 4800)) - db(win_rms(ch[0], int(0.7 * SR), 4800))
    H.report("makeup:render", abs(got) < 0.25, "10 kHz at -18 dBFS: %+.2f dB" % got)


def t_attack():
    """Attack is a one-pole RC: the GR reaches 63.2% of its settled value after
    one time constant -- 33 ms (Auto) or 1 ms (Fast Att), whatever the overshoot."""
    for fast, tau, tol in ((0, 0.033, 0.003), (1, 0.001, 0.0004)):
        res, detail, ok = {}, [], True
        for lv in (-24, -18, -10):
            ch = mono(timed_tone([(-70, 0.4), (lv, 0.8)]))
            kw = dict(thr_db=-30.0, ratio=20.0, auto_mu=0, rel_s=0.4, fast_att=fast)
            out = render("attack_%d_%d" % (fast, -lv), kw, ch)
            pts = gr_pts(ch[0], out[0], int(0.38 * SR), int(1.2 * SR))
            final = gr_mean(pts, 1.0, 1.15)
            t63 = t_cross(pts, 0.4, 0.632 * final, False)
            res[lv] = (final, t63)
            good = t63 is not None and abs(t63 - tau) < tol
            ok &= good
            detail.append("%d dBFS: GR %.1f dB, t63 %s ms" % (
                lv, final, "none" if t63 is None else "%.2f" % (t63 * 1e3)))
        H.report("attack:" + ("fast" if fast else "auto"), ok,
                 "want %.1f ms; " % (tau * 1e3) + "; ".join(detail))


def t_release():
    """Release has two time constants: after a short burst the GR falls away
    quickly (the fast state), after sustained compression a slow tail remains
    (the slow state, 6.7x longer, weighted K_SLOW)."""
    rel = 0.4
    kw = dict(thr_db=-30.0, ratio=20.0, auto_mu=0, rel_s=rel)
    t37 = {}
    for name, burst in (("short", 0.06), ("sustained", 2.0)):
        ch = mono(timed_tone([(-70, 0.3), (-18, burst), (-70, 1.6)]))
        out = render("release_" + name, kw, ch)
        t_end = 0.3 + burst
        pts = gr_pts(ch[0], out[0], int((t_end + 0.002) * SR), int((t_end + 1.5) * SR))
        g0 = gr_mean(pts, t_end + 0.002, t_end + 0.004)
        t37[name] = t_cross(pts, t_end, 0.37 * g0, True)
    tf = rel * model.REL_FAST_K
    want_s = tf * math.log(0.84 / 0.37)                      # fast state alone, from 84%
    want_l = tf * model.REL_SLOW_X * math.log(model.K_SLOW / 0.37)   # slow tail takes over
    ok = (t37["short"] is not None and t37["sustained"] is not None
          and abs(t37["short"] - want_s) < 0.03
          and abs(t37["sustained"] - want_l) < 0.05
          and t37["sustained"] > 2.5 * t37["short"])
    H.report("release:two-state", ok,
             "time to 37%%: short burst %.0f ms (est. %.0f), sustained %.0f ms (est. %.0f)"
             % (t37["short"] * 1e3, want_s * 1e3, t37["sustained"] * 1e3, want_l * 1e3))


def t_link():
    """Max uses the louder channel; Avg averages the powers, so a one-sided
    signal reads 3 dB lower and compresses less."""
    ch1 = steps_tone([-12], 1.0, f=HF)
    ch = [ch1, [0.0] * len(ch1)]
    base = dict(thr_db=-6.0, ratio=4.0, auto_mu=0, rel_s=0.1)
    gr = {}
    for mode in (0, 1):
        out = render("link_%d" % mode, dict(base, link_mode=mode), ch)
        gr[mode] = gr_at(ch[0], out[0], 0.8, win=4800)
    # thr_eff -24.  Max: level -12 -> x = 9*.75... see model.knee.
    want = (model.knee(12 * 0.75), model.knee(9 * 0.75))
    H.report("link", abs(gr[0] - want[0]) < 0.3 and abs(gr[1] - want[1]) < 0.3,
             "Max GR %.2f (want %.2f), Avg GR %.2f (want %.2f)"
             % (gr[0], want[0], gr[1], want[1]))


# ---- gate / expander ---------------------------------------------------------

def t_gate_off():
    """Gate Off, or Range 0, leaves the signal bit-identical (compressor 1:1)."""
    ch = program(SR * 3)
    for name, kw in (("off", dict(ratio=1.0, gate_mode=1, gate_range=40.0)),
                     ("range0", dict(ratio=1.0, gate_on=1, gate_mode=1, gate_range=0.0)),
                     ("range0x", dict(ratio=1.0, gate_on=1, gate_mode=0, gate_range=0.0))):
        out = render("gate_" + name, kw, ch)
        d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
        H.report("gate:" + name, d < 1e-7, "bit-transparent, maxdiff %.2e" % d)


def t_expand():
    """Expand mode: GR = 1.1 x (dB below Threshold), up to Range."""
    thr = -10.0                                 # -28 dBFS with the default Reference
    levels = [-20, -34, -40, -46, -52]
    seg = 0.8
    ch = mono(steps_tone(levels, seg, f=HF))
    kw = dict(ratio=1.0, gate_on=1, gate_mode=0, gate_thr=thr, gate_range=40.0, gate_rel=0.1)
    out = render("expand", kw, ch)
    worst, rows = 0.0, []
    for i, lv in enumerate(levels):
        lo = int((i * seg + seg - 0.12) * SR)
        got = gr_at(ch[0], out[0], i * seg + seg - 0.12, win=4800)
        want = max(0.0, (-18.0 + thr - lv) * 1.1)
        worst = max(worst, abs(got - want))
        rows.append("%d: %.1f (%.1f)" % (lv, got, want))
    H.report("expand:slope", worst < 0.5, "worst %.2f dB; level: GR (want) " % worst + ", ".join(rows))
    # Range is the asymptote: far below Threshold the GR stops at Range
    ch = mono(steps_tone([-20, -55], 1.0, f=HF))
    out = render("expand_range", dict(kw, gate_range=10.0), ch)
    got = gr_at(ch[0], out[0], 1.85, win=4800)
    H.report("expand:range", abs(got - 10.0) < 0.3, "GR %.2f dB at Range 10 (target would be 29.7)" % got)


def t_gate_hysteresis():
    """Gate mode closes 11.6 dB below Threshold and re-opens 2.2 dB below it."""
    thr = -10.0                                 # -28 dBFS
    l0, l1, secs, hold = -15.0, -55.0, 4.0, 0.4
    # hold first: the gate starts from REAPER's silent pre-roll, i.e. closed
    ch1 = f32(timed_tone([(l0, hold)]) + ramp_tone(l0, l1, secs, f=HF)
              + ramp_tone(l1, l0, secs, f=HF))
    ch = mono(ch1)
    kw = dict(ratio=1.0, gate_on=1, gate_mode=1, gate_thr=thr, gate_range=40.0,
              gate_rel=0.1, gate_fast=1)
    out = render("hysteresis", kw, ch)
    pts = gr_pts(ch[0], out[0], 0, len(ch1))
    lvl = lambda t: (l0 if t < hold else
                     l0 + (l1 - l0) * (t - hold) / secs if t < hold + secs else
                     l1 + (l0 - l1) * (t - hold - secs) / secs)
    tc = next(t for t, g in pts if hold < t < hold + secs and g > 2.0)
    to = next(t for t, g in pts if t > hold + secs and g < 2.0)
    lc, lo_ = lvl(tc), lvl(to)
    thr_dbfs = -18.0 + thr
    # The detector's own ripple: mean square of a tone at f ripples at 2f by
    # 1/sqrt(1 + (2 pi 2f tau)^2) of its mean.  Its dips close the gate and its
    # peaks open it a little before the RMS level gets there.
    rip = 10 * math.log10(1 + 1 / math.sqrt(1 + (2 * math.pi * 2 * HF * model.TAU_RMS) ** 2))
    wc, wo = thr_dbfs - 11.6 + rip, thr_dbfs - 2.2 - rip
    H.report("gate:hysteresis", abs(lc - wc) < 0.3 and abs(lo_ - wo) < 0.3,
             "closes at %.1f dBFS (want %.1f), opens at %.1f dBFS (want %.1f); "
             "level in dB, nominal %.1f / %.1f, detector ripple %.2f dB"
             % (lc, wc, lo_, wo, thr_dbfs - 11.6, thr_dbfs - 2.2, rip))


def t_gate_timing():
    """Gate attack lowers the GR (opening), release raises it (closing).
    Attack tau 0.68 ms (slow) / 40 us (fast); release tau 68 ms .. 1.77 s from the knob;
    Range is the asymptote of the release."""
    thr = -10.0
    # attack: closed for 0.5 s, then loud.  Time for the GR to fall to 37% of its start.
    t_at = {}
    for fast in (0, 1):
        ch = mono(timed_tone([(-60, 0.5), (-10, 0.2)]))
        kw = dict(ratio=1.0, gate_on=1, gate_mode=1, gate_thr=thr, gate_range=30.0,
                  gate_rel=0.1, gate_fast=fast)
        out = render("gtime_atk_%d" % fast, kw, ch)
        pts = gr_pts(ch[0], out[0], int(0.499 * SR), int(0.52 * SR))
        g0 = gr_mean(pts, 0.499, 0.5)
        t_at[fast] = t_cross(pts, 0.5, 0.37 * g0, True)
    ok = (t_at[0] is not None and t_at[1] is not None
          and abs(t_at[0] - 0.00068) < 0.00025 and t_at[1] < 0.00012
          and t_at[0] > 3 * t_at[1])
    H.report("gate:attack", ok, "slow %.3f ms (want 0.68), fast %.3f ms (want 0.04, one sample is 0.021)"
             % (t_at[0] * 1e3, t_at[1] * 1e3))
    # release: open, then quiet.  Time to 63.2% of Range = tau; plateau = Range.
    rows, ok = [], True
    for rel, rng, tau in ((0.1, 40.0, 0.068), (0.4, 20.0, 0.068 * 26 ** (math.log(4) / math.log(40))),
                          (2.0, 30.0, 0.068 * 26 ** (math.log(20) / math.log(40)))):
        tail = 3.0 * tau + 0.3
        ch = mono(timed_tone([(-10, 0.3), (-60, tail)]))
        kw = dict(ratio=1.0, gate_on=1, gate_mode=1, gate_thr=thr, gate_range=rng,
                  gate_rel=rel, gate_fast=1)
        out = render("gtime_rel_%g" % rel, kw, ch)
        pts = gr_pts(ch[0], out[0], int(0.3 * SR), int((0.3 + tail) * SR))
        t63 = t_cross(pts, 0.3, 0.632 * rng, False)
        plat = gr_mean(pts, 0.3 + tail - 0.05, 0.3 + tail)
        good = t63 is not None and abs(t63 - tau) < 0.06 * tau + 0.002 and abs(plat - rng) < 0.12 * rng
        ok &= good
        rows.append("rel %.1f: tau %.0f ms (want %.0f), plateau %.1f of %.0f dB"
                    % (rel, (t63 or 0) * 1e3, tau * 1e3, plat, rng))
    H.report("gate:release", ok, "; ".join(rows))


def t_gate_comp():
    """One detector, max of the two GRs: the gate sees the uncompressed
    signal, and the larger of the two GRs is applied, not their sum."""
    ch = mono(steps_tone([-40], 1.5, f=HF))
    base = dict(auto_mu=0, rel_s=0.1, gate_rel=0.1)
    gate = dict(gate_on=1, gate_mode=0, gate_thr=-10.0, gate_range=40.0)    # thr -28: GR 13.2
    comp = dict(thr_db=-30.0, ratio=20.0)                                   # thr -48: x = 8
    gr = {}
    for name, kw in (("gate", dict(base, ratio=1.0, **gate)), ("comp", dict(base, **comp)),
                     ("both", dict(base, **comp, **gate))):
        out = render("gc_" + name, kw, ch)
        gr[name] = gr_at(ch[0], out[0], 1.2, win=4800)
    want = max(gr["gate"], gr["comp"])
    # a gate that detected the compressed signal would see -40 - GR and read ~17.6 dB
    H.report("gate:max", abs(gr["both"] - want) < 0.3,
             "gate %.2f, comp %.2f, both %.2f (max %.2f, sum %.2f)"
             % (gr["gate"], gr["comp"], gr["both"], want, gr["gate"] + gr["comp"]))


def t_gate_lf():
    """Low frequencies ripple through the 80 us detector.  A tone well above
    the opening level must still leave the gate open (no chatter)."""
    kw = dict(ratio=1.0, gate_on=1, gate_mode=1, gate_thr=-10.0, gate_range=40.0, gate_rel=0.1)
    rows, ok = [], True
    for f in (40.0, 60.0, 100.0):
        ch = mono(steps_tone([-20], 1.5, f=f))
        out = render("lf_%d" % f, kw, ch)
        worst = max(gr_at(ch[0], out[0], t, win=480) for t in (0.5, 0.7, 0.9, 1.1, 1.3))
        ok &= worst < 1.0
        rows.append("%d Hz: GR <= %.2f dB" % (f, worst))
    H.report("gate:lf", ok, "; ".join(rows))


TESTS = [("params", t_params), ("canary", t_canary), ("model", t_model),
         ("knee", t_knee), ("static", t_static), ("makeup", t_makeup),
         ("attack", t_attack), ("release", t_release), ("link", t_link),
         ("gate_off", t_gate_off), ("expand", t_expand),
         ("hysteresis", t_gate_hysteresis), ("gate_timing", t_gate_timing),
         ("gate_comp", t_gate_comp), ("gate_lf", t_gate_lf)]

if __name__ == "__main__":
    H.run(TESTS)
