#!/usr/bin/env python3
"""Headless render tests for Magnolius_VariMuCompressor.jsfx.

    ./render_test.py                  # everything
    ./render_test.py unity canary     # named tests only

Renders go through `reaper -newinst`, so they are safe to run while a normal
REAPER is open. Work files land in ~/.cache/varimu-rendertest (VARIMU_WORK
overrides). VARIMU_FX_NAME overrides the FX lookup name.

Prerequisite: Magnolius_VariMuCompressor.jsfx symlinked (never copied) somewhere under
<resource>/Effects/. A stale plain copy anywhere in that tree shadows the
repo file and every test below then silently tests old code.

tools/model.py mirrors the plugin sample-for-sample; edit the two together
and do not loosen a tolerance to make a test pass.
"""
import array
import math
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model                                                    # noqa: E402
from render_harness import Harness, maxdiff, slider_line       # noqa: E402

SR = 48000
DUR = 4.0
TOL = 2e-5          # agreement with model.py
UNITY_TOL = 5e-16   # REAPER injects ~1.5e-16 denormal DC into FX inputs
ORIG_TOL = 1e-6     # agreement with sstillwell/fairlychildish2

# The stock Stillwell plugin we are derived from, for the "original" test.
ORIG_FX = os.environ.get("VARIMU_ORIG_FX", "fairlychildish2")

H = Harness("varimu", os.environ.get("VARIMU_FX_NAME", "Magnolius_VariMuCompressor.jsfx"),
            srate=SR, work=os.environ.get("VARIMU_WORK"))


def S(**kw):
    """Slider line in header order, with kw overriding the defaults."""
    p = dict(model.DEFAULTS)
    p.update(kw)
    return slider_line([p[k] for k in model.ORDER])


def S_orig(**kw):
    """Slider line for the stock fairlychildish2 -- its first 11 sliders are
    the same parameters in the same order as ours."""
    p = dict(model.DEFAULTS)
    p.update(kw)
    return slider_line([p[k] for k in model.ORDER[:11]], nslots=11)


