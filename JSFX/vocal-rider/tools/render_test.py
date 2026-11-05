#!/usr/bin/env python3
"""Headless render tests for "Magnolius_VocalRider.jsfx".

    ./render_test.py                 # everything
    ./render_test.py canary hold     # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open. Work files land in ~/.cache/vocal-rider-rendertest
(VR_WORK overrides). VR_FX_NAME overrides the FX lookup name.

Prerequisite: "Magnolius_VocalRider.jsfx" symlinked (never copied) somewhere
under <resource>/Effects/.

What these prove: the plugin agrees with model.py sample for sample, the
gain lands on paper numbers (Amount, Max boost, Max cut), gaps hold the gain,
quiet frames are discounted, and the reported latency is the real one. What
they do not prove: that it sounds good on a vocal, or that the panel draws.
"""
import array
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
from render_harness import Harness, maxdiff, parm_env, rms, slider_line  # noqa: E402

SR = 48000
TOL = 2e-5

H = Harness("vocal-rider",
            os.environ.get("VR_FX_NAME", "Magnolius_VocalRider.jsfx"),
            work=os.environ.get("VR_WORK"))


def S(**kw):
    bad = set(kw) - set(model.NAMES)
    if bad:
        raise KeyError("unknown slider(s): %s" % sorted(bad))
    v = dict(model.DEFAULTS, **kw)
    return slider_line([v[n] for n in model.NAMES])


def render(name, kw, chans, srate=SR, parmenv=None):
    H.write_input(name + "_in.wav", chans, srate)
    secs = len(chans[0]) / srate
    out, _ = H.render(name, S(**kw), input_name=name + "_in.wav",
                      length=secs, in_len=secs, srate=srate, parmenv=parmenv)
    return [o[:len(chans[0])] for o in out]


# ---------------------------------------------------------------------------
# signals
# ---------------------------------------------------------------------------

def f32(x):
    return list(array.array("f", x))


def tone_f(srate):
    # 1 kHz-ish, an exact number of cycles in 20 ms windows at every rate used
    return 1000.0


def segments(segs, srate=SR):
    """segs: [(seconds, rms_db or None), ...] -> stereo sine, None = silence.
    Each segment's sine restarts at phase 0, so its level is exact."""
    f = tone_f(srate)
    x = []
    for secs, lvl in segs:
        n = int(round(secs * srate))
        if lvl is None:
            x.extend([0.0] * n)
        else:
            a = math.sqrt(2) * 10 ** (lvl / 20)
            x.extend(a * math.sin(2 * math.pi * f * i / srate) for i in range(n))
    x = f32(x)
    return [x, list(x)]


class LCG:
    def __init__(self, seed):
        self.s = seed

    def uni(self):
        self.s = (1103515245 * self.s + 12345) & 0x7fffffff
        return self.s / 0x3fffffff - 1.0


def program(srate=SR):
    """Vocal-ish material: syllable-rate AM on two tones plus noise, in
    phrases at different levels with gaps, a quiet tail, and a long pause."""
    r = LCG(7)
    plan = [(1.2, -26), (0.5, None), (0.9, -14), (0.3, -40), (0.4, None),
            (1.0, -22), (2.6, None), (0.8, -30)]
    left, right = [], []
    k = 0
    for secs, lvl in plan:
        n = int(round(secs * srate))
        for _ in range(n):
            if lvl is None:
                left.append(0.0003 * r.uni())     # room noise, ~-75 dB
                right.append(0.0003 * r.uni())
            else:
                t = 2 * math.pi * k / srate
                am = 0.6 + 0.4 * math.sin(2 * math.pi * 4.5 * k / srate)
                a = 10 ** (lvl / 20) * am
                left.append(a * (1.1 * math.sin(220 * t) + 0.5 * math.sin(1310 * t)
                                 + 0.15 * r.uni()))
                right.append(a * (1.0 * math.sin(221 * t + 1) + 0.45 * math.sin(990 * t)
                                  + 0.15 * r.uni()))
            k += 1
    return [f32(left), f32(right)]


