#!/usr/bin/env python3
"""Headless render-test harness for "Magnolius_LoudnessSimulator.jsfx".

Renders tiny REAPER projects through the plugin with
`reaper -newinst -nosplash -renderproject` (works while a normal REAPER
instance is running) and compares the result against model.py, a pure-Python
reference implementation of the same DSP.

Prerequisites:
  - "Magnolius_LoudnessSimulator.jsfx" symlinked into <resource>/Effects/ (any subfolder)

Usage:
  render_test.py                    # run all tests
  render_test.py canary comp_static # run selected tests
Work dir: ~/.cache/loudsim-rendertest (override with LOUDSIM_TEST_DIR).
FX name override: LOUDSIM_FX_NAME (default "Magnolius_LoudnessSimulator.jsfx").
"""
import base64
import math
import os
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav, write_wav_f32
import model

WORK = os.environ.get("LOUDSIM_TEST_DIR",
                      os.path.expanduser("~/.cache/loudsim-rendertest"))
FX_NAME = os.environ.get("LOUDSIM_FX_NAME", "Magnolius_LoudnessSimulator.jsfx")
SR = 48000
DUR = 3.0
N = 16384              # analysis window (exact DFT bins, no leakage)
REG0 = 96000           # 2.0 s in: past every ballistic settling time
REG1 = REG0 + N
TOL = 2e-5             # waveform agreement vs the Python model

RENDER_CFG = base64.b64encode(b"evaw" + struct.pack("<i", 32)).decode()


# --------------------------------------------------------------- signals ----
def bin_freq(target, sr=SR, n=N):
    """Nearest frequency that lands exactly on a DFT bin of the window."""
    return round(target * n / sr) * sr / n


PROBE_F = [bin_freq(f) for f in (60, 150, 1000, 4000, 10000)]


def multitone(rms_db, dur=DUR, sr=SR, phase=0.0):
    n = int(sr * dur)
    out = [0.0] * n
    for k, f in enumerate(PROBE_F):
        ph = phase + k * 0.7
        w = 2 * math.pi * f / sr
        for i in range(n):
            out[i] += math.sin(w * i + ph)
    cur = math.sqrt(sum(v * v for v in out) / n)
    g = 10.0 ** (rms_db / 20.0) / cur
    return [v * g for v in out]


def step_signal(lo_db, hi_db, at=1.5, dur=DUR, sr=SR):
    a = multitone(lo_db, dur, sr)
    b = multitone(hi_db, dur, sr, phase=0.0)
    k = int(at * sr)
    return a[:k] + b[k:]


def gate_signal(hi_db, at=1.0, dur=DUR, sr=SR):
    """Digital silence, then a hard step to hi_db - worst case for zipper."""
    b = multitone(hi_db, dur, sr)
    k = int(at * sr)
    return [0.0] * k + b[k:]


# ----------------------------------------------------------- rpp / render ----
# Single source of truth for a settings set. slider_line() and run_model() both
# derive from this, so the REAPER render and the Python model can never end up
# running different settings (they silently did once - crossfeed on/off).
DEFAULTS = dict(loudness=0.0, makeup=0.0, xf_hz=700.0, xf_db=0.0,
                thresh=-24.0, ratio=2.0, rng=8.0, knee=6.0)

# slider order in the .jsfx header
SLIDER_ORDER = ("loudness", "makeup", "xf_hz", "xf_db",
                "thresh", "ratio", "rng", "knee")


def params(**kw):
    bad = set(kw) - set(DEFAULTS)
    if bad:
        raise KeyError("unknown setting(s): %s" % sorted(bad))
    p = dict(DEFAULTS)
    p.update(kw)
    return p


def slider_line(p):
    vals = ["%.6f" % p[k] for k in SLIDER_ORDER]
    vals += ["-"] * (64 - len(vals))
    return " ".join(vals)