class LCG:
    """Deterministic noise; repeatable across machines unlike random()."""

    def __init__(self, seed=12345):
        self.s = seed

    def next(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / 0x3FFFFFFF - 1.0


def program(dur=DUR, srate=SR):
    """Stereo programme with transients, tone and a decaying tail, and
    deliberately DIFFERENT L and R so Mid/Side mode is actually exercised."""
    n = int(dur * srate)
    rng = LCG()
    L, R = [], []
    for i in range(n):
        t = i / srate
        env = math.exp(-((t % 0.5) * 8.0))            # 2 Hz transient train
        tone = math.sin(2 * math.pi * 220.0 * t)
        noise = rng.next() * 0.25
        L.append(0.6 * env * (tone + noise))
        R.append(0.6 * env * (0.7 * tone - noise) + 0.05 * math.sin(
            2 * math.pi * 55.0 * t))
    return L, R


def quiet(dur=DUR, srate=SR):
    """Well below any threshold we use, so the compressor stays inactive."""
    n = int(dur * srate)
    return ([0.001 * math.sin(2 * math.pi * 300.0 * i / srate) for i in range(n)],
            [0.001 * math.sin(2 * math.pi * 410.0 * i / srate) for i in range(n)])


def f32(xs):
    """Round to float32 exactly as write_wav_f32 will.

    Comparing a render against the float64 list we generated -- rather than
    against what actually reached the plugin -- costs one float32 ULP, which
    at 0.001 amplitude is 6e-11 and swamps every tolerance below it. This
    cost a debugging cycle; keep every reference signal rounded.
    """
    return list(array.array("f", xs))


def _in(name, chans):
    """Writes the input WAV and returns (wav_name, float32-rounded channels)."""
    H.write_input(name + "_in.wav", chans)
    return name + "_in.wav", [f32(c) for c in chans]


# ---------------------------------------------------------------------------

def t_params():
    """Every slider survived the header parse AND is still an automatable
    parameter despite the '-' that hides it from REAPER's slider list."""
    names, _ = H.probe_params()
    want = ["L/Mid Threshold (dB)", "R/Side Threshold (dB)", "L/Mid Bias (%)",
            "R/Side Bias (%)", "L/Mid Makeup (dB)", "R/Side Makeup (dB)",
            "Mode", "L/Mid Time Constant", "R/Side Time Constant",
            "L/Mid RMS Window (us)", "R/Side RMS Window (us)", "Max Ratio",
            "Sidechain HPF (Hz)", "Stereo Link (%)", "Mix (%)",
            "Output Trim (dB)", "Display History (s)"]
    bad = [(i, w, names.get(i)) for i, w in enumerate(want) if names.get(i) != w]
    H.report("params", not bad,
             "17 hidden sliders all enumerate" if not bad else "mismatch %s" % bad[:3])


def t_canary():
    """+6 dB makeup on a signal far below threshold must give exactly 2x.
    A dead @init degrades to passthrough, which cannot fake this."""
    L, R = quiet()
    nm, (L, R) = _in("canary", [L, R])
    out, _ = H.render("canary", S(lmakeup_db=6.0206), input_name=nm, length=DUR)
    g = 10 ** (6.0206 / 20)
    d = max(maxdiff(out[0], [v * g for v in L], 4800, len(L) - 4800),
            maxdiff(out[1], [v * g for v in R], 4800, len(R) - 4800))
    H.report("canary", d < 1e-6, "makeup +6.02 dB gives 2x, maxdiff %.2e" % d)


def t_unity():
    """Threshold 0 dB, quiet input, mix 100% => output is the input."""
    L, R = quiet()
    nm, (L, R) = _in("unity", [L, R])
    out, _ = H.render("unity", S(), input_name=nm, length=DUR)
    d = max(maxdiff(out[0], L, 4800, len(L) - 4800),
            maxdiff(out[1], R, 4800, len(R) - 4800))
    H.report("unity", d < UNITY_TOL, "passthrough maxdiff %.2e" % d)


def t_original():
    """THE headline test: render the stock sstillwell/fairlychildish2 and
    VariMuComp on the same programme at matched settings and diff. Proves
    the whole refactor is inaudible."""
    L, R = program()
    nm, (L, R) = _in("orig", [L, R])
    cases = [
        ("L/R blowncap tc1", dict(agc_mode=0, lthr_db=-24, ltc=1)),
        ("L/R tc4", dict(agc_mode=2, lthr_db=-24, ltc=4)),
        ("M/S blowncap tc1", dict(agc_mode=1, lthr_db=-24, rthr_db=-18, ltc=1, rtc=3)),
        ("M/S tc6", dict(agc_mode=3, lthr_db=-30, rthr_db=-20, ltc=6, rtc=2,
                         lbias_pct=40, rbias_pct=90, lmakeup_db=3,
                         rmakeup_db=-2, lrms_us=800, rrms_us=50)),
    ]
    worst = 0.0
    detail = []
    for i, (label, kw) in enumerate(cases):
        if not (int(kw["agc_mode"]) & 1):
            # L/R mode: the original force-links its right sliders to the
            # left, so feed both plugins matched pairs or the comparison is
            # meaningless.
            for a, b in (("lthr_db", "rthr_db"), ("lbias_pct", "rbias_pct"),
                         ("lmakeup_db", "rmakeup_db"), ("ltc", "rtc"),
                         ("lrms_us", "rrms_us")):
                kw[b] = kw.get(a, model.DEFAULTS[a])
        mine, _ = H.render("orig_new%d" % i, S(**kw), input_name=nm, length=DUR)
        theirs, _ = H.render("orig_old%d" % i, S_orig(**kw), input_name=nm,
                             length=DUR, fx=ORIG_FX)
        d = max(maxdiff(mine[0], theirs[0], 0, len(L)),
                maxdiff(mine[1], theirs[1], 0, len(L)))
        # Two identical silences would also diff to zero. Insist that each
        # case actually compressed, or this whole test passes vacuously --
        # the exact trap a passthrough-looking plugin falls into.
        engaged = maxdiff(mine[0], L, 0, len(L))
        if engaged < 0.05:
            worst = float("inf")
            detail.append("%s NOT ENGAGED (%.3f)" % (label, engaged))
            continue
        worst = max(worst, d)
        detail.append("%s %.1e" % (label, d))
    H.report("original", worst < ORIG_TOL,
             "vs %s: %s" % (ORIG_FX, "  ".join(detail)))


def t_model():
    """Agreement with tools/model.py across modes and the new controls."""
    L, R = program()
    nm, (L, R) = _in("model", [L, R])
    cases = [
        ("defaults", dict(lthr_db=-24)),
        ("ms", dict(agc_mode=3, lthr_db=-28, rthr_db=-20, ltc=5, rtc=2,
                    lbias_pct=30, rbias_pct=85)),
        ("newctl", dict(lthr_db=-26, ratio_max=6, sc_hz=180, link_pct=35,
                        mix_pct=55, trim_db=-3.5, ltc=3)),
    ]
    worst = 0.0
    detail = []
    for i, (label, kw) in enumerate(cases):
        out, _ = H.render("model%d" % i, S(**kw), input_name=nm, length=DUR)
        mL, mR = model.process(L, R, SR, **kw)
        d = max(maxdiff(out[0], mL, 0, len(L)), maxdiff(out[1], mR, 0, len(L)))
        worst = max(worst, d)
        detail.append("%s %.1e" % (label, d))
    H.report("model", worst < TOL, "  ".join(detail))


MODESWITCH_LUA = """
local out = [[%(out)s]]
local lines = {}
reaper.InsertTrackAtIndex(0, false)
local tr = reaper.GetTrack(0, 0)
-- Side-only params: 1 Side threshold, 3 Side bias, 5 Side makeup,
-- 8 Side time constant, 10 Side RMS window. Index = slider number - 1.
local side = {{1,-12},{3,25},{5,4},{8,5},{10,700}}
local function probe(fxname)
  local fx = reaper.TrackFX_AddByName(tr, fxname, false, -1)
  if fx < 0 then lines[#lines+1] = fxname .. "\\tADD_FAILED" return end
  reaper.TrackFX_SetParam(tr, fx, 6, 3)              -- Mid/Side
  for _, p in ipairs(side) do reaper.TrackFX_SetParam(tr, fx, p[1], p[2]) end
  reaper.TrackFX_SetParam(tr, fx, 6, 2)              -- L/R
  reaper.TrackFX_SetParam(tr, fx, 6, 3)              -- back to Mid/Side
  for _, p in ipairs(side) do
    lines[#lines+1] = string.format("%%s\\t%%d\\t%%.4f\\t%%.4f",
      fxname, p[1], p[2], reaper.TrackFX_GetParam(tr, fx, p[1]))
  end
end
probe([[%(mine)s]])
probe([[%(orig)s]])
local f = io.open(out, "w"); f:write(table.concat(lines, "\\n") .. "\\n"); f:close()
reaper.Main_SaveProject(0, false)
reaper.Main_OnCommand(40004, 0)
"""


def t_modeswitch():
    """Regression test for the original's worst bug.

    fairlychildish2's @slider assigns slider2/4/6/9/11 from the left-hand
    sliders whenever the mode is L/R, so a round trip Mid/Side -> L/R ->
    Mid/Side silently resets every Side setting to its Left counterpart.

    This asks REAPER for the parameter values directly rather than inferring
    it from audio: an audio comparison here measures detector-state
    relaxation (which takes many release constants to die away), not whether
    the settings survived.

    The stock plugin is probed alongside as a control -- if it ever stops
    failing, this test has stopped being able to detect the bug.
    """
    out = H.path("modeswitch.txt")
    lua = H.path("modeswitch.lua")
    rpp = H.path("modeswitch.rpp")
    if os.path.exists(out):
        os.remove(out)
    with open(rpp, "w") as f:
        f.write('<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000\n'
                '  <TRACK\n    NAME "probe"\n  >\n>\n')
    with open(lua, "w") as f:
        f.write(MODESWITCH_LUA % dict(out=out, mine=H.fx, orig=ORIG_FX))
    subprocess.run(["reaper", "-newinst", "-nosplash", rpp, lua],
                   check=True, timeout=120,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    kept, lost = [], []
    for ln in open(out).read().splitlines():
        parts = ln.split("\t")
        if len(parts) != 4:
            continue
        fx, idx, want, got = parts[0], int(parts[1]), float(parts[2]), float(parts[3])
        (kept if fx == H.fx else lost).append(abs(got - want) < 1e-4)
    ok = len(kept) == 5 and all(kept) and (not lost or not all(lost))
    H.report("modeswitch", ok,
             "Side settings survive M/S->L/R->M/S: %d/%d kept "
             "(control %s: %d/%d kept)"
             % (sum(kept), len(kept), ORIG_FX, sum(lost), len(lost)))


def t_link():
    """link 100% is the original's single-detector path; link 0% gives
    genuinely independent per-channel gains."""
    n = int(1.5 * SR)
    # loud left, quiet right: linked => right is ducked too; unlinked => not
    Lc = [0.7 * math.sin(2 * math.pi * 220 * i / SR) for i in range(n)]
    Rc = [0.02 * math.sin(2 * math.pi * 330 * i / SR) for i in range(n)]
    nm, (Lc, Rc) = _in("link", [Lc, Rc])
    kw = dict(lthr_db=-20, agc_mode=2, ltc=1)
    a, _ = H.render("link100", S(link_pct=100, **kw), input_name=nm, length=1.5)
    b, _ = H.render("link0", S(link_pct=0, **kw), input_name=nm, length=1.5)
    lo, hi = int(1.0 * SR), int(1.4 * SR)
    rms_a = math.sqrt(sum(v * v for v in a[1][lo:hi]) / (hi - lo))
    rms_b = math.sqrt(sum(v * v for v in b[1][lo:hi]) / (hi - lo))
    rms_r = math.sqrt(sum(v * v for v in Rc[lo:hi]) / (hi - lo))
    ok = rms_a < rms_r * 0.5 and rms_b > rms_r * 0.95
    H.report("link", ok, "linked R %.4f, unlinked R %.4f, dry R %.4f"
             % (rms_a, rms_b, rms_r))


def t_mix_trim():
    """mix 0% is the dry signal exactly; trim is exact dB."""
    L, R = program()
    nm, (L, R) = _in("mixtrim", [L, R])
    a, _ = H.render("mix0", S(lthr_db=-30, mix_pct=0), input_name=nm, length=DUR)
    d1 = max(maxdiff(a[0], L, 0, len(L)), maxdiff(a[1], R, 0, len(L)))
    b, _ = H.render("trim6", S(lthr_db=-30, trim_db=-6.0206, mix_pct=0),
                    input_name=nm, length=DUR)
    g = 10 ** (-6.0206 / 20)
    d2 = maxdiff(b[0], [v * g for v in L], 0, len(L))
    H.report("mix_trim", d1 < UNITY_TOL and d2 < 1e-6,
             "mix0 %.2e, trim -6.02 dB %.2e" % (d1, d2))


def t_schpf():
    """The sidechain HPF is fully bypassed at its 20 Hz minimum."""
    L, R = program()
    nm, (L, R) = _in("schpf", [L, R])
    a, _ = H.render("hpf_off", S(lthr_db=-26, sc_hz=20), input_name=nm, length=DUR)
    mL, mR = model.process(L, R, SR, lthr_db=-26, sc_hz=20)
    d0 = max(maxdiff(a[0], mL, 0, len(L)), maxdiff(a[1], mR, 0, len(L)))
    b, _ = H.render("hpf_on", S(lthr_db=-26, sc_hz=300), input_name=nm, length=DUR)
    moved = maxdiff(a[0], b[0], 0, len(L))
    H.report("schpf", d0 < TOL and moved > 1e-3,
             "bypassed at 20 Hz (%.1e vs model), 300 Hz changes GR (%.3f)"
             % (d0, moved))


def t_rates():
    """Coefficients stay sane at every rate; no NaN, no runaway."""
    bad = []
    for sr in (44100, 48000, 96000, 192000):
        n = int(1.0 * sr)
        L = [0.5 * math.sin(2 * math.pi * 200 * i / sr) for i in range(n)]
        R = [0.5 * math.sin(2 * math.pi * 200 * i / sr) for i in range(n)]
        H.write_input("rate_in.wav", [L, R], srate=sr)
        out, _ = H.render("rate%d" % sr, S(lthr_db=-30, ltc=6),
                          input_name="rate_in.wav", length=1.0, srate=sr)
        pk = max(abs(v) for v in out[0])
        if not (pk == pk) or pk > 1.5 or pk < 1e-6:
            bad.append((sr, pk))
    H.report("rates", not bad, "44.1/48/96/192k all finite and bounded"
             if not bad else "bad %s" % bad)


TESTS = [("params", t_params), ("canary", t_canary), ("unity", t_unity),
         ("original", t_original), ("model", t_model),
         ("modeswitch", t_modeswitch), ("link", t_link),
         ("mix_trim", t_mix_trim), ("schpf", t_schpf), ("rates", t_rates)]

if __name__ == "__main__":
    H.run(TESTS)
