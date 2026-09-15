#!/usr/bin/env python3
"""Headless render tests for "Magnolius_UpwardCompressor.jsfx".

    ./render_test.py                 # everything
    ./render_test.py unity canary    # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open. Work files land in ~/.cache/upcomp-rendertest (UPCOMP_WORK
overrides). UPCOMP_FX_NAME overrides the FX lookup name.

Prerequisite: "Magnolius_UpwardCompressor.jsfx" symlinked (never copied) somewhere
under <resource>/Effects/.
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
DUR = 3.0
N = 16384                 # measurement window: exact DFT bins, no leakage
W0 = 96000                # 2.0 s in -- past every ballistic settling time
W1 = W0 + N
TOL = 2e-5                # waveform agreement against model.py
DBTOL = 0.2               # dB agreement against the analytic static curve

H = Harness("upcomp",
            os.environ.get("UPCOMP_FX_NAME", "Magnolius_UpwardCompressor.jsfx"),
            work=os.environ.get("UPCOMP_WORK"))

# Order must match the header of "Magnolius_UpwardCompressor.jsfx".
NAMES = ["thresh_db", "ratio", "range_db", "knee_db", "atk_ms", "rel_ms",
         "gate_db", "sc_hz", "det_mode", "link_pct", "makeup_db", "mix_pct",
         "hist_s"]
LABELS = ["Threshold (dB)", "Ratio (1:N)", "Range / Max Lift (dB)",
          "Knee (dB)", "Attack - lift in (ms)", "Release - lift out (ms)",
          "Noise Floor (dB)", "Sidechain HPF (Hz)", "Detector",
          "Stereo Link (%)", "Makeup (dB)", "Mix (%)", "Display History (s)"]

MAKEUP_2X = 20 * math.log10(2.0)      # +6.0206 dB -- exactly a factor of two


def S(**kw):
    bad = set(kw) - set(NAMES)
    if bad:
        raise KeyError("unknown slider(s): %s" % sorted(bad))
    v = dict(model.DEFAULTS, **kw)
    return slider_line([v[n] for n in NAMES])


# ---------------------------------------------------------------------------
# signal generation (stdlib only -- no numpy on this box)
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


def tone(n, f, amp, srate=SR):
    return f32([amp * math.sin(2 * math.pi * f * k / srate) for k in range(n)])


def tone_at(n, level_db, f=None, srate=SR):
    """A sine whose RMS -- i.e. what the RMS detector reads -- is level_db."""
    f = f or bin_freq(997.0, srate, N)
    return tone(n, f, math.sqrt(2.0) * 10 ** (level_db / 20.0), srate), f


def program(n, seed=3, srate=SR):
    """Loud/quiet alternating material, so the ballistics actually travel.

    0.4-second blocks stepping -6, -46, -20, -60, -12 dBFS, each a tone plus
    a little noise so neither detector mode ever sees a pure sine, then a
    silent tail so the release side and the gate are exercised too.
    """
    r = LCG(seed)
    steps = [-6.0, -46.0, -20.0, -60.0, -12.0]
    blk = int(0.4 * srate)
    left, right = [], []
    for k in range(n):
        lvl = steps[min(k // blk, len(steps) - 1)]
        a = 10 ** (lvl / 20.0)
        if k > int(2.2 * srate):
            a *= 0.0                       # silent tail: release + gate
        t = 2 * math.pi * k / srate
        left.append(a * (0.8 * math.sin(t * 220.0) + 0.2 * r.uni()))
        right.append(a * (0.8 * math.sin(t * 330.0 + 0.7) + 0.2 * r.uni()))
    return [f32(left), f32(right)]


def gain_db(out_ch, in_ch, f, srate=SR):
    """Output/input level of the tone at f, measured over the settled window."""
    return db(dft_mag(out_ch[W0:W1], f, srate)) - \
        db(dft_mag(in_ch[W0:W1], f, srate))


def cmp_model(name, sliders_kw, chans, srate=SR, tol=TOL, lo=0, hi=None):
    H.write_input(name + "_in.wav", chans, srate)
    out, _ = H.render(name, S(**sliders_kw), input_name=name + "_in.wav",
                      length=len(chans[0]) / srate,
                      in_len=len(chans[0]) / srate, srate=srate)
    ref, _ = model.run(chans, srate, **sliders_kw)
    hi = hi if hi is not None else len(chans[0])
    d = max(maxdiff(out[0], ref[0], lo, hi), maxdiff(out[1], ref[1], lo, hi))
    return d < tol, "maxdiff %.2e (tol %g)" % (d, tol), out, ref


# ------------------------------------------------------------------- tests --

def t_params():
    """Every slider must survive the header parse.

    A JSFX header error has no error UI: the offending slider and usually
    every slider after it silently vanish and the plugin still loads. This is
    the only reliable detector -- and the one thing that would catch the ':'
    in the "Ratio (1:N)" label turning into a parse hazard.
    """
    names, _ = H.probe_params()
    got = [names.get(i, "<missing>") for i in range(len(LABELS))]
    bad = [(i, LABELS[i], got[i]) for i in range(len(LABELS))
           if got[i] != LABELS[i]]
    H.report("params", not bad,
             "13/13 sliders parsed" if not bad else
             "mismatched: %s" % "; ".join("%d want %r got %r" % b for b in bad))


def t_unity():
    """Ratio 1:1 is exact passthrough -- proves zero latency and no colour.

    Bit-identical output is a much stronger claim than "close": it says the
    reported PDC (zero) equals the actual latency and that nothing in the
    signal path touches the sample when the lift is disengaged.
    """
    x = program(int(DUR * SR))
    H.write_input("unity_in.wav", x)
    out, _ = H.render("unity", S(ratio=1.0), input_name="unity_in.wav",
                      length=DUR, in_len=DUR)
    d = max(maxdiff(out[0], x[0], 0, len(x[0])),
            maxdiff(out[1], x[1], 0, len(x[1])))
    H.report("unity", d < 1e-9, "maxdiff %.2e" % d)


def t_canary():
    """+6.0206 dB makeup must give EXACTLY 2x.

    The suite's canary. Every passthrough-shaped assertion above passes
    vacuously if @init dies and the plugin degrades to passthrough; this one
    cannot. It also pins makeup to the wet path only.
    """
    x = program(int(DUR * SR))
    H.write_input("canary_in.wav", x)
    out, _ = H.render("canary", S(ratio=1.0, makeup_db=MAKEUP_2X),
                      input_name="canary_in.wav", length=DUR, in_len=DUR)
    want = [[2.0 * v for v in x[0]], [2.0 * v for v in x[1]]]
    d = max(maxdiff(out[0], want[0], 0, len(x[0])),
            maxdiff(out[1], want[1], 0, len(x[1])))
    moved = maxdiff(out[0], x[0], 0, len(x[0]))
    H.report("canary", d < 1e-7 and moved > 0.01,
             "2x maxdiff %.2e, moved %.3f from input" % (d, moved))


def t_mix_bypass():
    """Mix 0% is an exact bypass however Makeup and Range are set.

    Regression guard for the original topology, (dry*in + wet*in*g)*makeup,
    which multiplied the dry path too and turned Mix 0% into a gain stage.
    """
    x = program(int(DUR * SR))
    H.write_input("mixby_in.wav", x)
    out, _ = H.render("mixby",
                      S(mix_pct=0, makeup_db=12.0, range_db=24.0, ratio=8.0),
                      input_name="mixby_in.wav", length=DUR, in_len=DUR)
    d = max(maxdiff(out[0], x[0], 0, len(x[0])),
            maxdiff(out[1], x[1], 0, len(x[1])))
    H.report("mix_bypass", d < 1e-9, "maxdiff %.2e" % d)


def t_model():
    """Sample-for-sample agreement with tools/model.py on real material.

    If this fails after a DSP edit, the model and the .jsfx have drifted
    apart. Fix whichever one is wrong -- do not raise the tolerance.
    """
    x = program(int(DUR * SR))
    kw = dict(thresh_db=-28.0, ratio=3.0, range_db=15.0, knee_db=8.0,
              atk_ms=12.0, rel_ms=150.0, makeup_db=2.0, mix_pct=80.0,
              link_pct=60.0, det_mode=1)
    ok, detail, _, _ = cmp_model("model", kw, x)
    H.report("model", ok, detail)


def t_model_peak():
    """Same, with the Peak detector -- the other branch of @sample."""
    x = program(int(DUR * SR), seed=11)
    kw = dict(det_mode=0, thresh_db=-32.0, ratio=4.0, range_db=18.0,
              atk_ms=5.0, rel_ms=400.0, link_pct=0.0, sc_hz=120.0)
    ok, detail, _, _ = cmp_model("model_peak", kw, x)
    H.report("model_peak", ok, detail)


def t_static_curve():
    """Settled lift on a steady tone must land on the analytic static curve.

    Checked against model.settled_lift_db(), which is closed form and shares
    no code with the sample loop -- so this asserts the ballistics converge
    to the curve, not merely that two implementations agree.
    """
    lines, worst, ok = [], 0.0, True
    for lvl in (-10.0, -25.0, -35.0, -50.0, -60.0, -66.0):
        x, f = tone_at(int(DUR * SR), lvl)
        nm = "curve%d" % abs(int(lvl))
        H.write_input(nm + "_in.wav", [x, x])
        out, _ = H.render(nm, S(), input_name=nm + "_in.wav",
                          length=DUR, in_len=DUR)
        got = gain_db(out[0], x, f)
        want = model.settled_lift_db(lvl)
        e = abs(got - want)
        worst = max(worst, e)
        ok = ok and e < DBTOL
        lines.append("    %+6.1f dBFS in -> lift %+6.2f dB (want %+6.2f)"
                     % (lvl, got, want))
    H.report("static_curve", ok, "worst error %.3f dB (tol %g)\n%s"
             % (worst, DBTOL, "\n".join(lines)))


def t_range_clamp():
    """Range is a hard ceiling on the lift, whatever the ratio asks for."""
    lvl = -60.0
    x, f = tone_at(int(DUR * SR), lvl)
    H.write_input("range_in.wav", [x, x])
    lines, ok = [], True
    for rng in (3.0, 6.0, 12.0):
        out, _ = H.render("range%d" % int(rng),
                          S(ratio=20.0, range_db=rng, gate_db=-100.0),
                          input_name="range_in.wav", length=DUR, in_len=DUR)
        got = gain_db(out[0], x, f)
        ok = ok and abs(got - rng) < DBTOL
        lines.append("    Range %4.1f dB -> lift %+6.2f dB" % (rng, got))
    H.report("range_clamp", ok,
             "ratio 1:20 at %.0f dBFS asks for %.1f dB of lift\n%s"
             % (lvl, (1 - 1 / 20.0) * (abs(lvl) - 30), "\n".join(lines)))


def t_gate():
    """Below the noise floor the lift fades out, so hiss stays put."""
    lines, ok = [], True
    for lvl in (-80.0, -73.0, -64.0):
        x, f = tone_at(int(DUR * SR), lvl)
        nm = "gate%d" % abs(int(lvl))
        H.write_input(nm + "_in.wav", [x, x])
        out, _ = H.render(nm, S(range_db=40.0), input_name=nm + "_in.wav",
                          length=DUR, in_len=DUR)
        got = gain_db(out[0], x, f)
        exp = model.settled_lift_db(lvl, range_db=40.0)
        ok = ok and abs(got - exp) < DBTOL
        lines.append("    %+6.1f dBFS -> lift %+6.2f dB (want %+6.2f)"
                     % (lvl, got, exp))
    H.report("gate", ok, "noise floor -70 dB, 6 dB taper\n%s"
             % "\n".join(lines))


def t_link():
    """Stereo Link pulls both channels onto the louder one's detector.

    Left loud, right quiet: at 100% the right channel must inherit the left's
    (near zero) lift; at 0% it gets its own large one.
    """
    n = int(DUR * SR)
    f = bin_freq(997.0, SR, N)
    loud = tone(n, f, math.sqrt(2.0) * 10 ** (-10.0 / 20.0))
    quiet = tone(n, f, math.sqrt(2.0) * 10 ** (-55.0 / 20.0))
    H.write_input("link_in.wav", [loud, quiet])
    res = {}
    for pct in (0, 100):
        out, _ = H.render("link%d" % pct, S(link_pct=pct, range_db=40.0),
                          input_name="link_in.wav", length=DUR, in_len=DUR)
        res[pct] = (gain_db(out[0], loud, f), gain_db(out[1], quiet, f))
    want_unlinked = model.settled_lift_db(-55.0, range_db=40.0)
    ok = (abs(res[0][1] - want_unlinked) < DBTOL
          and res[100][1] < 0.5
          and abs(res[0][0]) < DBTOL and abs(res[100][0]) < DBTOL)
    H.report("link", ok,
             "link 0%%: L %+5.2f R %+5.2f (R wants %+5.2f) | "
             "link 100%%: L %+5.2f R %+5.2f (R wants ~0)"
             % (res[0][0], res[0][1], want_unlinked,
                res[100][0], res[100][1]))


def t_rates():
    """Every coefficient is rebuilt from srate, at every rate REAPER offers.

    recalc() lives in @init and is called again from @slider precisely so a
    samplerate change cannot leave a stale attack coefficient behind; this is
    what proves it.
    """
    kw = dict(thresh_db=-30.0, ratio=3.0, range_db=12.0, atk_ms=15.0,
              rel_ms=180.0, makeup_db=1.5, mix_pct=90.0)
    lines, ok = [], True
    for sr in (44100, 48000, 96000):
        x = program(int(2.0 * sr), srate=sr)
        good, detail, out, _ = cmp_model("rate%d" % sr, kw, x, srate=sr)
        peak = max(max(abs(v) for v in out[0]), max(abs(v) for v in out[1]))
        finite = peak < 4.0
        ok = ok and good and finite
        lines.append("    %6d Hz  %s  peak %.3f" % (sr, detail, peak))
    H.report("rates", ok, "\n".join(lines))


TESTS = [("params", t_params),
         ("unity", t_unity),
         ("canary", t_canary),
         ("mix_bypass", t_mix_bypass),
         ("model", t_model),
         ("model_peak", t_model_peak),
         ("static_curve", t_static_curve),
         ("range_clamp", t_range_clamp),
         ("gate", t_gate),
         ("link", t_link),
         ("rates", t_rates)]

if __name__ == "__main__":
    H.run(TESTS)