def make_rpp(path, sliders, out_wav, input_wav, length, srate):
    rpp = """<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000
  SAMPLERATE %d 0 0
  TEMPO 120 4 4
  RENDER_FILE "%s"
  RENDER_PATTERN ""
  RENDER_FMT 0 2 %d
  RENDER_1X 0
  RENDER_RANGE 1 0 %s 0 0
  RENDER_RESAMPLE 3 0 1
  RENDER_ADDTOPROJ 0
  RENDER_STEMS 0
  RENDER_DITHER 0
  <RENDER_CFG
    %s
  >
  <TRACK
    NAME "test"
    <FXCHAIN
      SHOW 0
      LASTSEL 0
      DOCKED 0
      BYPASS 0 0 0
      <JS "%s" ""
        %s
      >
    >
    <ITEM
      POSITION 0
      LENGTH %s
      LOOP 0
      NAME input
      <SOURCE WAVE
        FILE "%s"
      >
    >
  >
>
""" % (srate, out_wav, srate, length, RENDER_CFG, FX_NAME, sliders,
       length, input_wav)
    with open(path, "w") as f:
        f.write(rpp)


def render(name, sliders, chans_in, srate=SR, dur=DUR):
    in_wav = os.path.join(WORK, name + "_in.wav")
    out_wav = os.path.join(WORK, name + ".wav")
    rpp = os.path.join(WORK, name + ".rpp")
    write_wav_f32(in_wav, srate, chans_in)
    if os.path.exists(out_wav):
        os.remove(out_wav)
    make_rpp(rpp, sliders, out_wav, in_wav, dur, srate)
    t0 = time.time()
    subprocess.run(["reaper", "-newinst", "-nosplash", "-renderproject", rpp],
                   check=True, timeout=300,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(out_wav):
        raise RuntimeError("render produced no output: " + out_wav)
    _, chans = read_wav(out_wav)
    return chans, time.time() - t0


# -------------------------------------------------------------- analysis ----
def maxdiff(a, b, lo=0, hi=None):
    hi = len(a) if hi is None else hi
    return max(abs(x - y) for x, y in zip(a[lo:hi], b[lo:hi]))


def rms(x, lo=0, hi=None):
    seg = x[lo:hi]
    return math.sqrt(sum(v * v for v in seg) / max(len(seg), 1))


def dft_db(x, f, sr=SR):
    re = im = 0.0
    for n, v in enumerate(x):
        w = 2 * math.pi * f * n / sr
        re += v * math.cos(w)
        im -= v * math.sin(w)
    return 20 * math.log10(max(math.sqrt(re * re + im * im), 1e-30))


def band_gains(out, inp, srate=SR):
    """Per-probe-tone gain in dB, measured on the settled window."""
    o = out[REG0:REG1]
    i = inp[REG0:REG1]
    return [dft_db(o, f, srate) - dft_db(i, f, srate) for f in PROBE_F]


def run_model(chans_in, p, srate=SR):
    m = model.LoudnessSim(sr=float(srate),
                          loudness=p["loudness"], makeup_db=p["makeup"],
                          xf_hz=p["xf_hz"], xf_db=p["xf_db"],
                          thresh_db=p["thresh"], ratio=p["ratio"],
                          range_db=p["rng"], knee_db=p["knee"])
    l, r = m.process(chans_in[0], chans_in[1])
    return [l, r], m


def compare(out, ref, tol=TOL, lo=0, hi=None):
    dl = maxdiff(out[0], ref[0], lo, hi)
    dr = maxdiff(out[1], ref[1], lo, hi)
    ok = dl < tol and dr < tol
    return ok, "maxdiff L=%.2e R=%.2e (tol %g)" % (dl, dr, tol)


RESULTS = []


def report(name, ok, detail):
    RESULTS.append((name, ok))
    print("%-16s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


# ----------------------------------------------------------------- tests ----
def t_canary():
    """+6 dB makeup, everything else neutral -> output must be exactly 2x.

    Passthrough cannot fake this, so it proves every JSFX section compiled.
    A dead @init degrades the plugin to passthrough and this is the only test
    that would notice.
    """
    p = params(makeup=6.0)
    sig = multitone(-20.0)
    out, _ = render("canary", slider_line(p), [sig, sig])
    g = 10.0 ** (6.0 / 20.0)
    ref = [[v * g for v in sig]] * 2
    ok, det = compare(out, ref, tol=1e-5)
    if not ok:
        det += ("\n                 hint: if the gain is 1.0 REAPER never found "
                'the FX; try LOUDSIM_FX_NAME="Magnolius/Magnolius_LoudnessSimulator.jsfx"')
    report("canary", ok, det)


def t_identity():
    """All controls neutral -> bit-transparent."""
    p = params()
    sigl, sigr = multitone(-20.0), multitone(-20.0, phase=1.1)
    out, _ = render("identity", slider_line(p), [sigl, sigr])
    ok, det = compare(out, [sigl, sigr], tol=1e-6)
    report("identity", ok, det)


def t_contour():
    """slider1=100 at a level well above threshold -> static contour only.

    Topology-independent: with zero lift both the old parallel-add build and
    the cascaded-shelf build must produce this same curve.
    """
    p = params(loudness=100.0)
    sigl, sigr = multitone(-8.0), multitone(-8.0, phase=1.1)
    out, _ = render("contour", slider_line(p), [sigl, sigr])
    _, m = run_model([sigl, sigr], p)
    got = band_gains(out[0], sigl)
    want = [model.static_contour_db(100.0, f) for f in PROBE_F]
    dev = max(abs(a - b) for a, b in zip(got, want))
    ok = dev < 0.05 and m.g_ldb < 0.02 and m.g_hdb < 0.02
    report("contour", ok,
           "worst dev %.3f dB (tol 0.05), lift L/H %.2f/%.2f dB, per-tone %s"
           % (dev, m.g_ldb, m.g_hdb,
              " ".join("%.0fHz %+.2f" % (f, g) for f, g in zip(PROBE_F, got))))


def t_comp_static():
    """The test that catches the reported bug.

    A level ladder through the compressor. The rendered waveform must match the
    reference implementation, and the measured 60 Hz / 10 kHz gain must sit
    above the static contour by the modelled lift. Before the fix the plugin
    reported +0.00 dB of lift at every level a real mix lives at.
    """
    worst = 0.0
    lines = []
    ok = True
    for lvl in (-12.0, -24.0, -36.0, -48.0):
        p = params(loudness=100.0)
        sigl, sigr = multitone(lvl), multitone(lvl, phase=1.1)
        ch = [sigl, sigr]
        out, _ = render("comp%d" % abs(lvl), slider_line(p), ch)
        ref, m = run_model(ch, p)
        d = max(maxdiff(out[0], ref[0], REG0, REG1),
                maxdiff(out[1], ref[1], REG0, REG1))
        worst = max(worst, d)
        got = band_gains(out[0], sigl)
        base = [model.static_contour_db(100.0, f) for f in PROBE_F]
        ok = ok and d < TOL
        lines.append("    %+5.0f dBFS: lift 60Hz %+5.2f dB (model %+5.2f)  "
                     "10kHz %+5.2f dB (model %+5.2f)  maxdiff %.2e"
                     % (lvl, got[0] - base[0], m.g_ldb,
                        got[4] - base[4], m.g_hdb, d))
    report("comp_static", ok,
           "worst maxdiff %.2e (tol %g)\n%s" % (worst, TOL, "\n".join(lines)))


def t_comp_mid():
    """Midrange must not move when the lift engages.

    The old parallel-add topology cut 400 Hz - 3 kHz by ~1.5 dB whenever gL/gH
    left unity; a cascaded shelf pair does not.
    """
    p = params(loudness=100.0)
    sigl, sigr = multitone(-45.0), multitone(-45.0, phase=1.1)
    out, _ = render("comp_mid", slider_line(p), [sigl, sigr])
    _, m = run_model([sigl, sigr], p)
    got = band_gains(out[0], sigl)
    base = [model.static_contour_db(100.0, f) for f in PROBE_F]
    # Both halves matter: measuring the midrange while the lift sits at 0 dB
    # would pass vacuously, so require the RENDERED lift to be engaged too.
    lift = got[0] - base[0]
    ok = abs(got[2] - base[2]) < 0.3 and lift > 1.0
    report("comp_mid", ok,
           "1 kHz moved %+.2f dB (tol 0.30) while rendered low lift = %.2f dB "
           "(model %.2f, must be > 1.0)" % (got[2] - base[2], lift, m.g_ldb))


def t_sliders():
    """Drive sliders 5-8 with values that are NOT their defaults.

    Every other comp test happens to use the plugin's own default threshold /
    ratio / range / knee, so a header that failed to parse those sliders would
    fall back to the same numbers and pass vacuously. This one cannot: a
    dropped slider would leave the plugin on -24/2.0/8/6 while the model runs
    -18/4.0/14/2, and the waveforms would diverge by dB. The probe level is
    chosen so neither setting sits on the range clamp, which would hide the
    difference.
    """
    p = params(loudness=100.0, thresh=-18.0, ratio=4.0, rng=14.0, knee=2.0)
    sigl, sigr = multitone(-26.0), multitone(-26.0, phase=1.1)
    ch = [sigl, sigr]
    out, _ = render("sliders", slider_line(p), ch)
    ref, m = run_model(ch, p)
    ok, det = compare(out, ref, lo=REG0, hi=REG1)
    # and prove the settings actually changed the outcome vs the defaults
    ref_def, m_def = run_model(ch, params(loudness=100.0))
    sep = maxdiff(ref[0], ref_def[0], REG0, REG1)
    ok = ok and sep > 0.01
    report("sliders", ok, det +
           "  lift %.2f dB vs %.2f with defaults (separation %.3f, need >0.01)"
           % (m.g_ldb, m_def.g_ldb, sep))


def t_ballistics():
    """-55 -> -12 dBFS step: the lift must collapse with the right time
    constants. Waveform-exact vs the model across the transition."""
    p = params(loudness=100.0)
    sig = step_signal(-55.0, -12.0)
    ch = [sig, sig]
    out, _ = render("ballistics", slider_line(p), ch)
    ref, _ = run_model(ch, p)
    ok, det = compare(out, ref, lo=int(1.4 * SR), hi=int(2.4 * SR))
    report("ballistics", ok, det + "  (across the -55->-12 dBFS step)")


def t_click():
    """Silence -> near full scale at max lift. Guards the 32-sample shelf
    redesign: a coefficient step coarse enough to zipper would show up as a
    sample-to-sample discontinuity the model does not have."""
    p = params(loudness=100.0)
    sig = gate_signal(-3.0)
    ch = [sig, sig]
    out, _ = render("click", slider_line(p), ch)
    ref, _ = run_model(ch, p)
    lo, hi = int(0.9 * SR), int(2.0 * SR)
    ok, det = compare(out, ref, lo=lo, hi=hi)

    def worst_jump(x):
        return max(abs(x[i + 1] - x[i]) for i in range(lo, hi - 1))

    jo, jr = worst_jump(out[0]), worst_jump(ref[0])
    ok = ok and jo <= jr * 1.05 + 1e-6
    report("click", ok, det + "  worst step out=%.4f ref=%.4f" % (jo, jr))


def t_xfeed():
    """Crossfeed must be real bs2b, matched sample-exactly against the
    libbs2b-derived reference in model.bs2b_coefs()."""
    p = params(xf_db=5.0)
    sigl, sigr = multitone(-15.0), multitone(-15.0, phase=1.1)
    ch = [sigl, sigr]
    out, _ = render("xfeed", slider_line(p), ch)
    ref, _ = run_model(ch, p)
    ok, det = compare(out, ref, lo=SR // 2)
    report("xfeed", ok, det)


def t_xfeed_off():
    """slider4 = 0 must hard-bypass. The bs2b formulas do NOT degenerate to
    unity at feed = 0 (they give g_lo=0.708, g_hi=0.292), so the plugin needs
    an explicit branch rather than relying on the maths."""
    p = params(xf_db=0.0)
    sigl, sigr = multitone(-15.0), multitone(-15.0, phase=1.1)
    out, _ = render("xfeed_off", slider_line(p), [sigl, sigr])
    ok, det = compare(out, [sigl, sigr], tol=1e-6)
    report("xfeed_off", ok, det)


def t_rate_robust():
    """Render at 44.1 k and 96 k: output must stay finite and bounded.

    LIMITATION - this does NOT verify rate-dependent coefficients. Under
    `reaper -newinst -nosplash -renderproject`, JSFX srate is pinned to the
    audio device rate (48000 here) no matter what the project SAMPLERATE and
    RENDER_FMT say; REAPER resamples around the FX instead. Measured with a
    throwaway probe plugin that emitted srate as a DC sample value: a 44100 and
    a 96000 render both reported srate = 48000.0 inside @init and @sample.
    So all this can assert is that the resampled path stays sane. Real
    rate-dependent verification needs a live REAPER session at that rate.
    """
    ok = True
    lines = []
    for sr in (44100, 96000):
        p = params(loudness=100.0, xf_db=5.0)
        n = int(sr * DUR)
        w = [2 * math.pi * bin_freq(f, sr, N) / sr
             for f in (60, 150, 1000, 4000, 10000)]
        sig = [sum(math.sin(wk * i + k * 0.7) for k, wk in enumerate(w))
               for i in range(n)]
        cur = math.sqrt(sum(v * v for v in sig) / n)
        g = 10.0 ** (-30.0 / 20.0) / cur
        sig = [v * g for v in sig]
        out, _ = render("sr%d" % sr, slider_line(p), [sig, sig], srate=sr)
        pk = max(max(abs(v) for v in c) for c in out)
        finite = all(v == v and abs(v) < float("inf") for c in out for v in c)
        rr = rms(out[0], sr, sr * 2)
        good = finite and pk < 4.0 and rr > 1e-4
        ok = ok and good
        lines.append("    %d Hz: peak %.3f  rms %.5f  finite=%s" %
                     (sr, pk, rr, finite))
    report("rate_robust", ok, "\n" + "\n".join(lines))


def t_nyquist():
    """Filter designers must clamp to srate*0.45 so a low session rate cannot
    push hpf(5000) / highshelf(6500) past Nyquist.

    Checked against model.py, which mirrors the .jsfx designers line for line
    and is proven equivalent to the real plugin to ~1e-7 by every 48 kHz test
    above. It cannot be render-verified: see t_rate_robust for why the harness
    cannot hand the plugin a non-48 kHz srate.
    """
    bad = []
    for sr in (8000.0, 11025.0, 22050.0, 44100.0, 48000.0, 96000.0, 192000.0):
        designs = [("lowshelf", model.low_shelf(model.LOW_F, 18.0, sr)),
                   ("highshelf", model.high_shelf(model.HIGH_F, 8.0, sr)),
                   ("det lpf", model.lpf(model.DET_LO_F, sr)),
                   ("det hpf", model.hpf(model.DET_HI_F, sr))]
        for nm, c in designs:
            if any(v != v or abs(v) > 1e6 for v in c):
                bad.append("%s@%g non-finite" % (nm, sr))
                continue
            # poles strictly inside the unit circle: a2 < 1 and |a1| < 1 + a2
            a1, a2 = c[3], c[4]
            if not (abs(a2) < 1.0 and abs(a1) < 1.0 + a2):
                bad.append("%s@%g unstable (a1=%.4f a2=%.4f)" % (nm, sr, a1, a2))
        for f, nm in ((model.HIGH_F, "highshelf"), (model.DET_HI_F, "det hpf")):
            if f > sr * 0.5 and min(f, sr * 0.45) >= sr * 0.5:
                bad.append("%s@%g not clamped below Nyquist" % (nm, sr))
    report("nyquist", not bad,
           "7 rates x 4 designers stable and below Nyquist"
           if not bad else "; ".join(bad))


ALL = [("canary", t_canary), ("identity", t_identity), ("contour", t_contour),
       ("comp_static", t_comp_static), ("comp_mid", t_comp_mid),
       ("sliders", t_sliders),
       ("ballistics", t_ballistics), ("click", t_click),
       ("xfeed", t_xfeed), ("xfeed_off", t_xfeed_off),
       ("rate_robust", t_rate_robust), ("nyquist", t_nyquist)]


def main():
    os.makedirs(WORK, exist_ok=True)
    sel = sys.argv[1:]
    for name, fn in ALL:
        if sel and name not in sel:
            continue
        try:
            fn()
        except Exception as e:
            report(name, False, "EXCEPTION %s" % e)
    bad = [n for n, ok in RESULTS if not ok]
    print("----\n%d/%d passed" % (len(RESULTS) - len(bad), len(RESULTS)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
