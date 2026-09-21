#!/usr/bin/env python3
"""Headless render-test harness for Magnolius_ConvolutionReverb.jsfx.

Renders a tiny REAPER project through the plugin with
`reaper -newinst -nosplash -renderproject` (works while a normal REAPER
instance is running) and checks the rendered audio with pure-Python analysis.

Prerequisites:
  - Magnolius_ConvolutionReverb.jsfx symlinked/installed as
    <resource>/Effects/Magnolius_ConvolutionReverb.jsfx
  - tools/make_test_irs.py has been run (writes <resource>/Data/ReverbIRs/*)

Usage:
  render_test.py               # run all tests
  render_test.py unity swap    # run selected tests
Work dir: ~/.cache/convrvb-rendertest (override with CONVRVB_TEST_DIR).
"""
import base64
import math
import os
import random
import re
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav, write_wav_f32
import ir_onset            # reference model for the onset detector

WORK = os.environ.get("CONVRVB_TEST_DIR",
                      os.path.expanduser("~/.cache/convrvb-rendertest"))
SR = 48000
IN_LEN = 1.0  # seconds
FREQ_L, FREQ_R = 997.0, 1499.0
AMP = 0.4
# settled comparison region (well past convolver startup / partition fill)
REG0, REG1 = 24000, 45000

RENDER_CFG = base64.b64encode(b"evaw" + struct.pack("<i", 32)).decode()  # 32-bit float wav


def input_channels():
    n = int(SR * IN_LEN)
    left = [AMP * math.sin(2 * math.pi * FREQ_L * t / SR) for t in range(n)]
    right = [AMP * math.sin(2 * math.pi * FREQ_R * t / SR) for t in range(n)]
    return [left, right]


def slider_line(ir=None, wet=0.0, dry=-60.0, pre=0.0, length=100.0,
                hpf=20.0, lpf=20000.0, mdep=0.0, mrate=0.35, mons=0.0):
    # Slider layout: 1 = IR file, 2 = wet dB, 3 = dry dB, 4 = pre-delay ms,
    # 5 = IR length %, 6 = wet HPF Hz, 7 = wet LPF Hz, 8 = modulation depth %,
    # 9 = modulation rate Hz, 10 = modulation onset ms (0 = auto).
    # ir: file path RELATIVE to the slider's directory (Data/ReverbIRs).
    # Subdirectories are supported and serialize with the subpath, exactly as
    # REAPER writes them: "Bricasti M7/1 Halls 01 Large Hall, 48K.wav".
    #
    # mdep defaults to 0 and NOT to the plugin's own default: an undefined
    # slider takes the plugin default, which ships modulation ON, and every
    # test below was written against the unmodulated path. Pinning it at 0 here
    # turns all of them into bypass-null canaries - if the rotation ever leaks
    # into the Off state, they stop matching to 1.5e-08.
    vals = [('"%s"' % ir) if ir else "-", "%.6f" % wet, "%.6f" % dry,
            "%.6f" % pre, "%.6f" % length, "%.6f" % hpf, "%.6f" % lpf,
            "%.6f" % mdep, "%.6f" % mrate, "%.6f" % mons]
    vals += ["-"] * (64 - len(vals))
    return " ".join(vals)


def ser_block(path):
    """<JS_SER> payload selecting an IR by path, as the built-in browser saves
    it: 4-byte LE length (including the terminator) then the NUL-terminated
    string. Restoring this must override slider1."""
    raw = struct.pack("<i", len(path) + 1) + path.encode() + b"\x00"
    return base64.b64encode(raw).decode()


def make_rpp(path, sliders, out_wav, input_wav=None, srate=SR,
             in_len=IN_LEN, ser=None, fx="Magnolius_ConvolutionReverb.jsfx"):
    # RENDER_RANGE mode 1 is "entire project", so the render length is the item
    # length plus the ~1 s tail REAPER adds - NOT anything this function can
    # set. There used to be a `length` argument wired into the range end field,
    # which mode 1 ignores: every render came out at in_len + 1 s whatever it
    # said. To render more audio, pass a longer in_len (and an input file at
    # least that long).
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
    rpp = """<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000
  SAMPLERATE %d 0 0
  TEMPO 120 4 4
  RENDER_FILE "%s"
  RENDER_PATTERN ""
  RENDER_FMT 0 2 %d
  RENDER_1X 0
  RENDER_RANGE 1 0 0 18 1000
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
%s    >
%s  >
>
""" % (srate, out_wav, srate, RENDER_CFG, fx, sliders,
       ("      <JS_SER\n        %s\n      >\n" % ser) if ser else "", item)
    with open(path, "w") as f:
        f.write(rpp)


