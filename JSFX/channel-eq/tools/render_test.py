#!/usr/bin/env python3
"""Headless render tests for "Magnolius_ChannelEQ.jsfx".

    ./render_test.py                 # everything
    ./render_test.py neutral model   # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open.  Work files land in ~/.cache/chnl-eq-rendertest (CHEQ_WORK
overrides).  CHEQ_FX_NAME overrides the FX lookup name.

Prerequisite: "Magnolius_ChannelEQ.jsfx" symlinked (never copied) somewhere
under <resource>/Effects/.

What these show: the plugin does what tools/model.py says (sample for sample),
that model's response matches its analog prototype to the accuracy the design
promises, a neutral EQ is bit-identical passthrough, the chain is a pure linear
filter (nothing but the fundamental comes out, so nothing aliases), and
parameter changes glide without a step.  There is no reference unit, so the
analog prototypes themselves are checked in model_test.py against the formulas
they come from, not against hardware.
"""
import array
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model                                                        # noqa: E402
from render_harness import (Harness, bin_freq, db, dft_mag,         # noqa: E402
                            dft_mag_hann, maxdiff, parm_env, slider_line)

SR = 48000
TOL = 2e-5                  # waveform agreement against model.py
N_WIN = 16384               # analysis window, samples

H = Harness("chnl-eq",
            os.environ.get("CHEQ_FX_NAME", "Magnolius_ChannelEQ.jsfx"),
            work=os.environ.get("CHEQ_WORK"))

# Order must match the header of "Magnolius_ChannelEQ.jsfx" (REAPER drops the leading '-').
LABELS = ["EQ In", "Filters In", "High-pass", "Low-pass", "LF Gain", "LF Freq",
          "LMF Gain", "LMF Freq", "LMF Q", "LMF Div", "HMF Gain", "HMF Freq",
          "HMF Q", "HMF Mult", "HF Gain", "HF Freq", "Gain Law",
          "Saturation Amount", "Saturation Type"]


def P(**kw):
    bad = set(kw) - set(model.NAMES)
    if bad:
        raise KeyError("unknown slider(s): %s" % sorted(bad))
    return dict(model.DEFAULTS, **kw)


def S(p):
    return slider_line([p[n] for n in model.NAMES])


def f32(x):
    return list(array.array("f", x))