def voice(secs, lvl, srate=SR):
    """A harmonic stack on 220 Hz: voiced, energy below 1.5 kHz."""
    n = int(round(secs * srate))
    x = [sum(math.sin(2 * math.pi * 220 * h * k / srate) / h for h in range(1, 7))
         for k in range(n)]
    m = math.sqrt(sum(v * v for v in x) / n)
    a = 10 ** (lvl / 20) / m
    return [a * v for v in x]


def noise(secs, lvl, seed=5, srate=SR):
    """White noise: most of its energy above 3 kHz, like a breath."""
    r = LCG(seed)
    n = int(round(secs * srate))
    x = [r.uni() for _ in range(n)]
    m = math.sqrt(sum(v * v for v in x) / n)
    return [v * 10 ** (lvl / 20) / m for v in x]


def build(parts):
    x = []
    for p in parts:
        x.extend(p)
    x = f32(x)
    return [x, list(x)]


def gain_at(out, inp, t, srate=SR, win=0.02):
    """Gain in dB applied around time t, from output/input RMS over `win`."""
    lo = int(t * srate)
    hi = lo + int(win * srate)
    return 20 * math.log10(rms(out[0], lo, hi) / max(rms(inp[0], lo, hi), 1e-30))


def near(a, b, tol):
    return abs(a - b) <= tol


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

def t_params():
    names, _ = H.probe_params()
    want = {0: "Target level", 1: "Max boost", 2: "Ride speed", 3: "Noise floor",
            5: "Vocal loudness window", 8: "Max cut", 9: "Correction amount",
            10: "Lookahead", 11: "Breath guard", 12: "Breath threshold",
            13: "Tail lift"}
    bad = [(i, names.get(i)) for i, w in want.items()
           if not (names.get(i) or "").startswith(w)]
    H.report("params", not bad, "ok, 14 sliders" if not bad else "mismatch %s" % bad)


def t_model():
    for name, kw in [("model_def", {}),
                     ("model_mix", dict(amount=80, max_boost=9, max_cut=4,
                                        lookahead=50, speed=200, trim=-1.5))]:
        inp = program()
        out = render(name, kw, inp)
        ml, mr, _ = model.run(inp, SR, **kw)
        # REAPER compensates the reported latency, so the render is the
        # model's output moved L samples earlier
        L = model.lookahead_samples(kw.get("lookahead", 0), SR)
        n = len(ml) - L
        e = max(maxdiff(out[0][:n], ml[L:]), maxdiff(out[1][:n], mr[L:]))
        H.report(name, e < TOL, "max |render - model| = %.2e" % e)


def t_canary(srate=SR, tag="canary"):
    inp = segments([(4.0, -24)], srate)
    out = render(tag, {}, inp, srate)
    g = gain_at(out, inp, 3.5, srate)
    H.report(tag, near(g, 6.0, 0.05), "gain %+.3f dB (want +6.00)" % g)


def t_amount():
    inp = segments([(4.0, -24)])
    out = render("amount", dict(amount=50), inp)
    g = gain_at(out, inp, 3.5)
    H.report("amount", near(g, 3.0, 0.05), "50 %%: gain %+.3f dB (want +3.00)" % g)


def t_limits():
    inp = segments([(4.0, -34)])
    out = render("limit_boost", dict(max_boost=4, max_cut=10), inp)
    gb = gain_at(out, inp, 3.5)
    inp = segments([(4.0, -6)])
    out = render("limit_cut", dict(max_boost=10, max_cut=2), inp)
    gc = gain_at(out, inp, 3.5)
    ok = near(gb, 4.0, 0.02) and near(gc, -2.0, 0.02)
    H.report("limits", ok, "boost cap 4: %+.3f, cut cap 2: %+.3f" % (gb, gc))