def render(name, sliders, with_input=True, srate=SR,
           input_name="input.wav", in_len=IN_LEN, ser=None,
           fx="Magnolius_ConvolutionReverb.jsfx"):
    """Render and return (channels, wall_seconds). Output is in_len + ~1 s."""
    out_wav = os.path.join(WORK, name + ".wav")
    rpp = os.path.join(WORK, name + ".rpp")
    if os.path.exists(out_wav):
        os.remove(out_wav)
    make_rpp(rpp, sliders, out_wav,
             input_wav=os.path.join(WORK, input_name) if with_input else None,
             srate=srate, in_len=in_len, ser=ser, fx=fx)
    t0 = time.time()
    subprocess.run(["reaper", "-newinst", "-nosplash", "-renderproject", rpp],
                   check=True, timeout=300,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dt = time.time() - t0
    if not os.path.exists(out_wav):
        raise RuntimeError("render produced no output: " + out_wav)
    sr, chans = read_wav(out_wav)
    return chans, dt


# ---- filter-test tone: two exact DFT bins of the analysis window, so a plain
# rectangular-window DFT has zero leakage and needs no windowing correction.
FILT_N = 16384          # analysis window length
FILT_A0 = 24000         # analysis window start (past convolver startup)
BIN_LO, BIN_HI = 68, 1707
F_LO = BIN_LO * SR / FILT_N     # 199.22 Hz
F_HI = BIN_HI * SR / FILT_N     # 5001.46 Hz


def filt_channels():
    n = int(SR * IN_LEN)
    ch = [0.25 * math.sin(2 * math.pi * F_LO * t / SR) +
          0.25 * math.sin(2 * math.pi * F_HI * t / SR) for t in range(n)]
    return [ch, list(ch)]


def bin_amp(x, k, a=FILT_A0, n=FILT_N):
    """Amplitude of DFT bin k over x[a:a+n] (exact for an integer-period tone)."""
    re = im = 0.0
    for i in range(n):
        w = 2 * math.pi * k * i / n
        re += x[a + i] * math.cos(w)
        im -= x[a + i] * math.sin(w)
    return 2.0 * math.sqrt(re * re + im * im) / n


def biquad(kind, fc, sr):
    """RBJ 2-pole Butterworth (Q = 1/sqrt(2)) — mirrors biq_design() in the
    .jsfx, including its srate*0.45 Nyquist clamp. Edit both together."""
    fc = min(fc, sr * 0.45)
    w0 = 2 * math.pi * fc / sr
    cs, sn = math.cos(w0), math.sin(w0)
    alpha = sn / 1.41421356
    a0 = 1 + alpha
    if kind == "hp":
        b0, b1, b2 = (1 + cs) / 2 / a0, -(1 + cs) / a0, (1 + cs) / 2 / a0
    else:
        b0, b1, b2 = (1 - cs) / 2 / a0, (1 - cs) / a0, (1 - cs) / 2 / a0
    return b0, b1, b2, -2 * cs / a0, (1 - alpha) / a0


def biquad_mag(coef, f, sr):
    b0, b1, b2, a1, a2 = coef
    w = 2 * math.pi * f / sr
    c1, s1 = math.cos(w), -math.sin(w)
    c2, s2 = math.cos(2 * w), -math.sin(2 * w)
    nr, ni = b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2
    dr, di = 1 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2
    return math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di))


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


def t_dryonly():
    # dry 0 / wet off with unity IR: output == input. Verifies the dry path
    # and that its CONV_P alignment delay is PDC-compensated (offline render).
    out, _ = render("dryonly", slider_line(
        ir="test_unity4.wav", wet=-60.0, dry=0.0))
    ok, det = check_matches(out, IN_L, IN_R)
    report("dryonly", ok, det)


def t_unity():
    # unit-impulse IR (LL,RR), wet only: wet output == input at exactly 0 dB.
    # This proves @init compiled AND the FFT scaling (1/N) is right.
    out, _ = render("unity", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R)
    det += "  wet/in rms ratio L=%.4f" % (rms(out[0], REG0, REG1) /
                                          max(rms(IN_L, REG0, REG1), 1e-12))
    report("unity", ok, det)