class LCG:
    def __init__(self, seed=12345):
        self.s = seed

    def uni(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s / 0x3FFFFFFF - 1.0


def program(n, seed=3):
    """Stereo programme: a few tones and noise, different in each channel."""
    r = LCG(seed)
    left, right = [], []
    for k in range(n):
        t = 2 * math.pi * k / SR
        left.append(0.18 * math.sin(t * 220.0) + 0.1 * math.sin(t * 3100.0) + 0.12 * r.uni())
        right.append(0.15 * math.sin(t * 330.0 + 0.7) + 0.08 * math.sin(t * 9000.0) + 0.12 * r.uni())
    return [f32(left), f32(right)]


def render(name, p, chans, srate=SR, parmenv=None):
    H.write_input(name + "_in.wav", chans, srate)
    out, _ = H.render(name, S(p), input_name=name + "_in.wav",
                      length=len(chans[0]) / srate, in_len=len(chans[0]) / srate,
                      srate=srate, parmenv=parmenv)
    return out


def multisine(freqs, amp, n, srate, phase0=0.3):
    return f32([sum(amp * math.sin(2 * math.pi * f * k / srate + phase0 * (i + 1) ** 2)
                    for i, f in enumerate(freqs)) for k in range(n)])


def sections_mag(p, fs, f):
    m = 1.0
    for c in model.targets(p, fs):
        m *= model.digital_mag(c, fs, f)
    return m


# ---------------------------------------------------------------------------
def t_params():
    names, lines = H.probe_params()
    missing = [i for i, n in enumerate(LABELS) if names.get(i) != n]
    H.report("params", not missing,
             "all %d sliders parsed in order" % len(LABELS) if not missing
             else "slider(s) wrong or missing at %s: %s" % (missing, [names.get(i) for i in missing]))


def t_neutral():
    ch = program(SR)
    out = render("neutral", P(), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("neutral", d == 0.0, "defaults: bit-identical passthrough (max diff %.3g)" % d)
    # bypass switches and the dummy saturation controls
    p = P(hf_g=1, lmf_g=0.6, hmf_g=-0.5, lf_g=0.4, hpf=0.5, lpf=0.3, eq_in=0, flt_in=0)
    out = render("bypass", p, ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("bypass", d == 0.0, "EQ In and Filters In off: bit-identical (max diff %.3g)" % d)
    out = render("satdummy", P(sat_amt=1.0, sat_mode=1), ch)
    d = max(maxdiff(out[0], ch[0]), maxdiff(out[1], ch[1]))
    H.report("satdummy", d == 0.0, "saturation controls do nothing yet (max diff %.3g)" % d)


def t_canary():
    # A boosted band must hit its table gain at its centre.  Passthrough cannot fake this.
    p = P(hmf_g=1.0, hmf_f=0.5, hmf_q=0.0)
    proto = [x for n, _, x in model.analog_sections(p, SR) if n == "hmf"][0]
    f0 = bin_freq(math.sqrt(proto[5]) / (2 * math.pi), SR, N_WIN)
    n = SR + N_WIN
    out = render("canary", p, [multisine([f0], 0.04, n, SR, 0.0)] * 2)
    got = db(dft_mag(out[0][SR:SR + N_WIN], f0, SR) / 0.04)   # REAPER adds a silent tail: never read the end
    want = db(sections_mag(p, SR, f0))
    H.report("canary", abs(got - 21.0) < 0.1 and abs(got - want) < 0.01,
             "HMF full boost at %.0f Hz: %.2f dB (table 21.0, model %.2f)" % (f0, got, want))


def t_model():
    ch = program(SR // 2)
    presets = {
        "hf shelf + lf": P(hf_g=0.8, hf_f=0.7, lf_g=-0.6, lf_f=0.3),
        "mids x3 / div": P(lmf_g=0.9, lmf_f=0.4, lmf_q=0.8, lmf_d3=1, hmf_g=-0.7, hmf_f=0.6, hmf_q=0.3, hmf_x3=1),
        "filters": P(hpf=0.55, lpf=0.4, hf_g=0.3),
        "everything": P(hpf=0.3, lpf=0.8, lf_g=0.7, lf_f=0.2, lmf_g=-0.5, lmf_f=0.5, lmf_q=0.5,
                        hmf_g=0.6, hmf_f=0.8, hmf_q=0.9, hf_g=-0.9, hf_f=0.4, gain_law=1),
    }
    worst = 0.0
    for name, p in presets.items():
        out = render("model", p, ch)
        ref = model.Engine(p, SR).process(ch)
        d = max(maxdiff(out[0], ref[0]), maxdiff(out[1], ref[1]))
        worst = max(worst, d)
        print("    %-14s max diff %.3g" % (name, d))
    H.report("model", worst < TOL, "render equals model.py sample for sample (worst %.3g, tol %.0e)" % (worst, TOL))


def t_magnitude(srate=SR, tag="magnitude", lim15=0.12):
    freqs = [bin_freq(f, srate, N_WIN) for f in (40, 80, 160, 320, 640, 1100, 2000, 3400, 5500, 8000, 11000, 14000)]
    freqs = [f for f in freqs if f < 0.45 * srate]
    p = P(hpf=0.35, lpf=0.85, lf_g=0.7, lf_f=0.3, lmf_g=0.8, lmf_f=0.5, lmf_q=0.6,
          hmf_g=-0.6, hmf_f=0.55, hmf_q=0.4, hf_g=0.9, hf_f=0.5)
    n = srate + N_WIN
    sig = multisine(freqs, 0.018, n, srate)
    out = render(tag, p, [sig, sig], srate=srate)
    win = out[0][srate:srate + N_WIN]
    dmax = amax = 0.0
    for f in freqs:
        got = db(dft_mag_hann(win, f, srate) / 0.018)
        dig = db(model.digital_total(p, srate, f))
        ana = db(model.analog_total(p, srate, f))
        dmax = max(dmax, abs(got - dig))
        if f <= 15000:
            amax = max(amax, abs(got - ana))
    H.report(tag, dmax < 0.02 and amax < lim15,
             "%g kHz: render vs model %.3f dB, vs analog prototype %.3f dB (to 15 kHz, limit %.2f)"
             % (srate / 1000, dmax, amax, lim15))


def t_pure():
    # A loud tone near Nyquist through full boost: only the fundamental may come out.
    fs = 44100
    f = bin_freq(15000, fs, N_WIN)
    p = P(hf_g=1.0, hf_f=0.9, hmf_g=1.0, hmf_f=0.9, hmf_x3=1, hmf_q=1.0, lmf_g=-1.0, lmf_f=1.0)
    n = fs + N_WIN
    sig = multisine([f], 0.03, n, fs, 0.0)
    out = render("pure", p, [sig, sig], srate=fs)
    x = out[0][fs:fs + N_WIN]
    a = 2 / N_WIN * sum(v * math.cos(2 * math.pi * f * k / fs) for k, v in enumerate(x))
    b = 2 / N_WIN * sum(v * math.sin(2 * math.pi * f * k / fs) for k, v in enumerate(x))
    res = [v - (a * math.cos(2 * math.pi * f * k / fs) + b * math.sin(2 * math.pi * f * k / fs)) for k, v in enumerate(x)]
    amp = math.hypot(a, b)
    rel = math.sqrt(sum(v * v for v in res) / N_WIN) / (amp / math.sqrt(2))
    H.report("pure", rel < 1e-6 and amp > 0.1,
             "15 kHz at 44.1 kHz through the full boost: %.1f dB gain, everything else %.0f dB down"
             % (db(amp / 0.03), db(rel)))


def t_glide():
    # a gain step on a sine at the band centre must glide, with no step or overshoot
    p0 = P(hmf_g=0.0, hmf_f=0.5, hmf_q=0.2)
    p1 = P(hmf_g=0.8, hmf_f=0.5, hmf_q=0.2)
    proto = [x for n, _, x in model.analog_sections(p1, SR) if n == "hmf"][0]
    f0 = bin_freq(math.sqrt(proto[5]) / (2 * math.pi), SR, N_WIN)
    n = 3 * SR
    amp = 0.05
    sig = multisine([f0], amp, n, SR, 0.0)
    t_step = 1.0
    env = parm_env(10, "HMF Gain", [(0.0, 0.0), (t_step, 0.8)])
    out = render("glide", p0, [sig, sig], parmenv=env)
    y = out[0]
    per = max(1, int(round(SR / f0)))

    def envelope(i):
        seg = y[i:i + per]
        return math.sqrt(2 * sum(v * v for v in seg) / len(seg))
    pre = envelope(int(0.5 * SR))
    gfin = sections_mag(p1, SR, f0)
    fin = envelope(int(2.8 * SR))
    ks = range(int(t_step * SR), int(2.2 * SR), 16)
    es = [envelope(k) for k in ks]
    pk = max(es)
    t10 = next(k for k, e in zip(ks, es) if e > pre + 0.1 * (fin - pre))
    t90 = next(k for k, e in zip(ks, es) if e > pre + 0.9 * (fin - pre))
    rise = (t90 - t10) / SR * 1000
    slope = max(abs(y[k + 1] - y[k]) for k in range(int(0.9 * SR), int(2.5 * SR)))
    slope_ok = slope <= amp * gfin * 2 * math.pi * f0 / SR * 1.15
    ok = (abs(db(pre / amp)) < 0.01 and abs(db(fin / (amp * gfin))) < 0.1
          and db(pk / fin) < 0.1 and 3 < rise < 60 and slope_ok)
    H.report("glide", ok,
             "step to %+.1f dB at %.0f Hz: 10-90%% rise %.1f ms, overshoot %.2f dB, steepest slope %.2f of the bound"
             % (db(gfin), f0, rise, db(pk / fin), slope / (amp * gfin * 2 * math.pi * f0 / SR)))
    # switching the EQ off must end in exact passthrough again
    ch = program(2 * SR)
    p = P(hf_g=1, lmf_g=0.6, hmf_g=-0.5, lf_g=0.4, hpf=0.5, lpf=0.3)
    env = parm_env(0, "EQ In", [(0.0, 1.0), (0.5, 0.0)]) + "\n" + parm_env(1, "Filters In", [(0.0, 1.0), (0.5, 0.0)])
    out = render("offglide", p, ch, parmenv=env)
    lo = int(1.4 * SR)
    d = max(maxdiff(out[0], ch[0], lo), maxdiff(out[1], ch[1], lo))
    H.report("offglide", d == 0.0,
             "after EQ In and Filters In go off the output settles to exact passthrough (max diff %.3g)" % d)


def t_rates():
    for srate, lim in ((44100, 0.12), (96000, 0.03), (192000, 0.03)):
        ch = [multisine([1000.0], 0.2, srate // 2, srate)] * 2
        out = render("rate_neutral", P(), ch, srate=srate)
        d = maxdiff(out[0], ch[0])
        H.report("neutral@%gk" % (srate / 1000), d == 0.0, "bit-identical at %d Hz" % srate)
        t_magnitude(srate, "magnitude@%gk" % (srate / 1000), lim)


TESTS = [("params", t_params), ("neutral", t_neutral), ("canary", t_canary), ("model", t_model),
         ("magnitude", t_magnitude), ("pure", t_pure), ("glide", t_glide), ("rates", t_rates)]

if __name__ == "__main__":
    H.run(TESTS)
