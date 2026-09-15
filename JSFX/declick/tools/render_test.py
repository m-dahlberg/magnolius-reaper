#!/usr/bin/env python3
"""Headless render-test harness for Magnolius_DeClick.jsfx.

Renders a tiny REAPER project through the plugin with
`reaper -newinst -nosplash -renderproject` (works while a normal REAPER
instance is running) and checks the rendered audio with pure-Python analysis.

Prerequisite: Magnolius_DeClick.jsfx symlinked as <resource>/Effects/Magnolius_DeClick.jsfx.

Usage:
  render_test.py               # run all tests
  render_test.py apply quiet   # run selected tests
Work dir: ~/.cache/declicker-rendertest (override with DECLICK_TEST_DIR).
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

WORK = os.environ.get("DECLICK_TEST_DIR",
                      os.path.expanduser("~/.cache/declicker-rendertest"))
SR = 48000
IN_LEN = 4.0  # seconds
BED_FREQ = 440.0
BED_AMP = 0.3
# stereo clicks at exact sample positions; one extra click in R only
CLICKS = [24000, 48000, 72000, 96000, 120000, 144000]
R_ONLY_CLICK = 156000
CLICK_SHAPE = [0.6, -0.5, 0.4]

RENDER_CFG = base64.b64encode(b"evaw" + struct.pack("<i", 32)).decode()

RESOURCE = os.path.expanduser("~/.config/REAPER")


def input_channels(with_clicks=True):
    n = int(SR * IN_LEN)
    left = [BED_AMP * math.sin(2 * math.pi * BED_FREQ * t / SR)
            for t in range(n)]
    right = list(left)
    if with_clicks:
        for p in CLICKS:
            for i, v in enumerate(CLICK_SHAPE):
                left[p + i] += v
                right[p + i] += v
        for i, v in enumerate(CLICK_SHAPE):
            right[R_ONLY_CLICK + i] += v
    return [left, right]


def slider_line(action=1, passes=2, sens=6.0, step_ms=5.0, max_steps=2,
                sep=3, crackle=-45.0, flo=150.0, fhi=20000.0, nbands=16,
                xfade=5.0):
    vals = ["%.6f" % v for v in (action, passes, sens, step_ms, max_steps,
                                 sep, crackle, flo, fhi, nbands, xfade)]
    vals += ["-"] * 53
    return " ".join(vals)


def make_rpp(path, sliders, out_wav, input_wav, length=IN_LEN, srate=SR):
    item = """    <ITEM
      POSITION 0
      LENGTH %s
      LOOP 0
      NAME input
      <SOURCE WAVE
        FILE "%s"
      >
    >
""" % (IN_LEN, input_wav)
    rpp = """<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000
  SAMPLERATE %d 0 0
  TEMPO 120 4 4
  RENDER_FILE "%s"
  RENDER_PATTERN ""
  RENDER_FMT 0 2 %d
  RENDER_1X 0
  RENDER_RANGE 1 0 %s 18 1000
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
      <JS "Magnolius_DeClick.jsfx" ""
        %s
      >
    >