def t_swap():
    # cross-only IR (LR,RL): output channels must be swapped. Passthrough
    # cannot fake this.
    out, _ = render("swap", slider_line(
        ir="test_swap4.wav", wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_R, IN_L)
    report("swap", ok, det)


def t_delay5k():
    # impulse at 5000 crosses a partition boundary (P=2048): tests FDL indexing.
    out, _ = render("delay5k", slider_line(
        ir="test_delay5k4.wav", wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R, delay=5000)
    report("delay5k", ok, det)


def t_stereo2ch():
    # 2-ch IR = parallel stereo (LL,RR): wet output == input.
    out, _ = render("stereo2ch", slider_line(
        ir="test_unity2.wav", wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R)
    report("stereo2ch", ok, det)


def t_resample():
    # 96k IR with impulse at 9600 -> 4800-sample echo in a 48k project.
    # Linear resampling of a lone impulse is exact only when it lands on an
    # output grid point (9600/2 does), so a tight tolerance still applies.
    out, _ = render("resample", slider_line(
        ir="test_delay96k.wav", wet=0.0, dry=-60.0))
    ok, det = check_matches(out, IN_L, IN_R, delay=4800, tol=0.001)
    report("resample", ok, det)


def t_drywet():
    # dry 0 / wet 0 with unity IR: dry + wet = 2x input (checks mix + alignment)
    out, _ = render("drywet", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=0.0))
    ref_l = [2 * v for v in IN_L]
    ref_r = [2 * v for v in IN_R]
    ok, det = check_matches(out, ref_l, ref_r)
    report("drywet", ok, det)


def t_predelay():
    # 100 ms pre-delay with a unit-impulse IR: the wet path must come out
    # delayed by exactly 4800 samples and otherwise untouched. Pre-delay is
    # internal, so PDC must NOT change (the dry-aligned path already proves
    # reported latency; here a wrong pdc_delay would shift the whole render).
    out, _ = render("predelay", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0, pre=100.0))
    ok, det = check_matches(out, IN_L, IN_R, delay=4800)
    report("predelay", ok, det)


def t_len200():
    # IR length 200% on an impulse-at-5000 IR: resampling stretch puts it at
    # 10000. Linear interpolation spreads it over 3 taps (0.25, 0.5, 0.25 of
    # the source amplitude) which energy-normalize to 0.4082, 0.8165, 0.4082 —
    # a symmetric (linear-phase) 3-tap FIR, so a sine comes out scaled by
    # 0.8165*(1+cos w) at the SAME 10000-sample delay.
    out, _ = render("len200", slider_line(
        ir="test_delay5k4.wav", wet=0.0, dry=-60.0, length=200.0))
    sc = 1.0 / math.sqrt(0.375)          # energy normalization of the 3 taps
    gl = 0.5 * sc * (1 + math.cos(2 * math.pi * FREQ_L / SR))
    gr = 0.5 * sc * (1 + math.cos(2 * math.pi * FREQ_R / SR))
    ok, det = check_matches(out, [gl * v for v in IN_L], [gr * v for v in IN_R],
                            delay=10000, tol=0.001)
    det += "  gain L=%.4f R=%.4f" % (gl, gr)
    report("len200", ok, det)


def t_len50():
    # IR length 50%: ir_ratio = 2, so the box-average (anti-alias) path runs.
    # The impulse at 5000 maps onto exactly one output frame, 2500, and
    # energy normalization restores unity gain — a clean 2500-sample delay.
    out, _ = render("len50", slider_line(
        ir="test_delay5k4.wav", wet=0.0, dry=-60.0, length=50.0))
    ok, det = check_matches(out, IN_L, IN_R, delay=2500)
    report("len50", ok, det)


def t_hpf():
    # 12 dB/oct wet high-pass at 1 kHz. Measured against a filters-off render
    # of the same signal, so the convolver's own scaling cancels; the target
    # comes from the biquad design, not from an idealized analog response.
    ref, _ = render("hpf_off", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0), input_name="filt.wav")
    out, _ = render("hpf_on", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0, hpf=1000.0),
        input_name="filt.wav")
    got_lo = bin_amp(out[0], BIN_LO) / bin_amp(ref[0], BIN_LO)
    got_hi = bin_amp(out[0], BIN_HI) / bin_amp(ref[0], BIN_HI)
    coef = biquad("hp", 1000.0, SR)
    exp_lo = biquad_mag(coef, F_LO, SR)
    exp_hi = biquad_mag(coef, F_HI, SR)
    ok = abs(got_lo - exp_lo) < 0.01 * max(exp_lo, 0.02) + 0.002 and \
         abs(got_hi - exp_hi) < 0.01
    report("hpf", ok, "%.0fHz %.4f (exp %.4f)  %.0fHz %.4f (exp %.4f)"
           % (F_LO, got_lo, exp_lo, F_HI, got_hi, exp_hi))