def t_hold():
    # wants +8; a 1 s gap must not glide it back toward 0
    inp = segments([(3.0, -26), (1.0, None), (1.0, -26)])
    out = render("hold", dict(max_boost=12), inp)
    before = gain_at(out, inp, 2.9)
    after = gain_at(out, inp, 4.0)
    H.report("hold", near(after, before, 0.5),
             "end of phrase %+.2f, start of next %+.2f dB" % (before, after))


def t_release():
    inp = segments([(3.0, -26), (4.5, None), (0.5, -26)])
    out = render("release_boost", dict(max_boost=12), inp)
    b0, b1 = gain_at(out, inp, 2.9), gain_at(out, inp, 7.5)
    inp = segments([(3.0, -12), (4.5, None), (0.5, -12)])
    out = render("release_cut", {}, inp)
    c0, c1 = gain_at(out, inp, 2.9), gain_at(out, inp, 7.5)
    ok = b0 > 7.5 and b1 < 2.0 and near(c1, c0, 0.3)
    H.report("release", ok, "boost %+.2f -> %+.2f after 4.5 s gap; cut %+.2f -> %+.2f"
             % (b0, b1, c0, c1))


def t_weighting():
    # at target, then 0.3 s 15 dB under (a quiet syllable), then back
    inp = segments([(2.0, -18), (0.3, -33), (0.5, -18)])
    out = render("weight_quiet", dict(max_boost=12), inp)
    gq = gain_at(out, inp, 2.28)
    # control: 4 dB under is inside the knee and moves at full rate
    inp = segments([(2.0, -18), (0.3, -22), (0.5, -18)])
    out = render("weight_knee", dict(max_boost=12), inp)
    gk = gain_at(out, inp, 2.28)
    # what the quiet burst would do unweighted: two-pole step toward +12
    tau = 0.3 * 0.5 * 1.5
    x = 0.3 / tau
    unweighted = 12 * (1 - (1 + x) * math.exp(-x))
    ok = gq < 1.0 and gk > 1.0
    H.report("weighting", ok,
             "15 dB under: %+.2f (unweighted ~%+.1f); 4 dB under: %+.2f"
             % (gq, unweighted, gk))


BREATH_KW = dict(win_v=300, speed=222, floor=-60, max_boost=12, lookahead=200)


