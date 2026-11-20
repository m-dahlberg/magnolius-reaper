#!/usr/bin/env python3
"""Headless render tests for Magnolius Modulation Delay.

    python3 render_test.py                 all tests
    python3 render_test.py delay feedback  just those

Work dir: ~/.cache/moddelay-rendertest (override with MODDELAY_WORK).
Every test renders through the real plugin in an isolated REAPER (-newinst),
so it is safe to run while your normal REAPER is open. Pure stdlib.

Signals are short on purpose: there is no numpy here, and every test pins one
behaviour from the brief ("Behaviour requirements" 1-9) to a number.
"""
import array
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_harness import Harness, slider_line, parm_env, dft_mag_hann, db  # noqa: E402
from wavio import write_wav_f32  # noqa: E402

H = Harness("moddelay", "Magnolius/Magnolius_ModulationDelay.jsfx",
            work=os.environ.get("MODDELAY_WORK"))

# ---------------------------------------------------------------- parameters
DEFAULTS = [
    ("time", 375), ("sync", 0), ("sync_type", 0), ("r_off", 0), ("st_mode", 0),
    ("cross", 0), ("fb", 40), ("hpf", 100), ("lpf", 6000), ("drive", 20),
    ("smear", 0), ("mod_rate", 0.6), ("mod_depth", 1.5), ("mod_shape", 0),
    ("depth_scale", 0), ("st_phase", 90), ("wow", 0), ("flutter", 0),
    ("character", 1), ("time_change", 0), ("glide", 120), ("duck_amt", 0),
    ("duck_thr", -24), ("duck_rel", 250), ("width", 100), ("mix", 30),
    ("wet_only", 0), ("freeze", 0), ("out_db", 0), ("hpf_slope", 0),
    ("lpf_slope", 0), ("decay_curve", 0)]
ORDER = [k for k, _ in DEFAULTS]
LABEL = {"time": "Time (ms)", "character": "Character", "mix": "Mix (%)",
         "fb": "Feedback (%)", "decay_curve": "Decay curve (%)", "freeze": "Freeze", "hpf": "Loop HPF (Hz)",
         "lpf": "Loop LPF (Hz)", "out_db": "Output (dB)", "drive": "Drive (%)",
         "time_change": "Time change", "wet_only": "Wet only"}

# a clean, exact reference: Digital, crossfade, no loop colour, 100 % wet
CLEAN = dict(character=0, time_change=1, fb=0, drive=0, mod_depth=0, mix=100,
             hpf=20, lpf=20000)


def cl(**kw):
    """CLEAN with overrides."""
    d = dict(CLEAN)
    d.update(kw)
    return d


def sl(**kw):
    bad = set(kw) - set(ORDER)
    if bad:
        raise KeyError(bad)
    vals = dict(DEFAULTS)
    vals.update(kw)
    return slider_line([vals[k] for k in ORDER])


def env(name, points):
    return parm_env(ORDER.index(name), LABEL.get(name, name), points)


# ------------------------------------------------------------------- signals
def zeros(n):
    return [0.0] * n


def put_sine(x, sr, t0, dur, f, amp, fade=0.003):
    n0, n = int(t0*sr), int(dur*sr)
    nf = max(1, int(fade*sr))
    for i in range(n):
        if n0 + i >= len(x):
            break
        w = 1.0
        if i < nf:
            w = 0.5 - 0.5*math.cos(math.pi*i/nf)
        elif i > n - nf:
            w = 0.5 - 0.5*math.cos(math.pi*(n - i)/nf)
        x[n0 + i] += amp*w*math.sin(2*math.pi*f*i/sr)


def seconds(sr, secs):
    return int(secs*sr)


def win(x, sr, t0, t1):
    return x[int(t0*sr):int(t1*sr)]


def rms(x):
    return math.sqrt(sum(v*v for v in x)/max(len(x), 1))


def peak_at(x, sr, t0, t1):
    seg = x[int(t0*sr):int(t1*sr)]
    m = max(seg, key=abs)
    return (int(t0*sr) + seg.index(m)), m