def t_lpf():
    # 12 dB/oct wet low-pass at 1 kHz, same method.
    ref, _ = render("lpf_off", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0), input_name="filt.wav")
    out, _ = render("lpf_on", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0, lpf=1000.0),
        input_name="filt.wav")
    got_lo = bin_amp(out[0], BIN_LO) / bin_amp(ref[0], BIN_LO)
    got_hi = bin_amp(out[0], BIN_HI) / bin_amp(ref[0], BIN_HI)
    coef = biquad("lp", 1000.0, SR)
    exp_lo = biquad_mag(coef, F_LO, SR)
    exp_hi = biquad_mag(coef, F_HI, SR)
    ok = abs(got_lo - exp_lo) < 0.01 and \
         abs(got_hi - exp_hi) < 0.01 * max(exp_hi, 0.02) + 0.002
    report("lpf", ok, "%.0fHz %.4f (exp %.4f)  %.0fHz %.4f (exp %.4f)"
           % (F_LO, got_lo, exp_lo, F_HI, got_hi, exp_hi))


def t_dryfilter():
    # The filters are wet-only: with wet muted and dry open, a 1 kHz low-pass
    # must not touch the output at all. Guards against ever moving the biquads
    # onto the summed signal.
    out, _ = render("dryfilter", slider_line(
        ir="test_unity4.wav", wet=-60.0, dry=0.0, lpf=1000.0, hpf=500.0))
    ok, det = check_matches(out, IN_L, IN_R)
    report("dryfilter", ok, det)


def t_serpath():
    # Canary for the built-in browser's load path: slider1 points at the unity
    # IR, but a serialized browser selection names the CHANNEL-SWAP IR. The
    # output must be swapped — which proves @serialize restored the path AND
    # that file_open(#string) loaded it in preference to the file slider.
    out, _ = render("serpath", slider_line(
        ir="test_unity4.wav", wet=0.0, dry=-60.0),
        ser=ser_block("test_swap4.wav"))
    ok, det = check_matches(out, IN_R, IN_L)
    report("serpath", ok, det)


RES = os.path.expanduser("~/.config/REAPER")
IDX_PATH = os.path.join(RES, "Data", "ConvReverbIRs.idx")
DBG_FX = "_ConvRvbDbg.jsfx"

# Time-multiplexed debug read-out appended to the END of @sample. Every value
# stays well inside +-1: REAPER zeroes a track's entire render if an FX emits
# samples far outside that range.
DBG_TAIL = """
dbg_sl = floor(dbg_cnt / 4096) % 5;   // cycles, so pre-roll cannot eat a slot
spl0 = dbg_sl * 0.01;
spl1 = (dbg_sl == 0 ? nir : dbg_sl == 1 ? nfld : dbg_sl == 2 ? IRLEN[0] :
        dbg_sl == 3 ? FLDCNT[1] : dbg_sl == 4 ? idx_ready : 0) * 0.001;
dbg_cnt += 1;
"""


# Onset detector read-out. ons_ms is a multiple of the 2 ms hop (or a 1 ms
# half-step, from the 4-channel median), so 3 decimal places of a value scaled
# by 0.001 is plenty to recover it exactly.
ONS_TAIL = """
dbg_sl = floor(dbg_cnt / 4096) % 5;
spl0 = dbg_sl * 0.01;
spl1 = (dbg_sl == 0 ? ons_ms : dbg_sl == 1 ? ons_pre_ms :
        dbg_sl == 2 ? ons_ok : dbg_sl == 3 ? ons_uncertain :
        dbg_sl == 4 ? ir_nparts : 0) * 0.001;
dbg_cnt += 1;
"""


def build_debug_fx(tail=DBG_TAIL):
    """Generate the debug build from the REAL source on every run, so the
    tested code cannot drift from the shipped code."""
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "Magnolius_ConvolutionReverb.jsfx")).read()
    marker = "\n@gfx "
    assert marker in src, "no @gfx section to insert before"
    i = src.index(marker)
    out = src[:i] + "\n" + tail + src[i:]
    with open(os.path.join(RES, "Effects", DBG_FX), "w") as f:
        f.write(out)


def read_slots(out, nslots):
    """Decode a time-multiplexed debug read-out into {slot: value}.

    The debug counter free-runs from the plugin's first sample, which is NOT
    the first sample of the render range, so the slot number is read off ch0
    rather than assumed from an offset.
    """
    got = {}
    for i in range(len(out[0])):
        slot = round(out[0][i] * 100)
        if 0 <= slot < nslots:
            got.setdefault(slot, out[1][i] * 1000.0)
    return got


