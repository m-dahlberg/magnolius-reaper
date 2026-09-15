#!/usr/bin/env python3
"""Headless render-test harness for Magnolius_PerceptualEQ.jsfx.

Renders a tiny REAPER project through the plugin with
`reaper -newinst -nosplash -renderproject` (works while a normal REAPER
instance is running) and checks the rendered audio with pure-Python analysis.

Prerequisites:
  - Magnolius_PerceptualEQ.jsfx symlinked/installed as <resource>/Effects/Magnolius_PerceptualEQ.jsfx
  - tools/make_test_irs.py has been run (writes <resource>/Data/ReverbIRs/*)

Usage:
  render_test.py               # run all tests
  render_test.py unity swap    # run selected tests
Work dir: ~/.cache/peq-rendertest (override with PEQ_TEST_DIR).
"""
import base64
import math
import os
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav, write_wav_f32
from validate_iso226 import contour, interp_logf, FREQ
import fit_reference

WORK = os.environ.get("PEQ_TEST_DIR",
                      os.path.expanduser("~/.cache/peq-rendertest"))
SR = 48000
IN_LEN = 1.0  # seconds
FREQ_L, FREQ_R = 997.0, 1499.0
AMP = 0.4
# settled comparison region (skips the plugin's ~40 ms trim fade-in generously)
REG0, REG1 = 24000, 45000

RENDER_CFG = base64.b64encode(b"evaw" + struct.pack("<i", 32)).decode()  # 32-bit float wav


def input_channels():
    n = int(SR * IN_LEN)
    left = [AMP * math.sin(2 * math.pi * FREQ_L * t / SR) for t in range(n)]
    right = [AMP * math.sin(2 * math.pi * FREQ_R * t / SR) for t in range(n)]
    return [left, right]


def slider_line(mode=0, ir=None, rvb_on=0, wet=0.0, dry=-60.0,
                xf_on=0, xf_fcut=700.0, xf_feed=4.5, strength=50.0):
    # ir: file name RELATIVE to the slider's directory (Data/ReverbIRs),
    # e.g. "test_unity4.wav" — confirmed against a REAPER-written chunk
    vals = ["%d.000000" % mode, "0.000000", "60.000000", "%.6f" % strength,
            "12.000000", "0.000000",
            "%d.000000" % xf_on, "%.6f" % xf_fcut, "%.6f" % xf_feed,
            ('"%s"' % ir) if ir else "-",
            "%d.000000" % rvb_on, "%.6f" % wet, "%.6f" % dry]
    vals += ["-"] * 51
    return " ".join(vals)


def js_ser_block(meas, flags, cur_step, ser_ver=1):
    """Serialized plugin state: the @serialize stream is ser_ver, MEAS[64],
    FLAGS[64], cur_step as raw 32-bit LE floats, base64 inside <JS_SER."""
    floats = [float(ser_ver)] + list(meas) + list(flags) + [float(cur_step)]
    assert len(floats) == 130
    raw = struct.pack("<%df" % len(floats), *floats)
    b64 = base64.b64encode(raw).decode()
    lines = [b64[i:i + 128] for i in range(0, len(b64), 128)]
    return "<JS_SER\n" + "\n".join("        " + ln for ln in lines) + "\n      >"