def t_breath():
    # a voiced phrase, a 1.5 s breath above the gate, the next phrase.
    # -24 dB wants a boost; -10 dB wants a cut.
    gap = [0.0] * int(0.1 * SR)
    L = model.lookahead_samples(BREATH_KW["lookahead"], SR)
    res, err = {}, 0.0
    for lvl in (-24, -10):
        inp = build([voice(4.0, lvl), gap, noise(1.5, lvl - 22), voice(1.0, lvl)])
        for guard in (0, 1, 2):
            kw = dict(BREATH_KW, breath_guard=guard)
            out = render("breath_%d_g%d" % (-lvl, guard), kw, inp)
            end = gain_at(out, inp, 3.8, win=0.1)
            gb = [gain_at(out, inp, 4.12 + 0.02 * k) for k in range(70)]
            res[lvl, guard] = (end, max(gb), sorted(gb)[len(gb) // 2])
            if guard:
                ml, _, _ = model.run(inp, SR, **kw)
                err = max(err, maxdiff(out[0][:len(ml) - L], ml[L:]))
    b, c = (lambda g: res[-24, g]), (lambda g: res[-10, g])
    ok = (b(0)[1] - b(0)[0] > 2.0                  # unguarded: the breath rises
          and b(1)[1] - b(1)[0] < 0.3              # Freeze: held at the phrase
          and b(2)[0] > 3 and abs(b(2)[2]) < 0.1   # No boost: a boost goes to 0 dB
          and c(1)[1] - c(1)[0] < 0.3              # a cut is frozen in both modes
          and c(2)[1] - c(2)[0] < 0.3 and c(2)[0] < -3
          and err < TOL)
    H.report("breath", ok,
             "after %+.1f dB: off %+.2f, freeze %+.2f, no boost %+.2f dB; "
             "after %+.1f dB: freeze %+.2f, no boost %+.2f dB; model %.1e"
             % (b(0)[0], b(0)[2], b(1)[2], b(2)[2], c(1)[0], c(1)[2], c(2)[2], err))


def t_sibilant():
    # a noise burst at phrase level inside a phrase is not a breath
    inp = build([voice(2.0, -24), noise(0.15, -30), voice(1.0, -24)])
    outs = [render("sib_g%d" % g, dict(BREATH_KW, breath_guard=g), inp)
            for g in (0, 1)]
    e = max(maxdiff(outs[0][0], outs[1][0]), maxdiff(outs[0][1], outs[1][1]))
    H.report("sibilant", e == 0.0, "guard on vs off: max diff %.1e" % e)


USER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                         "Test files", "Breaths test.wav")


def frame_gains(o, ein, fr, nf, trim):
    """Applied gain in dB per 10 ms frame, from output and input energy."""
    g = []
    for f in range(nf):
        eo = sum(v * v for v in o[f * fr:(f + 1) * fr])
        g.append(10 * math.log10((eo + 1e-30) / (ein[f] + 1e-30)) - trim)
    return g


def t_userfile():
    """Acceptance on the user's take, at the user's settings.
    Freeze: no breath more than 1 dB above the phrase before it.
    No boost: as Freeze after a cut; after a boost, no breath above +0.25 dB
    inside the breath. The first and last 20 ms are the guard's ramps (it
    engages over 10 ms and lets go over 50 ms, both 20 ms early), reported
    separately.
    Skipped when the file is absent (it is not in the repository)."""
    if not os.path.exists(USER_FILE):
        H.report("userfile", True, "skipped, no %s" % USER_FILE)
        return
    import wave
    w = wave.open(USER_FILE)
    sr, nfr = w.getframerate(), w.getnframes()
    dst = H.path("userfile_in.wav")
    if not os.path.exists(dst):
        os.symlink(os.path.abspath(USER_FILE), dst)
    d = w.readframes(nfr)
    b = bytearray(4 * nfr)
    b[1::4] = d[0::3]
    b[2::4] = d[1::3]
    b[3::4] = d[2::3]
    a = array.array("i")
    a.frombytes(bytes(b))
    x = [v / 2147483648.0 for v in a]
    lpc = model.rbj("lp", model.BR_LP, sr)
    hpc = model.rbj("hp", model.BR_HP, sr)
    fr = sr // 100
    nf = nfr // fr
    lvl, rat, ein = [], [], []
    l1 = l2 = l3 = l4 = h1 = h2 = h3 = h4 = 0.0
    for f in range(nf):
        ee = el = eh = 0.0
        for i in range(f * fr, (f + 1) * fr):
            s = x[i]
            yl = lpc[0] * s + lpc[1] * l1 + lpc[2] * l2 - lpc[3] * l3 - lpc[4] * l4
            l2, l1, l4, l3 = l1, s, l3, yl
            yh = hpc[0] * s + hpc[1] * h1 + hpc[2] * h2 - hpc[3] * h3 - hpc[4] * h4
            h2, h1, h4, h3 = h1, s, h3, yh
            ee += s * s
            el += yl * yl
            eh += yh * yh
        lvl.append(10 * math.log10(ee / fr + 1e-15))
        rat.append(10 * math.log10((eh + 1e-15) / (el + 1e-15)))
        ein.append(ee)

    def bl(k):
        return k < nf and -70 < lvl[k] < -36 and rat[k] > -8 and ein[k] > 1e-12

    runs, i = [], 0      # breath-like frames, one-frame dropouts bridged
    while i < nf:
        if bl(i):
            j = i
            while bl(j) or bl(j + 1):
                j += 1
            if j - i >= 8:
                runs.append((i, j))
            i = j
        else:
            i += 1
    trim = 1.58
    kw = dict(target=-24.1, max_boost=6, speed=222, floor=-28, win_v=300,
              trim=trim, max_cut=6, amount=58, lookahead=200)
    msg, ok = [], True
    for guard, label in ((1, "freeze"), (2, "no boost")):
        out, _ = H.render("userfile_g%d" % guard, S(breath_guard=guard, **kw),
                          input_name="userfile_in.wav", length=nfr / sr,
                          in_len=nfr / sr, srate=sr)
        o = out[0]
        fgain = frame_gains(o, ein, fr, nf, trim)
        if guard == 2:
            fg_100 = fgain

        def gain(f, fgain=fgain):
            return fgain[f]

        worst_rise, worst_boost, worst_ramp, nb = -99.0, -99.0, -99.0, 0
        for i, j in runs:
            before = [gain(k) for k in range(max(0, i - 60), i)
                      if lvl[k] > -32 and ein[k] > 1e-12]
            if not before:
                continue
            nb += 1
            pb = sum(before) / len(before)
            top = max(gain(k) for k in range(i, j) if ein[k] > 1e-12)
            if guard == 2 and pb > 0:
                edge = [i, i + 1, j - 2, j - 1]
                worst_ramp = max(worst_ramp, max(gain(k) for k in edge
                                                 if ein[k] > 1e-12))
                worst_boost = max(worst_boost, max(gain(k) for k in range(i + 2, j - 2)
                                                   if ein[k] > 1e-12))
            else:
                worst_rise = max(worst_rise, top - pb)
        ok = ok and nb > 10 and worst_rise < 1.0
        if guard == 2:
            ok = ok and worst_boost < 0.25
            msg.append("%s: after a cut %+.2f; after a boost %+.2f dB "
                       "(edge ramps %+.2f)"
                       % (label, worst_rise, worst_boost, worst_ramp))
        else:
            msg.append("%s: worst %+.2f over the phrase" % (label, worst_rise))
    H.report("userfile", ok, "%d breaths; %s" % (nb, "; ".join(msg)))

    # Tail lift 0 %, against the No boost render above (Tail lift 100 %):
    # the ends of fading notes must no longer be lifted over the note body
    out, _ = H.render("userfile_tail0", S(breath_guard=2, tail_lift=0, **kw),
                      input_name="userfile_in.wav", length=nfr / sr,
                      in_len=nfr / sr, srate=sr)
    fg_0 = frame_gains(out[0], ein, fr, nf, trim)

    def sung(k):
        return lvl[k] > -36 and rat[k] < -8 and ein[k] > 1e-12

    def mean(v):
        return sum(v) / len(v)

    lifts = []           # long notes whose last 0.3 s fades more than 2 dB
    for e in range(100, nf - 15):
        if (sung(e - 1) and not any(sung(m) for m in range(e, e + 15))
                and sum(sung(m) for m in range(e - 100, e)) > 90):
            tf = [m for m in range(e - 30, e) if sung(m)]
            bf = [m for m in range(e - 100, e - 60) if sung(m)]
            if tf and bf and mean([lvl[m] for m in bf]) - mean([lvl[m] for m in tf]) > 2:
                lifts.append([mean([g[m] for m in tf]) - mean([g[m] for m in bf])
                              for g in (fg_100, fg_0)])
    d = sorted(fg_0[k] - fg_100[k] for k in range(nf) if sung(k))
    l100, l0 = mean([x[0] for x in lifts]), mean([x[1] for x in lifts])
    med = d[len(d) // 2]
    H.report("userfile_tail", len(lifts) > 10 and l100 > 0.3 and l0 < 0.15 and med > -0.2,
             "%d fading notes, end lift %+.2f dB at 100 %%, %+.2f at 0 %%; "
             "sung frames median %+.2f dB" % (len(lifts), l100, l0, med))


TAIL_KW = dict(win_v=300, speed=222, floor=-50, amount=58, target=-24.1,
               lookahead=200)


def t_tail():
    # a long note: 1.2 s steady, then a 9 dB fade over 1.5 s, a gap, a new note
    fade = voice(1.5, -27)
    n = len(fade)
    fade = [v * 10 ** (-9 * (k / n) / 20) for k, v in enumerate(fade)]
    inp = build([voice(1.2, -27), fade, [0.0] * int(0.8 * SR), voice(1.0, -27)])
    L = model.lookahead_samples(TAIL_KW["lookahead"], SR)
    lift, err = {}, 0.0
    for t in (100, 50, 0):
        kw = dict(TAIL_KW, tail_lift=t)
        out = render("tail_%d" % t, kw, inp)
        lift[t] = gain_at(out, inp, 2.6, win=0.05) - gain_at(out, inp, 1.0, win=0.1)
        ml, _, _ = model.run(inp, SR, **kw)
        err = max(err, maxdiff(out[0][:len(ml) - L], ml[L:]))
    # a loud note, a short dip, a steady note 5 dB quieter: not a fade
    inp = build([voice(1.5, -24), voice(0.12, -34), voice(2.0, -29)])
    q = [gain_at(render("tailq_%d" % t, dict(TAIL_KW, tail_lift=t), inp), inp, 3.4, win=0.1)
         for t in (100, 0)]
    # a steady tone lands on the same gain
    inp = segments([(4.0, -24)])
    c = gain_at(render("tail_canary", dict(tail_lift=0), inp), inp, 3.5)
    half = lift[50] / lift[100]
    ok = (lift[100] > 2 and lift[0] < 0.2 and 0.35 < half < 0.7
          and abs(q[1] - q[0]) < 0.2 and abs(c - 6.0) < 0.05 and err < TOL)
    H.report("tail", ok,
             "fade lift %+.2f / %+.2f / %+.2f dB at 100/50/0 %%; quieter note "
             "%+.2f vs %+.2f; steady %+.3f; model %.1e"
             % (lift[100], lift[50], lift[0], q[0], q[1], c, err))


def t_lookahead_null():
    inp = program()
    out = render("la_null", dict(amount=0, lookahead=200), inp)
    e = max(maxdiff(out[0], inp[0]), maxdiff(out[1], inp[1]))
    H.report("lookahead_null", e == 0.0,
             "200 ms, Amount 0: max |out - in| = %.2e" % e)


def t_lane_step():
    # constant -24 tone; Target automation steps -24 -> -18 at 2.0 s
    inp = segments([(4.0, -24)])
    env = parm_env(0, "Target level", [(0, -24), (2.0, -18)])
    cross = {}
    for la in (0, 200):
        out = render("lane_la%d" % la, dict(lookahead=la), inp, parmenv=env)
        t = 1.9
        while t < 3.5 and gain_at(out, inp, t, win=0.005) < 3.0:
            t += 0.001
        cross[la] = t
    shift = (cross[0] - cross[200]) * 1000
    H.report("lane_step", cross[0] < 3.5,
             "gain crosses +3 dB at %.3f s (no lookahead), %.3f s (200 ms): "
             "lane anticipated by %.0f ms" % (cross[0], cross[200], shift))


def t_srate():
    for sr in (44100, 96000):
        t_canary(sr, "canary_%dk" % (sr // 1000))


TESTS = [("params", t_params), ("model", t_model), ("canary", t_canary),
         ("amount", t_amount), ("limits", t_limits), ("hold", t_hold),
         ("release", t_release), ("weighting", t_weighting),
         ("breath", t_breath), ("sibilant", t_sibilant), ("tail", t_tail),
         ("lookahead_null", t_lookahead_null), ("lane_step", t_lane_step),
         ("srate", t_srate), ("userfile", t_userfile)]

if __name__ == "__main__":
    H.run(TESTS)