def t_onset():
    # The mixing-time detector, read back from the audio thread and checked
    # against tools/ir_onset.py on the same file. Those two are separate
    # implementations of the same algorithm and the .jsfx comment promises they
    # agree; this is what holds them to it.
    #
    # test_mix60.wav has a DESIGNED mixing time: sparse discrete reflections
    # for exactly 60 ms after the direct sound, then continuous noise. So the
    # reference is itself checked against a known answer, not just echoed.
    try:
        build_debug_fx(ONS_TAIL)
        cases = [("test_mix60.wav", 60.0, 5.0),   # designed onset, designed pre
                 ("test_hall4.wav", 10.0, 0.0)]   # noise from frame 0 -> clamped
        bad = []
        det = []
        for name, want_ms, want_pre in cases:
            ref = ir_onset.analyse(
                os.path.join(RES, "Data", "ReverbIRs", name))
            out, _ = render("onset_" + name[:-4], slider_line(ir=name),
                            with_input=False, fx=DBG_FX)
            got = read_slots(out, 5)
            ms, pre, ok = got.get(0), got.get(1), got.get(2)
            if ms is None or pre is None:
                bad.append("%s: no read-out" % name)
                continue
            det.append("%s ms=%.1f pre=%.1f ok=%.0f" % (name, ms, pre, ok))
            if abs(ms - ref["onset_ms"]) > 0.6:
                bad.append("%s: plugin %.1f != reference %.1f"
                           % (name, ms, ref["onset_ms"]))
            if abs(ms - want_ms) > 2.1:
                bad.append("%s: %.1f ms, designed %.1f" % (name, ms, want_ms))
            if abs(pre - want_pre) > 0.6:
                bad.append("%s: pre-delay %.1f, designed %.1f"
                           % (name, pre, want_pre))
        report("onset", not bad, "  ".join(det) + ("  " + "; ".join(bad) if bad else ""))
    finally:
        if not os.environ.get("CONVRVB_KEEP_DBG"):
            try:
                os.remove(os.path.join(RES, "Effects", DBG_FX))
            except OSError:
                pass


def t_index():
    # Parses a KNOWN index file and reads back what idx_load() built. This is
    # the only headless check of the IR browser's data: @gfx never runs in an
    # offline render, so nothing else here can catch an index-parser
    # regression. The user's real index is saved and restored around it.
    had = os.path.exists(IDX_PATH)
    backup = open(IDX_PATH, "rb").read() if had else None
    try:
        with open(IDX_PATH, "w") as f:
            # 3 files over 2 folders (root + "sub"), one blank line and one
            # CRLF line ending, both of which the parser must survive
            f.write("test_unity4.wav\n\nsub/one.wav\r\nsub/two.wav\n")
        build_debug_fx()
        out, _ = render("index", slider_line(ir="test_unity4.wav"),
                        with_input=False, fx=DBG_FX)
        # The debug counter free-runs from the plugin's first sample, which is
        # NOT the first sample of the render range (REAPER runs blocks before
        # it), so slot boundaries are shifted by an unknown pre-roll. Read the
        # slot number the plugin emits on ch0 instead of assuming offsets.
        got = {}
        for i in range(len(out[0])):
            slot = round(out[0][i] * 100)
            if 0 <= slot <= 4:
                got.setdefault(slot, round(out[1][i] * 1000))
        exp = {0: 3, 1: 2, 2: len("test_unity4.wav"), 3: 2, 4: 1}
        ok = all(got.get(k) == v for k, v in exp.items())
        report("index", ok, "nir=%s nfld=%s len0=%s fldcnt[1]=%s ready=%s "
                            "(expected %s)" % (got.get(0), got.get(1),
                                               got.get(2), got.get(3),
                                               got.get(4), list(exp.values())))
    finally:
        if not os.environ.get("CONVRVB_KEEP_DBG"):
            try:
                os.remove(os.path.join(RES, "Effects", DBG_FX))
            except OSError:
                pass
        if had:
            open(IDX_PATH, "wb").write(backup)
        elif os.path.exists(IDX_PATH):
            os.remove(IDX_PATH)


# ---- late-tail modulation -------------------------------------------------
# An impulse input is what makes the early/late split visible. With a
# continuous input every output sample is a sum over the WHOLE IR, so "before
# the onset" means nothing; with a single click at IMP_AT the output is the IR
# itself, and output sample IMP_AT + n comes from IR sample n alone.
IMP_AT = 4800
MIX60_ONSET = 65.0       # test_mix60: 5 ms pre-delay + 60 ms mixing time
MIX60_XF = 30.0          # MOD_XF_MS in the plugin
PAN_LEN = 6.0            # seconds: many LFO cycles at the top rate


def impulse_channels(n=None):
    n = n or int(SR * IN_LEN)
    ch = [0.0] * n
    ch[IMP_AT] = 0.5
    return [ch, list(ch)]