def bs2b_ref(left, right, sr=SR, fcut=700.0, feed=4.5):
    """Reference bs2b crossfeed, formulas verbatim from libbs2b init()."""
    gb_lo = feed * -5.0 / 6.0 - 3.0
    gb_hi = feed / 6.0 - 3.0
    g_lo = 10.0 ** (gb_lo / 20.0)
    g_hi = 1.0 - 10.0 ** (gb_hi / 20.0)
    fc_hi = fcut * 2.0 ** ((gb_lo - 20.0 * math.log10(g_hi)) / 12.0)
    x = math.exp(-2.0 * math.pi * fcut / sr)
    b1_lo, a0_lo = x, g_lo * (1.0 - x)
    x = math.exp(-2.0 * math.pi * fc_hi / sr)
    b1_hi, a0_hi, a1_hi = x, 1.0 - g_hi * (1.0 - x), -x
    gain = 1.0 / (1.0 - g_hi + g_lo)
    lo_l = lo_r = hi_l = hi_r = as_l = as_r = 0.0
    out_l, out_r = [], []
    for il, ir_ in zip(left, right):
        lo_l = a0_lo * il + b1_lo * lo_l
        lo_r = a0_lo * ir_ + b1_lo * lo_r
        hi_l = a0_hi * il + a1_hi * as_l + b1_hi * hi_l
        hi_r = a0_hi * ir_ + a1_hi * as_r + b1_hi * hi_r
        as_l, as_r = il, ir_
        out_l.append((hi_l + lo_r) * gain)
        out_r.append((hi_r + lo_l) * gain)
    return out_l, out_r


def make_rpp(path, sliders, out_wav, input_wav=None, length=1.5, srate=SR,
             js_ser=None, in_len=IN_LEN):
    item = ""
    if input_wav:
        item = """    <ITEM
      POSITION 0
      LENGTH %s
      LOOP 0
      NAME input
      <SOURCE WAVE
        FILE "%s"
      >
    >
""" % (in_len, input_wav)
    ser = ("\n      " + js_ser) if js_ser else ""
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
      <JS "Magnolius_PerceptualEQ.jsfx" ""
        %s
      >%s
    >