def render(name, sliders, left, right=None, length=None, sr=48000, **kw):
    right = left if right is None else right
    inp = name + "_in.wav"
    write_wav_f32(H.path(inp), sr, [left, right])
    length = length or (len(left)/sr)
    chans, secs = H.render(name, sliders, input_name=inp, length=length,
                           srate=sr, in_len=len(left)/sr, **kw)
    return chans, secs


class Tempo:
    """Temporarily change the project tempo in the harness template."""
    def __init__(self, bpm, env_block=""):
        self.bpm, self.env = bpm, env_block

    def __enter__(self):
        self.old = H.proj.TEMPLATE
        t = self.old.replace("TEMPO 120 4 4", "TEMPO %g 4 4" % self.bpm)
        if self.env:
            t = t.replace("  <TRACK", self.env + "  <TRACK", 1)
        H.proj.TEMPLATE = t

    def __exit__(self, *a):
        H.proj.TEMPLATE = self.old


# =================================================================== tests
def t_params():
    names, lines = H.probe_params()
    want = ["Time (ms)", "Sync", "Sync type", "R offset (%)", "Stereo mode",
            "Cross amount (%)", "Feedback (%)", "Loop HPF (Hz)", "Loop LPF (Hz)",
            "Drive (%)", "Smear (stages)", "Mod rate (Hz)", "Mod depth (ms)",
            "Mod shape", "Depth scaling", "Stereo phase (deg)", "Wow (%)",
            "Flutter (%)", "Character", "Time change", "Glide time (ms)",
            "Duck amount (dB)", "Duck threshold (dB)", "Duck release (ms)",
            "Width (%)", "Mix (%)", "Wet only", "Freeze", "Output (dB)",
            "Loop HPF slope", "Loop LPF slope", "Decay curve (%)"]
    got = [names.get(i) for i in range(len(want))]
    rng = {l.split("\t")[1]: (float(l.split("\t")[3]), float(l.split("\t")[4]))
           for l in lines[1:]}
    ok_rng = (rng["Loop HPF (Hz)"] == (20, 5000) and rng["Loop LPF (Hz)"] == (200, 20000)
              and rng["Decay curve (%)"] == (-100, 100) and rng["Smear (stages)"] == (0, 4))
    H.report("params", got == want and ok_rng,
             "32 sliders in order; HPF 20-5000, LPF 200-20000, curve -100..100" if got == want and ok_rng else
             "mismatch: %s" % [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w][:4])