def t_modearly():
    # THE claim the whole design rests on: modulation must not touch the early
    # reflections. Rendered as the IR itself (impulse in), the region from the
    # click to the start of the crossfade has to be bit-identical with the
    # depth at 0 and at 100, while the region past the crossfade must NOT be -
    # otherwise the test would pass just as well on a build where modulation
    # never engaged.
    sl = dict(ir="test_mix60.wav", wet=0.0, dry=-60.0)
    off, _ = render("modearly_off", slider_line(mdep=0.0, **sl),
                    input_name="impulse.wav")
    on, _ = render("modearly_on", slider_line(mdep=100.0, **sl),
                   input_name="impulse.wav")
    a = IMP_AT + int(SR * (MIX60_ONSET - MIX60_XF / 2) * 0.001)
    b = IMP_AT + int(SR * (MIX60_ONSET + MIX60_XF / 2) * 0.001)
    early = max(maxdiff(off[0][:a], on[0][:a]), maxdiff(off[1][:a], on[1][:a]))
    late = max(maxdiff(off[0][b:], on[0][b:]), maxdiff(off[1][b:], on[1][b:]))
    peak = max(abs(v) for v in off[0])
    ok = early < 1e-6 and late > peak * 0.005
    report("modearly", ok,
           "early(0..%d) diff=%.2e (must be ~0)  late diff=%.2e "
           "(must be >%.2e)" % (a, early, late, peak * 0.005))


def t_moddet():
    # Same render twice at full depth: bit-identical, or a bounce does not
    # match the last bounce. EEL2's rand() cannot be seeded, which is why the
    # random end runs off a Park-Miller LCG seeded from the IR.
    sl = slider_line(ir="test_hall4.wav", wet=0.0, dry=-60.0, mdep=100.0)
    a, _ = render("moddet_a", sl)
    b, _ = render("moddet_b", sl)
    d = max(maxdiff(a[0], b[0]), maxdiff(a[1], b[1]))
    report("moddet", d == 0.0, "maxdiff between two identical renders = %.2e" % d)


def hf_rms(x, a, b):
    """RMS of the first difference: a 6 dB/oct high-frequency emphasis.

    Cheap stand-in for a band analysis, and the thing that actually catches a
    lossy fractional-delay interpolator. Broadband RMS barely moved when a
    4-point Lagrange was costing -2.5 dB above 15 kHz; this moves plainly.
    """
    return math.sqrt(sum((x[i] - x[i - 1]) ** 2
                         for i in range(a, b)) / max(b - a, 1))


def t_modlevel():
    # The premise of the whole thing: this is PHASE movement, so it must not
    # change how loud the reverb is or what it sounds like spectrally. The
    # delay lines interpolate with a first-order allpass for exactly this
    # reason - unit magnitude at every frequency, where linear and Lagrange
    # interpolators both null at Nyquist and sweep that null with the LFO.
    # test_hall4 is full-band noise, which is the worst case for any of them.
    sl = dict(ir="test_hall4.wav", wet=0.0, dry=-60.0)
    off, _ = render("modlevel_off", slider_line(mdep=0.0, **sl))
    on, _ = render("modlevel_on", slider_line(mdep=100.0, **sl))
    d_st = 20 * math.log10(rms(on[0], REG0, REG1) /
                           max(rms(off[0], REG0, REG1), 1e-12))
    d_hf = 20 * math.log10(hf_rms(on[0], REG0, REG1) /
                           max(hf_rms(off[0], REG0, REG1), 1e-12))
    mono_off = [0.5 * (l + r) for l, r in zip(off[0][REG0:REG1], off[1][REG0:REG1])]
    mono_on = [0.5 * (l + r) for l, r in zip(on[0][REG0:REG1], on[1][REG0:REG1])]
    d_mono = 20 * math.log10(rms(mono_on) / max(rms(mono_off), 1e-12))
    ok = abs(d_st) < 0.3 and abs(d_hf) < 0.5 and abs(d_mono) < 1.0
    report("modlevel", ok, "level %+.2f dB (<0.3)  HF-weighted %+.2f dB (<0.5)"
                           "  mono fold %+.2f dB (<1.0)" % (d_st, d_hf, d_mono))


def t_modshort():
    # Under the 500 ms floor there is no diffuse tail worth moving, so the
    # modulator must switch itself off entirely - full depth has to null
    # against no depth. Same guard that keeps cabinet impulses out of it.
    sl = dict(ir="test_short4.wav", wet=0.0, dry=-60.0)
    off, _ = render("modshort_off", slider_line(mdep=0.0, **sl))
    on, _ = render("modshort_on", slider_line(mdep=100.0, **sl))
    d = max(maxdiff(off[0], on[0]), maxdiff(off[1], on[1]))
    report("modshort", d == 0.0, "300 ms IR, depth 0 vs 100: maxdiff %.2e" % d)