%s  >
>
""" % (srate, out_wav, srate, length, RENDER_CFG, sliders, item)
    with open(path, "w") as f:
        f.write(rpp)


def render(name, sliders, input_name="input.wav"):
    out_wav = os.path.join(WORK, name + ".wav")
    rpp = os.path.join(WORK, name + ".rpp")
    if os.path.exists(out_wav):
        os.remove(out_wav)
    make_rpp(rpp, sliders, out_wav, os.path.join(WORK, input_name))
    t0 = time.time()
    subprocess.run(["reaper", "-newinst", "-nosplash", "-renderproject", rpp],
                   check=True, timeout=600,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dt = time.time() - t0
    if not os.path.exists(out_wav):
        raise RuntimeError("render produced no output: " + out_wav)
    sr, chans = read_wav(out_wav)
    return chans, dt


def maxdiff(a, b, lo, hi):
    return max(abs(x - y) for x, y in zip(a[lo:hi], b[lo:hi]))


def peak(x, lo, hi):
    return max(abs(v) for v in x[lo:hi])


def dft_mag(x, f, sr=SR):
    re = im = 0.0
    for n, v in enumerate(x):
        w = 2 * math.pi * f * n / sr
        re += v * math.cos(w)
        im -= v * math.sin(w)
    return math.sqrt(re * re + im * im)


# regions well away from any click (>=100 ms clearance)
QUIET = [(10000, 20000), (32000, 42000), (128000, 140000), (170000, 185000)]

RESULTS = []


def report(name, ok, detail):
    RESULTS.append((name, ok))
    print("%-12s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


IN_L, IN_R = None, None
BED_L, BED_R = None, None


def t_params():
    """ReaScript probe: all 11 sliders must have parsed (a broken header
    silently eats sliders with no error UI)."""
    outfile = os.path.join(WORK, "params.txt")
    if os.path.exists(outfile):
        os.remove(outfile)
    lua = os.path.join(WORK, "probe.lua")
    rpp = os.path.join(WORK, "probe.rpp")
    with open(rpp, "w") as f:
        f.write('<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000\n'
                '  <TRACK\n    NAME "probe"\n  >\n>\n')
    with open(lua, "w") as f:
        f.write("""
local tr = reaper.GetTrack(0, 0)
local fx = reaper.TrackFX_AddByName(tr, "Magnolius_DeClick.jsfx", false, -1)
local f = io.open("%s", "w")
if fx < 0 then
  f:write("ADD_FAILED\\n")
else
  local n = reaper.TrackFX_GetNumParams(tr, fx)
  f:write("nparams " .. n .. "\\n")
  for i = 0, n - 1 do
    local _, name = reaper.TrackFX_GetParamName(tr, fx, i, "")
    f:write(i .. " " .. name .. "\\n")
  end