%s  >
>
""" % (srate, out_wav, srate, length, RENDER_CFG, sliders, ser, item)
    with open(path, "w") as f:
        f.write(rpp)


def render(name, sliders, with_input=True, length=1.5, srate=SR,
           js_ser=None, input_name="input.wav", in_len=IN_LEN):
    out_wav = os.path.join(WORK, name + ".wav")
    rpp = os.path.join(WORK, name + ".rpp")
    if os.path.exists(out_wav):
        os.remove(out_wav)
    make_rpp(rpp, sliders, out_wav,
             input_wav=os.path.join(WORK, input_name) if with_input else None,
             length=length, srate=srate, js_ser=js_ser, in_len=in_len)
    t0 = time.time()
    subprocess.run(["reaper", "-newinst", "-nosplash", "-renderproject", rpp],
                   check=True, timeout=300,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dt = time.time() - t0
    if not os.path.exists(out_wav):
        raise RuntimeError("render produced no output: " + out_wav)
    sr, chans = read_wav(out_wav)
    return chans, dt


def rms(x, a=0, b=None):
    seg = x[a:b]
    return math.sqrt(sum(v * v for v in seg) / max(len(seg), 1))


def maxdiff(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def check_matches(out, ref_l, ref_r, delay=0, tol=0.0001):
    """out[REG0:REG1] must equal ref[REG0-delay:REG1-delay] on both channels."""
    dl = maxdiff(out[0][REG0:REG1], ref_l[REG0 - delay:REG1 - delay])
    dr = maxdiff(out[1][REG0:REG1], ref_r[REG0 - delay:REG1 - delay])
    ok = dl < tol and dr < tol
    return ok, "maxdiff L=%.2e R=%.2e (tol %g)" % (dl, dr, tol)


RESULTS = []


def report(name, ok, detail):
    RESULTS.append((name, ok))
    print("%-12s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


IN_L, IN_R = None, None


def t_canary():
    # Test mode, no input: tone generator must produce output.
    # This proves every JSFX section compiled (a dead @init = silent passthrough).
    out, _ = render("canary", slider_line(mode=1), with_input=False, length=3.0)
    r = rms(out[0], 0, SR * 3)
    report("canary", r > 0.001, "test-tone rms=%.4f" % r)


def t_identity():
    # Correct mode, reverb off: output == input; also the regression baseline.
    out, _ = render("identity", slider_line(mode=0))
    ok, det = check_matches(out, IN_L, IN_R)
    base = os.path.join(WORK, "baseline_identity.wav")
    if ok and not os.path.exists(base):
        shutil.copy(os.path.join(WORK, "identity.wav"), base)
        det += " [baseline saved]"
    elif os.path.exists(base):
        _, bch = read_wav(base)
        d = max(maxdiff(out[0], bch[0]), maxdiff(out[1], bch[1]))
        ok = ok and d == 0
        det += " baseline-diff=%.2e" % d
    report("identity", ok, det)


def t_unity():
    out, _ = render("unity", slider_line(
        ir="test_unity4.wav", rvb_on=1, wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R)
    det += "  wet/in rms ratio L=%.4f" % (rms(out[0], REG0, REG1) /
                                          max(rms(IN_L, REG0, REG1), 1e-12))
    report("unity", ok, det)


def t_swap():
    out, _ = render("swap", slider_line(
        ir="test_swap4.wav", rvb_on=1, wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_R, IN_L)  # channels must be swapped
    report("swap", ok, det)


def t_delay5k():
    out, _ = render("delay5k", slider_line(
        ir="test_delay5k4.wav", rvb_on=1, wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R, delay=5000)
    report("delay5k", ok, det)


def t_stereo2ch():
    out, _ = render("stereo2ch", slider_line(
        ir="test_unity2.wav", rvb_on=1, wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R)
    report("stereo2ch", ok, det)


def t_resample():
    # 96k IR with impulse at 9600 -> 4800-sample echo in a 48k project.
    # Linear resampling of a lone impulse is exact only when it lands on an
    # output grid point (9600/2 does), so a tight tolerance still applies.
    out, _ = render("resample", slider_line(
        ir="test_delay96k.wav", rvb_on=1, wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R, delay=4800, tol=0.001)
    report("resample", ok, det)


def t_drywet():
    # dry 0 / wet 0 with unity IR: dry + wet = 2x input (checks mix + alignment)
    out, _ = render("drywet", slider_line(
        ir="test_unity4.wav", rvb_on=1, wet=0.0, dry=0.0))
    ref_l = [2 * v for v in IN_L]
    ref_r = [2 * v for v in IN_R]
    ok, det = check_matches(out, ref_l, ref_r)
    report("drywet", ok, det)


def t_xfeed():
    # crossfeed on, reverb off: output must match the Python bs2b reference
    # sample-exactly (validates coefficients, filter states and the gain
    # compensation, not just "some sound crosses over")
    out, _ = render("xfeed", slider_line(xf_on=1))
    ref_l, ref_r = bs2b_ref(IN_L, IN_R)
    ok, det = check_matches(out, ref_l, ref_r)
    report("xfeed", ok, det)


def t_xforder():
    # crossfeed on + L->L-only IR, wet-only. Crossfeed-before-reverb yields
    # (crossfed L, silence); reverb-before-crossfeed would leak lowpassed
    # left into the right channel. Unity/swap/delay IRs commute with the
    # crossfeed and could not tell the two orders apart.
    out, _ = render("xforder", slider_line(
        ir="test_lonly4.wav", rvb_on=1, wet=0.0, dry=-60.0, xf_on=1))
    ref_l, _ = bs2b_ref(IN_L, IN_R)
    ok, det = check_matches(out, ref_l, [0.0] * len(IN_R))
    report("xforder", ok, det)


CURVE_DEV = [-4.6, -0.4, 0.8, 0.4, 1.4, 1.6, 0.0, -0.6, 1.2, -1.4, -0.8,
             -3.2, -3.4, -2.4, 1.6]  # hostile: sign flips + same-sign runs
IMP_POS = 36000    # impulse placed after the trim fade-in has settled
IMP_WIN = 32768    # response window for the DFT probes


def dft_db(x, f, sr=SR):
    re = im = 0.0
    for n, v in enumerate(x):
        w = 2 * math.pi * f * n / sr
        re += v * math.cos(w)
        im -= v * math.sin(w)
    return 20 * math.log10(max(math.sqrt(re * re + im * im), 1e-12))


def t_curve():
    # Serialized hearing-test state -> Correct mode at strength 100 must
    # reproduce the fitted correction curve: through the measured points,
    # smooth spline target between them, 1 kHz anchor at exactly 0 dB.
    bands = fit_reference.BANDS
    c60 = contour(60.0)
    ref1k = c60[FREQ.index(1000)]
    isorel = [interp_logf(f, c60) - ref1k for f in bands]
    meas = [0.0] * 64
    flags = [0.0] * 64
    for i, dv in enumerate(CURVE_DEV):
        if i == fit_reference.ANCHOR_IDX:
            continue
        meas[i] = isorel[i] + dv
        flags[i] = 1.0
    ser = js_ser_block(meas, flags, cur_step=14)

    n = int(SR * 1.45)
    imp = [0.0] * n
    imp[IMP_POS] = 1.0
    write_wav_f32(os.path.join(WORK, "impulse.wav"), SR, [imp, imp])

    out, _ = render("curve", slider_line(mode=0, strength=100.0),
                    js_ser=ser, input_name="impulse.wav", in_len=1.45)
    resp = out[0][IMP_POS:IMP_POS + IMP_WIN]

    ref = fit_reference.FitReference(sr=SR, maxboost=12.0, strength=100.0)
    # meas is serialized as f32; mirror that quantization in the reference
    dev32 = [struct.unpack("<f", struct.pack("<f", meas[i]))[0] - isorel[i]
             if i != fit_reference.ANCHOR_IDX else 0.0
             for i in range(len(bands))]
    gains, tcurve, peak = ref.fit(dev32)
    trim_db = -peak  # outtrim 0, auto headroom
    pts = ref.point_targets(dev32)

    mids = [math.sqrt(bands[i] * bands[i + 1]) for i in range(len(bands) - 1)]
    worst_ref = worst_pt = worst_mid = 0.0
    for f in bands + mids:
        got = dft_db(resp, f)
        want = ref.cascade_db(gains, f) + trim_db
        worst_ref = max(worst_ref, abs(got - want))
    for i, f in enumerate(bands):
        worst_pt = max(worst_pt, abs(dft_db(resp, f) - trim_db - pts[i]))
    for f in mids:
        want = ref._lin_at(tcurve, math.log(f))
        worst_mid = max(worst_mid, abs(dft_db(resp, f) - trim_db - want))
    ok = worst_ref < 0.05 and worst_pt < 0.15 and worst_mid < 0.3
    report("curve", ok,
           "vs reference %.3f dB (tol 0.05), points %.3f (tol 0.15), "
           "spline midpoints %.3f (tol 0.3), trim %.2f dB"
           % (worst_ref, worst_pt, worst_mid, trim_db))


def t_cpu():
    # 5.4 s dense IR: no assertion, just render-time telemetry (render is
    # offline, so wall time >> real time would flag live-playback risk).
    out, dt = render("cpu", slider_line(
        ir="test_hall4.wav", rvb_on=1, wet=0.0, dry=0.0), length=3.0)
    r = rms(out[0], REG0, REG1)
    report("cpu", r > 0.001, "5.4s-IR render of 3.0s took %.1fs, wet rms=%.4f" % (dt, r))


ALL = [("canary", t_canary), ("identity", t_identity), ("unity", t_unity),
       ("swap", t_swap), ("delay5k", t_delay5k), ("stereo2ch", t_stereo2ch),
       ("resample", t_resample), ("drywet", t_drywet),
       ("xfeed", t_xfeed), ("xforder", t_xforder), ("curve", t_curve),
       ("cpu", t_cpu)]


def main():
    global IN_L, IN_R
    os.makedirs(WORK, exist_ok=True)
    IN_L, IN_R = input_channels()
    write_wav_f32(os.path.join(WORK, "input.wav"), SR, [IN_L, IN_R])
    sel = sys.argv[1:]
    for name, fn in ALL:
        if sel and name not in sel:
            continue
        try:
            fn()
        except Exception as e:  # keep going; report the failure
            report(name, False, "EXCEPTION %s" % e)
    bad = [n for n, ok in RESULTS if not ok]
    print("----\n%d/%d passed" % (len(RESULTS) - len(bad), len(RESULTS)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