def t_modpan():
    # Position stability: a hard-panned source must not move as depth rises.
    # test_ts4 is used rather than test_hall4 because its four channels carry
    # real inter-channel relationships; four independent noise channels have no
    # image to hold still in the first place.
    #
    # Honest note: this passes on a build deliberately repaired to pair the
    # LFOs by OUTPUT channel instead of by input path, which the brief warns
    # against. Measured either way, the image held (L/R phase spread under 1
    # degree over 6 s at the top rate). Pairing by input path is kept because
    # it is the principled choice and costs nothing, not because this test
    # demonstrates it matters - in this architecture the delay lands on each
    # path's OUTPUT, and a hard-panned source only excites one input side, so
    # both pairings move that side's two paths coherently enough.
    # Run at the top rate over a long input so the measurement spans many LFO
    # cycles: the quantity of interest is how far the image WANDERS, and a
    # window shorter than one cycle just samples an arbitrary LFO phase.
    sl = dict(ir="test_ts4.wav", wet=0.0, dry=-60.0, mrate=2.0)
    off, _ = render("modpan_off", slider_line(mdep=0.0, **sl),
                    input_name="panlong.wav", in_len=PAN_LEN)
    on, _ = render("modpan_on", slider_line(mdep=100.0, **sl),
                   input_name="panlong.wav", in_len=PAN_LEN)

    def balance_spread(x):
        """Std deviation, in dB, of the block-wise L/R balance."""
        blk = 4800
        vals = []
        for a in range(REG0, int(SR * PAN_LEN) - blk, blk):
            l, r = rms(x[0], a, a + blk), rms(x[1], a, a + blk)
            if l > 1e-9 and r > 1e-9:
                vals.append(20 * math.log10(l / r))
        m = sum(vals) / len(vals)
        return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))

    def fold(x):
        n = int(SR * PAN_LEN)
        return [0.5 * (l + r) for l, r in zip(x[0][REG0:n], x[1][REG0:n])]

    d_mono = 20 * math.log10(rms(fold(on)) / max(rms(fold(off)), 1e-12))
    s_off, s_on = balance_spread(off), balance_spread(on)
    ok = abs(d_mono) < 1.0 and (s_on - s_off) < 0.5
    report("modpan", ok, "hard-left: mono fold %+.2f dB (<1.0)  image wander "
                         "%.2f -> %.2f dB rms (rise <0.5)"
           % (d_mono, s_off, s_on))


def t_modonset():
    # The onset override has to move the split. Forcing it late (180 ms) must
    # leave more of the IR unmodulated than the auto value (65 ms) does, so the
    # first difference between a modulated and an unmodulated render moves
    # later by roughly the amount the override moved.
    sl = dict(ir="test_mix60.wav", wet=0.0, dry=-60.0)
    off, _ = render("modonset_off", slider_line(mdep=0.0, **sl),
                    input_name="impulse.wav")
    firsts = {}
    for mons in (0.0, 180.0):
        on, _ = render("modonset_%d" % mons, slider_line(
            mdep=100.0, mons=mons, **sl), input_name="impulse.wav")
        peak = max(abs(v) for v in off[0])
        first = None
        for i in range(IMP_AT, len(on[0])):
            if abs(on[0][i] - off[0][i]) > peak * 0.001:
                first = (i - IMP_AT) * 1000.0 / SR
                break
        firsts[mons] = first
    auto, forced = firsts[0.0], firsts[180.0]
    ok = (auto is not None and forced is not None and
          abs(auto - (MIX60_ONSET - MIX60_XF / 2)) < 12.0 and
          forced > auto + 80.0)
    report("modonset", ok, "auto split at %s ms, override 180 ms split at %s ms"
           % ("%.0f" % auto if auto else "-",
              "%.0f" % forced if forced else "-"))