end
f:close()
reaper.Main_SaveProject(0, false)
reaper.Main_OnCommand(40004, 0)
""" % outfile)
    subprocess.run(["reaper", "-newinst", "-nosplash", rpp, lua],
                   check=True, timeout=120,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(outfile):
        report("params", False, "probe wrote no output")
        return
    lines = open(outfile).read().splitlines()
    if not lines or lines[0].startswith("ADD_FAILED"):
        report("params", False, "plugin failed to load")
        return
    names = {}
    for ln in lines[1:]:
        idx, _, nm = ln.partition(" ")
        names[int(idx)] = nm
    # REAPER appends wet/bypass/delta params after the sliders
    want0, want10 = "Action", "Crossfade widen (ms)"
    ok = (len(names) >= 11 and names.get(0) == want0
          and names.get(10) == want10)
    report("params", ok, "%d params, [0]=%r [10]=%r" %
           (len(names), names.get(0), names.get(10)))


def t_quiet():
    # clean bed, no clicks: output must be identical to input (no false
    # positives, and PDC-compensated alignment is sample-exact)
    out, _ = render("quiet", slider_line(), input_name="bed.wav")
    d = max(maxdiff(out[0], BED_L, 5000, 185000),
            maxdiff(out[1], BED_R, 5000, 185000))
    report("quiet", d < 0.000001, "maxdiff vs input %.2e (tol 1e-6)" % d)


def t_apply():
    out, _ = render("apply", slider_line(action=1))
    # 1. untouched regions bit-match the input (also proves latency == PDC)
    worst_q = 0.0
    for lo, hi in QUIET:
        worst_q = max(worst_q, maxdiff(out[0], IN_L, lo, hi),
                      maxdiff(out[1], IN_R, lo, hi))
    ok_q = worst_q < 0.000001
    # 2. every click peak is substantially reduced
    worst_ratio = 0.0
    engaged = True
    for p in CLICKS:
        ip = peak(IN_L, p - 10, p + 20)
        op = peak(out[0], p - 10, p + 20)
        worst_ratio = max(worst_ratio, op / ip)
        if maxdiff(out[0], IN_L, p - 480, p + 480) < 0.001:
            engaged = False  # plugin never touched this click: vacuous
    ok_c = worst_ratio < 0.75 and engaged
    # 3. the 440 Hz bed survives through the repair (multiband selectivity)
    p = CLICKS[2]
    bed_in = dft_mag(IN_L[p - 480:p + 960], BED_FREQ)
    bed_out = dft_mag(out[0][p - 480:p + 960], BED_FREQ)
    bed_db = 20 * math.log10(max(bed_out, 1e-12) / max(bed_in, 1e-12))
    # the click legitimately raises energy in the bed's neighboring band, so
    # a few dB of dip from that band's repair skirt is faithful behavior;
    # this only guards against the repair flattening the whole spectrum
    ok_b = abs(bed_db) < 6.0
    report("apply", ok_q and ok_c and ok_b,
           "quiet maxdiff %.2e, worst click peak ratio %.2f, engaged %s, "
           "bed %.2f dB" % (worst_q, worst_ratio, engaged, bed_db))


def t_isolate():
    # isolate = repaired - dry; therefore apply-render == input + isolate
    iso, _ = render("isolate", slider_line(action=0))
    out, _ = render("apply2", slider_line(action=1))
    worst_q = 0.0
    for lo, hi in QUIET:
        worst_q = max(worst_q, peak(iso[0], lo, hi), peak(iso[1], lo, hi))
    sum_l = [a + b for a, b in zip(IN_L, iso[0])]
    sum_r = [a + b for a, b in zip(IN_R, iso[1])]
    d = max(maxdiff(out[0], sum_l, 5000, 185000),
            maxdiff(out[1], sum_r, 5000, 185000))
    nonzero = max(peak(iso[0], p - 480, p + 480) for p in CLICKS)
    ok = worst_q < 0.000001 and d < 0.00001 and nonzero > 0.01
    report("isolate", ok,
           "quiet peak %.2e, apply-(in+iso) maxdiff %.2e, click diff peak %.3f"
           % (worst_q, d, nonzero))


def t_stereo():
    # the R-only click must be repaired in R while L stays untouched there
    out, _ = render("stereo", slider_line(action=1))
    p = R_ONLY_CLICK
    dl = maxdiff(out[0], IN_L, p - 480, p + 480)
    dr = maxdiff(out[1], IN_R, p - 480, p + 480)
    report("stereo", dl < 0.000001 and dr > 0.01,
           "L maxdiff %.2e (must be ~0), R maxdiff %.3f (must be >0.01)"
           % (dl, dr))


def t_pass1():
    # single pass still detects and aligns (checks the PDC formula for np=1)
    out, _ = render("pass1", slider_line(action=1, passes=1))
    worst_q = 0.0
    for lo, hi in QUIET:
        worst_q = max(worst_q, maxdiff(out[0], IN_L, lo, hi))
    p = CLICKS[0]
    reduced = peak(out[0], p - 10, p + 20) < peak(IN_L, p - 10, p + 20) * 0.9
    report("pass1", worst_q < 0.000001 and reduced,
           "quiet maxdiff %.2e, click reduced %s" % (worst_q, reduced))


def t_cpu():
    _, dt = render("cpu", slider_line(action=1, nbands=30, passes=4))
    report("cpu", True, "4-pass 30-band render of %.0fs took %.1fs"
           % (IN_LEN, dt))


ALL = [("params", t_params), ("quiet", t_quiet), ("apply", t_apply),
       ("isolate", t_isolate), ("stereo", t_stereo), ("pass1", t_pass1),
       ("cpu", t_cpu)]


def main():
    global IN_L, IN_R, BED_L, BED_R
    os.makedirs(WORK, exist_ok=True)
    IN_L, IN_R = input_channels(True)
    BED_L, BED_R = input_channels(False)
    write_wav_f32(os.path.join(WORK, "input.wav"), SR, [IN_L, IN_R])
    write_wav_f32(os.path.join(WORK, "bed.wav"), SR, [BED_L, BED_R])
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