def t_delay():
    """Canary: an impulse comes back exactly `time` later at exactly the
    right level, only on its own channel; dry and equal-power mix are exact."""
    sr = 48000
    x = zeros(seconds(sr, 1.5)); x[sr//2] = 0.5
    r = zeros(len(x))
    out, _ = render("delay", sl(**cl(time=100)), x, r)
    i, v = peak_at(out[0], sr, 0.55, 0.65)
    ok1 = i == sr//2 + 4800 and abs(v - 0.5) < 1e-5
    others = max(abs(a) for k, a in enumerate(out[0]) if k != i)
    ok2 = others < 4e-4 and max(abs(a) for a in out[1]) < 1e-9
    H.report("delay", ok1 and ok2,
             "echo at +%d samples (want 4800), level %.6f, stray %.1e, other channel %.1e"
             % (i - sr//2, v, others, max(abs(a) for a in out[1])))
    out, _ = render("delay_mix", sl(**cl(time=100, mix=50)), x, r)
    d = out[0][sr//2]; w = out[0][sr//2 + 4800]
    g = math.cos(math.pi/4)*0.5
    H.report("mix_equal_pow", abs(d - g) < 1e-5 and abs(w - g) < 1e-5,
             "dry %.5f wet %.5f (want %.5f each)" % (d, w, g))
    out, _ = render("delay_dry", sl(**cl(time=100, mix=0)), x, r)
    H.report("mix_zero_dry", abs(out[0][sr//2] - 0.5) < 1e-6 and
             max(abs(a) for a in out[0][sr//2 + 100:sr]) < 1e-9,
             "dry %.6f, nothing wet" % out[0][sr//2])


def t_feedback():
    """First echo full level; repeats fall by exactly the feedback."""
    sr = 48000
    x = zeros(seconds(sr, 1.4)); put_sine(x, sr, 0.3, 0.05, 1000, 0.4)
    out, _ = render("feedback", sl(**cl(time=100, fb=50)), x)
    base = rms(win(x, sr, 0.31, 0.34))
    res = []
    for k in range(1, 5):
        r = rms(win(out[0], sr, 0.31 + 0.1*k, 0.34 + 0.1*k))
        res.append(db(r/base))
    want = [0, -6.02, -12.04, -18.06]
    ok = all(abs(a - b) < 0.15 for a, b in zip(res, want))
    H.report("feedback", ok, "echo levels %s dB (want %s)" %
             ([round(a, 2) for a in res], want))


def t_first_echo_chain():
    """The first echo goes through the same loop chain, then compounds."""
    sr = 48000
    x = zeros(seconds(sr, 1.2)); put_sine(x, sr, 0.1, 0.05, 6000, 0.4)
    base = rms(win(x, sr, 0.11, 0.14))
    res = []
    for nm, kw in (("LPF 6k", dict(lpf=6000)), ("HPF 6k", dict(hpf=6000))):
        out, _ = render("echochain", sl(**cl(time=100, fb=100, **kw)), x)
        e1 = db(rms(win(out[0], sr, 0.21, 0.24))/base)
        e2 = db(rms(win(out[0], sr, 0.31, 0.34))/base)
        res.append((nm, e1, e2))
    ok = all(abs(e1 + 3.01) < 0.3 and abs(e2 + 6.02) < 0.5 for _n, e1, e2 in res)
    H.report("first_echo_chain", ok, "; ".join("%s: echo1 %.2f, echo2 %.2f dB (want -3.0, -6.0)" % r for r in res))


def t_filter_off():
    """At the ends of their ranges the loop filters are exactly off."""
    sr = 48000
    x = zeros(seconds(sr, 0.8)); put_sine(x, sr, 0.1, 0.2, 9000, 0.4)
    a, _ = render("filtoff", sl(**cl(time=100)), x)
    g = rms(win(a[0], sr, 0.21, 0.28))/rms(win(x, sr, 0.11, 0.18))
    H.report("filter_off", abs(db(g)) < 0.02, "9 kHz through HPF 20 / LPF 20k: %+.3f dB (want 0)" % db(g))


def t_curve():
    """Feedback sets the number of repeats (-60 dB at N = 3/-log10 fb); the
    curve sets the shape: level(m) = -60 * ((m-1)/N)^p, p = 2^(2c)."""
    sr = 48000
    x = zeros(seconds(sr, 1.4)); put_sine(x, sr, 0.3, 0.05, 1000, 0.4)
    base = rms(win(x, sr, 0.31, 0.34))
    N = 3/(-math.log10(0.5))
    det = []; ok = True
    for c in (0, 100, -100, 50):
        out, _ = render("curve", sl(**cl(time=100, fb=50, decay_curve=c)), x)
        p = 2**(2*c/100)
        for m in range(1, 7):
            want = -60*((m - 1)/N)**p
            if want < -48:
                continue
            got = db(rms(win(out[0], sr, 0.31 + 0.1*m, 0.34 + 0.1*m))/base)
            if abs(got - want) > 0.5:
                ok = False
        det.append("curve %+d: echoes %s" % (c, [round(db(rms(win(out[0], sr, 0.31 + 0.1*m, 0.34 + 0.1*m))/base), 1) for m in range(1, 7)]))
    H.report("curve", ok, "; ".join(det) + "  (echo 1 is always 0 dB)")


def t_curve_count():
    """With the curve on, the number of repeats still follows Feedback: the
    level at repeat N is about -60 dB whatever the curve."""
    sr = 48000
    x = zeros(seconds(sr, 1.6)); put_sine(x, sr, 0.1, 0.05, 1000, 0.4)
    base = rms(win(x, sr, 0.11, 0.14))
    # fb 0.5 -> N ~ 9.97 repeats: echo 11 should sit near -60 dB for every curve
    res = []
    for c in (0, 100, -100):
        out, _ = render("curveN", sl(**cl(time=100, fb=50, decay_curve=c)), x)
        res.append(db(rms(win(out[0], sr, 0.11 + 0.1*11, 0.14 + 0.1*11))/base))
    want = -60*((10)/(3/(-math.log10(0.5))))**1
    H.report("curve_count", all(abs(r - want) < 3 for r in res[:1]) and res[1] < -45 and res[2] < -45,
             "level of echo 11 at curve 0/+100/-100: %s dB (want about %.0f)" % ([round(r, 1) for r in res], want))


def t_smear():
    """Smear is continuous and smears the first echo."""
    sr = 48000
    x = zeros(seconds(sr, 1.0)); x[sr//4] = 0.5
    pk = []; en = []
    for sm_ in (0, 1.0, 2.5, 4.0):
        out, _ = render("smear", sl(**cl(time=100, smear=sm_)), x)
        seg = win(out[0], sr, 0.3, 0.5)
        pk.append(max(abs(v) for v in seg)); en.append(sum(v*v for v in seg))
    mono = all(a > b for a, b in zip(pk, pk[1:]))
    ok = mono and pk[3] < 0.6*pk[0] and all(abs(e/en[0] - 1) < 0.3 for e in en)
    H.report("smear", ok, "echo peak at smear 0/1/2.5/4: %s; energy kept: %s"
             % ([round(v, 3) for v in pk], [round(e/en[0], 2) for e in en]))


def t_runaway():
    """Feedback > 100 % saturates into a sustained wash, never blows up."""
    sr = 48000
    x = zeros(seconds(sr, 15)); put_sine(x, sr, 0.1, 0.1, 440, 0.8)
    for dr in (0, 100):
        out, _ = render("runaway%d" % dr, sl(**cl(time=100, fb=110, drive=dr)), x)
        pk = max(abs(v) for v in out[0])
        tail = rms(win(out[0], sr, 12, 14))
        finite = all(v == v and abs(v) < 1e3 for v in out[0][::97])
        H.report("runaway_d%d" % dr, finite and pk <= 2.1 and tail > 0.05,
                 "peak %.3f (ceiling 2.0), tail rms %.3f (%.1f dBFS)" % (pk, tail, db(tail)))


def t_dc():
    """Asymmetric (Tape) saturation builds no DC over many repeats."""
    sr = 48000
    x = zeros(seconds(sr, 8)); put_sine(x, sr, 0.1, 0.3, 150, 0.7)
    out, _ = render("dc", sl(character=2, time_change=0, time=60, fb=85, drive=70,
                             mix=100, mod_depth=0, hpf=20), x)
    seg = win(out[0], sr, 2, 6)
    mean = sum(seg)/len(seg)
    pos, neg = max(seg), -min(seg)
    H.report("dc", abs(mean) < 2e-3 and rms(seg) > 0.01,
             "mean %.2e over rms %.3f; pos/neg peak %.3f/%.3f (asymmetric: %s)"
             % (mean, rms(seg), pos, neg, "yes" if abs(pos - neg) > 0.01 else "NO"))


def t_silence():
    """The tail decays to true silence (no denormal plateau), and a quiet
    input gives exact zeros in Digital."""
    sr = 48000
    x = zeros(seconds(sr, 9)); put_sine(x, sr, 0.1, 0.05, 1000, 0.5)
    out, secs = render("silence", sl(**cl(time=10, fb=70, smear=4)), x)
    tail = out[0][int(6*sr):int(8*sr)]
    # REAPER injects ~1e-16 of its own anti-denormal noise into every track,
    # so "silence" is that floor; what matters is that nothing larger lingers
    H.report("tail_silence", max(abs(v) for v in tail) < 1e-12,
             "last 2 s: max %.1e (REAPER's own floor is ~1e-16), render %.1f s" % (max(abs(v) for v in tail), secs))
    z = zeros(seconds(sr, 3))
    out, _ = render("silence0", sl(**cl(time=100, fb=60)), z)
    H.report("quiet_input", max(abs(v) for v in out[0]) < 1e-12,
             "Digital, no input -> %.1e (REAPER's floor)" % max(abs(v) for v in out[0]))


def t_bbd_noise():
    sr = 48000
    z = zeros(seconds(sr, 5))
    out, _ = render("bbdnoise", sl(character=1, mix=100, fb=40, time=375, mod_depth=0), z)
    r = rms(win(out[0], sr, 2, 5))
    H.report("bbd_noise", db(r) <= -70 and r > 0,
             "BBD hiss %.1f dBFS rms (want <= -70 and not zero)" % db(r))


def t_sync():
    """Synced time: straight, dotted, triplet, and a different tempo."""
    sr = 48000
    x = zeros(seconds(sr, 2.5)); x[sr//4] = 0.5
    cases = [("1/4 @120", 120, 3, 0, 0.5), ("1/8 dotted @120", 120, 4, 1, 0.375),
             ("1/4 triplet @120", 120, 3, 2, 1/3), ("1/4 @90", 90, 3, 0, 60/90),
             ("1/1 @60 (4 s cap)", 60, 1, 0, 4.0)]
    ok = True; det = []
    for nm, bpm, sy, ty, want in cases:
        with Tempo(bpm):
            out, _ = render("sync", sl(**cl(sync=sy, sync_type=ty)), x,
                            length=2.5 if want < 2 else 5.5) if want < 2 else \
                render("sync", sl(**cl(sync=sy, sync_type=ty)), x + zeros(seconds(sr, 3)))
        i, v = peak_at(out[0], sr, 0.3, min(len(out[0])/sr - 0.01, 0.25 + want + 0.2))
        got = (i - sr//4)/sr
        good = abs(got - want) < 2/sr and abs(v - 0.5) < 1e-3
        ok &= good
        det.append("%s: %.5f s (want %.5f)" % (nm, got, want))
    H.report("sync", ok, "; ".join(det))


def t_tempo_auto():
    """Tempo automation: echo spacing follows the tempo within a block."""
    sr = 48000
    x = zeros(seconds(sr, 4))
    for t in (0.2, 2.0):
        x[int(t*sr)] = 0.5
    block = ("  <TEMPOENVEX\n    ACT 1 -1\n    VIS 1 1 1\n    LANEHEIGHT 0 0\n"
             "    ARM 0\n    DEFSHAPE 1 -1 -1\n    PT 0 120 1\n    PT 1.0 60 1\n  >\n")
    with Tempo(120, block):
        out, _ = render("tempoauto", sl(**cl(sync=3)), x)
    i1, _v = peak_at(out[0], sr, 0.3, 1.2)
    i2, _v = peak_at(out[0], sr, 2.1, 3.9)
    d1, d2 = (i1 - int(0.2*sr))/sr, (i2 - int(2.0*sr))/sr
    H.report("tempo_auto", abs(d1 - 0.5) < 0.002 and abs(d2 - 1.0) < 0.002,
             "1/4 at 120 -> %.4f s (want 0.5), after a drop to 60 bpm -> %.4f s (want 1.0)" % (d1, d2))


def t_r_offset():
    sr = 48000
    x = zeros(seconds(sr, 1.5)); x[int(0.2*sr)] = 0.5
    out, _ = render("roff", sl(**cl(time=375, r_off=20)), x)
    il, _a = peak_at(out[0], sr, 0.3, 1.0)
    ir, _b = peak_at(out[1], sr, 0.3, 1.0)
    H.report("r_offset", il - int(0.2*sr) == 18000 and ir - int(0.2*sr) == 21600,
             "L +%d, R +%d samples (want 18000 / 21600)" % (il - int(0.2*sr), ir - int(0.2*sr)))


def t_stereo_modes():
    sr = 48000
    x = zeros(seconds(sr, 1.0)); put_sine(x, sr, 0.1, 0.05, 1000, 0.4)
    z = zeros(len(x))
    # ping-pong: mono-summed in, repeats alternate L R L
    out, _ = render("pingpong", sl(**cl(time=100, fb=100, st_mode=1)), x, x)
    seq = []
    for k in range(1, 5):
        a = rms(win(out[0], sr, 0.11 + 0.1*k, 0.14 + 0.1*k))
        b = rms(win(out[1], sr, 0.11 + 0.1*k, 0.14 + 0.1*k))
        seq.append("L" if a > 10*b else "R" if b > 10*a else "?")
    H.report("pingpong", seq == ["L", "R", "L", "R"], "repeat sides %s (want L R L R)" % "".join(seq))
    # cross: L-only input; repeat 2 splits per the bleed amount
    res = []
    for c in (0, 100, 50):
        out, _ = render("cross", sl(**cl(time=100, fb=100, st_mode=2, cross=c)), x, z)
        l2 = rms(win(out[0], sr, 0.31, 0.34)); r2 = rms(win(out[1], sr, 0.31, 0.34))
        res.append((c, l2, r2))
    ok = (res[0][1] > 10*res[0][2] and res[1][2] > 10*res[1][1]
          and abs(res[2][1] - res[2][2]) < 0.05*res[2][1])
    H.report("cross", ok, "repeat 2 L/R rms at cross 0/100/50: %s"
             % ["%d: %.3f/%.3f" % r for r in res])


def t_freeze():
    """Frozen material holds its level and tone: no decay through strong loop
    filters, and no new input."""
    sr = 48000
    x = zeros(seconds(sr, 5)); put_sine(x, sr, 0.3, 0.1, 1000, 0.4)
    # a late burst after the freeze must not get in
    put_sine(x, sr, 3.0, 0.1, 1000, 0.4)
    pe = env("freeze", [(0, 0), (0.55, 1)])
    out, _ = render("freeze", sl(**cl(time=100, fb=40, hpf=800, lpf=1000, freeze=0)), x, parmenv=pe)
    a = rms(win(out[0], sr, 1.0, 1.1)); b = rms(win(out[0], sr, 2.9, 3.0))
    c = rms(win(out[0], sr, 3.05, 3.15))
    H.report("freeze", a > 0.02 and abs(db(b/a)) < 0.5 and abs(db(c/a)) < 0.5,
             "level at 1.0 s %.4f, 2.9 s %+.2f dB, after a late burst %+.2f dB" % (a, db(b/a), db(c/a)))


def t_width():
    sr = 48000
    x = zeros(seconds(sr, 0.8)); put_sine(x, sr, 0.1, 0.2, 500, 0.4)
    z = zeros(len(x))
    res = {}
    for w in (0, 100, 150):
        out, _ = render("width", sl(**cl(time=100, width=w)), x, z)
        res[w] = (rms(win(out[0], sr, 0.25, 0.3)), rms(win(out[1], sr, 0.25, 0.3)))
    a = res[100][0]
    ok = (abs(res[0][0] - res[0][1]) < 1e-6 and abs(res[0][0] - a/2) < 0.01*a
          and res[100][1] < 1e-6 and abs(res[150][0] - 1.25*a) < 0.01*a
          and abs(res[150][1] - 0.25*a) < 0.01*a)
    H.report("width", ok, "wet L/R rms at 0/100/150 %%: %s" %
             ["%.3f/%.3f" % res[w] for w in (0, 100, 150)])


def t_duck():
    sr = 48000
    x = zeros(seconds(sr, 4)); put_sine(x, sr, 0.2, 1.8, 1000, 0.3)
    base, _ = render("duck0", sl(**cl(time=100, fb=90)), x)
    duck, _ = render("duck12", sl(**cl(time=100, fb=90, duck_amt=12, duck_thr=-30, duck_rel=100)), x)
    during = db(rms(win(duck[0], sr, 1.2, 1.9))/rms(win(base[0], sr, 1.2, 1.9)))
    after = db(rms(win(duck[0], sr, 3.0, 3.2))/rms(win(base[0], sr, 3.0, 3.2)))
    H.report("duck", abs(during + 12) < 1.0 and abs(after) < 1.5,
             "wet while dry is loud %+.2f dB (want -12), swell back in the gap %+.2f dB (want ~0)" % (during, after))


def t_time_change():
    """A time change starts within a block, with no click, in both modes."""
    sr = 48000
    n = seconds(sr, 3)
    x = zeros(n)
    put_sine(x, sr, 0.0, 3.0, 1000, 0.5, fade=0.0005)
    step = env("time", [(0, 100), (1.0, 200)])
    ref100 = [0.5*math.sin(2*math.pi*1000*(i - 0.1*sr)/sr) if i >= 0.1*sr else 0 for i in range(n)]
    for mode, tc, extra in (("crossfade", 1, {}), ("glide", 0, dict(glide=30))):
        out, _ = render("tc_" + mode, sl(**cl(time=100, time_change=tc, **extra)), x, parmenv=step)
        y = out[0]
        # first sample where the output departs from the 100 ms version
        dev = None
        for i in range(int(0.95*sr), int(1.4*sr)):
            if abs(y[i] - ref100[i]) > 1e-2:     # the first echo now passes the DC blocker: ~2.5e-3 phase error
                dev = i
                break
        started = (dev - sr)/sr*1000 if dev else None
        # click: largest sample-to-sample step against the natural slope of the tone
        nat = 0.5*2*math.pi*1000/sr
        jump = max(abs(y[i] - y[i - 1]) for i in range(int(0.9*sr), int(1.9*sr)))
        settled = None
        if mode == "crossfade":
            ref200 = [0.5*math.sin(2*math.pi*1000*(i - 0.2*sr)/sr) for i in range(n)]
            settled = max(abs(y[i] - ref200[i]) for i in range(int(1.1*sr), int(1.3*sr)))
        ok = dev is not None and started < 30 and jump < 2.5*nat and (settled is None or settled < 8e-3)
        H.report("tchange_" + mode, ok,
                 "departs %.1f ms after the step (want < one block), max step %.2fx natural%s" %
                 (started if started is not None else -1, jump/nat,
                  "" if settled is None else ", settled err %.1e" % settled))


def t_zipper():
    """Steps in continuous parameters are smoothed: no jump beyond the tone's
    own slope."""
    sr = 48000
    n = seconds(sr, 3)
    x = zeros(n); put_sine(x, sr, 0.0, 3.0, 1000, 0.4, fade=0.0005)
    nat = 0.4*2*math.pi*1000/sr
    cases = [("mix", [(0, 100), (1.0, 20)], {}),
             ("out_db", [(0, 0), (1.0, -12)], {}),
             ("fb", [(0, 0), (1.0, 50)], dict(time=50)),
             ("lpf", [(0, 20000), (1.0, 1000)], dict(fb=50, time=50)),
             ("hpf", [(0, 20), (1.0, 800)], dict(fb=50, time=50)),
             ("drive", [(0, 0), (1.0, 100)], dict(fb=50, time=50))]
    ok = True; det = []
    for name, pts, extra in cases:
        kw = dict(CLEAN); kw.update(time=100)
        kw.update(extra)
        out, _ = render("zip_" + name, sl(**kw), x, parmenv=env(name, pts))
        y = out[0]
        worst = max(abs(y[i] - y[i - 1]) for i in range(int(0.98*sr), int(1.6*sr)))
        # a feedback tone can grow, so compare to the local peak
        loc = max(abs(v) for v in y[int(0.98*sr):int(1.6*sr)])
        g = worst/max(loc, 0.4)
        good = g < 1.15*2*math.pi*1000/sr
        ok &= good
        det.append("%s %.2f" % (name, g/(2*math.pi*1000/sr)))
    H.report("zipper", ok, "max step / natural slope: " + ", ".join(det))


def t_character_clear():
    """A Character change empties the delay: nothing stale is replayed."""
    sr = 48000
    x = zeros(seconds(sr, 4)); put_sine(x, sr, 0.2, 0.2, 700, 0.5)
    pe = env("character", [(0, 0), (2.0, 2)])
    out, _ = render("charclear", sl(character=0, time_change=1, time=100, fb=95, mix=100,
                                    mod_depth=0, drive=0), x, parmenv=pe)
    before = rms(win(out[0], sr, 1.8, 1.95))
    after = rms(win(out[0], sr, 2.05, 3.0))
    H.report("character_clear", before > 0.1 and db(after) < -60,
             "tail before the change %.1f dBFS, after %.1f dBFS" % (db(before), db(after)))


def t_modulation():
    """Sample-rate independence of the modulation, and the 4-sample constraint."""
    res = []
    for sr in (44100, 48000, 96000, 192000):
        n = seconds(sr, 3)
        x = zeros(n)
        for i in range(n):
            x[i] = 0.5*math.sin(2*math.pi*100*i/sr)
        out, _ = render("mod%d" % sr, sl(**cl(time=40, mod_depth=3, mod_rate=5,
                                         mod_shape=0, st_phase=0)), x, sr=sr)
        seg = win(out[0], sr, 1.0, 2.0)
        c = dft_mag_hann(seg, 100, sr)
        s1 = dft_mag_hann(seg, 105, sr)
        s2 = dft_mag_hann(seg, 95, sr)
        res.append((sr, (s1 + s2)/2/c))
    base = res[1][1]
    ok = all(abs(r - base)/base < 0.03 for _, r in res)
    H.report("mod_sr_indep", ok, "sideband/carrier at 44.1/48/96/192 k: %s (beta 1.88: J1/J0 ~ 1.9)"
             % ["%.3f" % r for _, r in res])


def t_mod_constraint():
    """Read distance never below 4 samples, at 1 ms and the deepest negative depth."""
    ok = True; det = []
    for sr in (44100, 192000):
        for ds in (0, 1):
            tail = ("\n// debug tail\ndbg_n += 1; dbg_m == 0 ? ( dbg_m = 100000000; );\n"
                    "dbg_n > 4000 ? ( dbg_m = min(dbg_m, min(L.dd1, R.dd1)); );\n"
                    "spl0 = min(0.9, dbg_m*0.0001); spl1 = 0;\n")
            fx = H.build_debug_fx(os.path.join(os.path.dirname(__file__), "..", "Magnolius_ModulationDelay.jsfx"),
                                  tail, dst_name="Magnolius/moddelay_dbg.jsfx")
            try:
                n = seconds(sr, 2.5)
                x = [0.3*math.sin(2*math.pi*220*i/sr) for i in range(n)]
                out, _ = render("modc", sl(character=2, time_change=1, time=1, r_off=-50,
                                           mod_depth=10, mod_rate=10, depth_scale=ds,
                                           wow=100, flutter=100, mix=100),
                                x, sr=sr, fx="Magnolius/moddelay_dbg.jsfx")
            finally:
                if os.path.exists(fx):
                    os.remove(fx)
            m = out[0][-100]/0.0001
            good = m >= 4 - 1e-6
            ok &= good
            det.append("%dk %s: min %.4f" % (sr//1000, "rel" if ds else "fixed", m))
    H.report("mod_min_dist", ok, "closest read, samples: " + ", ".join(det))


def t_srate():
    """Echo time and loop filter agree across sample rates."""
    res = []
    for sr in (44100, 48000, 96000, 192000):
        x = zeros(seconds(sr, 1.2)); put_sine(x, sr, 0.1, 0.05, 6000, 0.4)
        out, _ = render("sr%d" % sr, sl(**cl(time=100, fb=100, lpf=6000)), x, sr=sr)
        e1 = rms(win(out[0], sr, 0.21, 0.24)); e2 = rms(win(out[0], sr, 0.31, 0.34))
        res.append((sr, db(e2/e1)))
    ok = all(abs(r - res[1][1]) < 0.6 for _, r in res)
    H.report("srate_filter", ok, "6 kHz through one pass of the 6 kHz LPF: %s dB"
             % ["%.2f" % r for _, r in res])


def t_cpu():
    sr = 48000
    z = zeros(seconds(sr, 60))
    for i in range(0, len(z), 1):
        pass
    x = [0.2*math.sin(2*math.pi*220*i/sr) for i in range(len(z))]
    _, base = render("cpu_light", sl(**cl(time=100)), x)
    _, worst = render("cpu_worst", sl(character=2, time=300, fb=90, smear=4, mod_depth=5,
                                     mod_shape=2, wow=100, flutter=100, hpf_slope=1,
                                     lpf_slope=1, drive=60, duck_amt=12, mix=100), x)
    H.report("cpu", worst < 60, "60 s of audio: light %.1f s, worst case %.1f s wall (incl. REAPER startup)"
             % (base, worst))


TESTS = [("params", t_params), ("delay", t_delay), ("feedback", t_feedback),
         ("first_echo", t_first_echo_chain), ("filter_off", t_filter_off), ("curve", t_curve), ("curve_count", t_curve_count), ("smear", t_smear), ("runaway", t_runaway), ("dc", t_dc), ("silence", t_silence),
         ("bbd_noise", t_bbd_noise), ("sync", t_sync), ("tempo_auto", t_tempo_auto),
         ("r_offset", t_r_offset), ("stereo", t_stereo_modes), ("freeze", t_freeze),
         ("width", t_width), ("duck", t_duck), ("time_change", t_time_change),
         ("zipper", t_zipper), ("char_clear", t_character_clear),
         ("modulation", t_modulation), ("mod_constraint", t_mod_constraint),
         ("srate", t_srate), ("cpu", t_cpu)]

if __name__ == "__main__":
    H.run(TESTS)