def t_case():
    # EEL2 identifiers are CASE-INSENSITIVE, so a constant NAME and a runtime
    # variable `name` are one variable. That silently broke two things here: a
    # `mod_sub` counter decremented the `MOD_SUB` interval until the LFO ran
    # every sample and divided by a negative, and `pre_xf` zeroed `PRE_XF` so
    # the pre-delay crossfade never ran at all in 1.3. Neither produced an
    # error anywhere, and no render test caught either one.
    #
    # Only the code below @init is scanned: slider labels above it are prose
    # and legitimately contain words like Reverb and Wet. Comments, strings and
    # 'c' character literals are stripped for the same reason.
    #
    # Function parameters and local() names are excluded: EEL2 scopes those per
    # function, so g_decay's `S` and mod_lfo's `s` are genuinely separate
    # storage. That does leave one gap - a name that is a local in one function
    # and a global elsewhere is still a hazard and will not be reported - but
    # the bugs that actually happened here were both global-vs-global.
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "Magnolius_ConvolutionReverb.jsfx")).read()
    src = src[src.index("\n@init"):]
    src = re.sub(r'//[^\n]*', '', src)
    src = re.sub(r'"[^"]*"', '', src)
    src = re.sub(r"'[^']*'", '', src)
    declared = set()
    for m in re.finditer(r'function\s+[A-Za-z_]\w*\s*\(([^)]*)\)'
                         r'(?:\s*local\s*\(([^)]*)\))?', src):
        for grp in m.groups():
            if grp:
                declared.update(n.strip() for n in grp.split(","))
    seen = {}
    for name in re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', src):
        if name not in declared:
            seen.setdefault(name.lower(), set()).add(name)
    bad = sorted(k for k, v in seen.items() if len(v) > 1)
    report("case", not bad,
           "no global identifier differs only by case" if not bad else
           "collide: " + ", ".join("/".join(sorted(seen[k])) for k in bad))


CPU_LEN = 20.0          # seconds of audio for the long leg of the measurement


def t_cpu():
    # Cost per second of audio for the worst realistic IR, with REAPER's ~4 s
    # of process startup differenced out by rendering two lengths. That ratio
    # is the number that matters for live playback: 1.0 is one core entirely
    # spent on one instance, and the 192-partition cap is ~1.5x this IR.
    #
    # It used to render a fixed 2 s and call it 3 s, because the old `length`
    # argument fed a RENDER_RANGE field that mode 1 ignores. The only lever on
    # render length is the item, hence the long input file.
    n = int(SR * CPU_LEN)
    ch = [AMP * math.sin(2 * math.pi * FREQ_L * t / SR) for t in range(n)]
    write_wav_f32(os.path.join(WORK, "cpulong.wav"), SR, [ch, list(ch)])
    cost = {}
    for dep in (0.0, 100.0):
        sl = slider_line(ir="test_hall4.wav", wet=0.0, dry=0.0, mdep=dep)
        out, t_short = render("cpu_s", sl, input_name="cpulong.wav", in_len=1.0)
        _, t_long = render("cpu_l", sl, input_name="cpulong.wav",
                           in_len=CPU_LEN)
        cost[dep] = (t_long - t_short) / (CPU_LEN - 1.0)
        if dep == 0.0:
            r = rms(out[0], REG0, REG1)
    over = 100.0 * (cost[100.0] / max(cost[0.0], 1e-9) - 1.0)
    report("cpu", r > 0.001 and cost[100.0] < 1.0,
           "5.4s IR: %.3f s/s unmodulated, %.3f s/s modulated (%+.0f%%, "
           "must stay <1.0), wet rms=%.4f"
           % (cost[0.0], cost[100.0], over, r))


ALL = [("dryonly", t_dryonly), ("unity", t_unity), ("swap", t_swap),
       ("delay5k", t_delay5k), ("stereo2ch", t_stereo2ch),
       ("resample", t_resample), ("drywet", t_drywet),
       ("predelay", t_predelay), ("len200", t_len200), ("len50", t_len50),
       ("hpf", t_hpf), ("lpf", t_lpf), ("dryfilter", t_dryfilter),
       ("serpath", t_serpath), ("index", t_index), ("onset", t_onset),
       ("modearly", t_modearly), ("moddet", t_moddet),
       ("modlevel", t_modlevel), ("modshort", t_modshort),
       ("modpan", t_modpan), ("modonset", t_modonset),
       ("case", t_case), ("cpu", t_cpu)]


def main():
    global IN_L, IN_R
    os.makedirs(WORK, exist_ok=True)
    IN_L, IN_R = input_channels()
    write_wav_f32(os.path.join(WORK, "input.wav"), SR, [IN_L, IN_R])
    write_wav_f32(os.path.join(WORK, "filt.wav"), SR, filt_channels())
    write_wav_f32(os.path.join(WORK, "impulse.wav"), SR, impulse_channels())
    # Hard-left BROADBAND noise. A tone here measures the comb the modulator
    # puts across frequency - which is the point of it - rather than whether
    # the tail survives a mono fold; only broadband material averages that out.
    # Seeded, so the fixture does not move between runs.
    n = int(SR * PAN_LEN)
    rnd = random.Random(3)
    write_wav_f32(os.path.join(WORK, "panlong.wav"), SR,
                  [[AMP * (rnd.random() * 2 - 1) for _ in range(n)], [0.0] * n])
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
