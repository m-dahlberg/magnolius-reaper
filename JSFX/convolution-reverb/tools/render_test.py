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
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav, write_wav_f32

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
                hpf=20.0, lpf=20000.0):
    # Slider layout: 1 = IR file, 2 = wet dB, 3 = dry dB, 4 = pre-delay ms,
    # 5 = IR length %, 6 = wet HPF Hz, 7 = wet LPF Hz.
    # ir: file path RELATIVE to the slider's directory (Data/ReverbIRs).
    # Subdirectories are supported and serialize with the subpath, exactly as
    # REAPER writes them: "Bricasti M7/1 Halls 01 Large Hall, 48K.wav".
    vals = [('"%s"' % ir) if ir else "-", "%.6f" % wet, "%.6f" % dry,
            "%.6f" % pre, "%.6f" % length, "%.6f" % hpf, "%.6f" % lpf]
    vals += ["-"] * (64 - len(vals))
    return " ".join(vals)


def ser_block(path):
    """<JS_SER> payload selecting an IR by path, as the built-in browser saves
    it: 4-byte LE length (including the terminator) then the NUL-terminated
    string. Restoring this must override slider1."""
    raw = struct.pack("<i", len(path) + 1) + path.encode() + b"\x00"
    return base64.b64encode(raw).decode()


def make_rpp(path, sliders, out_wav, input_wav=None, length=1.5, srate=SR,
             in_len=IN_LEN, ser=None, fx="Magnolius_ConvolutionReverb.jsfx"):
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
      <JS "%s" ""
        %s
      >
%s    >
%s  >
>
""" % (srate, out_wav, srate, length, RENDER_CFG, fx, sliders,
       ("      <JS_SER\n        %s\n      >\n" % ser) if ser else "", item)
    with open(path, "w") as f:
        f.write(rpp)


def render(name, sliders, with_input=True, length=1.5, srate=SR,
           input_name="input.wav", in_len=IN_LEN, ser=None,
           fx="Magnolius_ConvolutionReverb.jsfx"):
    out_wav = os.path.join(WORK, name + ".wav")
    rpp = os.path.join(WORK, name + ".rpp")
    if os.path.exists(out_wav):
        os.remove(out_wav)
    make_rpp(rpp, sliders, out_wav,
             input_wav=os.path.join(WORK, input_name) if with_input else None,
             length=length, srate=srate, in_len=in_len, ser=ser, fx=fx)
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


def build_debug_fx():
    """Generate the debug build from the REAL source on every run, so the
    tested code cannot drift from the shipped code."""
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "Magnolius_ConvolutionReverb.jsfx")).read()
    marker = "\n@gfx "
    assert marker in src, "no @gfx section to insert before"
    i = src.index(marker)
    out = src[:i] + "\n" + DBG_TAIL + src[i:]
    with open(os.path.join(RES, "Effects", DBG_FX), "w") as f:
        f.write(out)


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
                        with_input=False, length=1.2, fx=DBG_FX)
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


def t_cpu():
    # 5.4 s dense IR: no assertion, just render-time telemetry (render is
    # offline, so wall time >> real time would flag live-playback risk).
    out, dt = render("cpu", slider_line(
        ir="test_hall4.wav", wet=0.0, dry=0.0), length=3.0)
    r = rms(out[0], REG0, REG1)
    report("cpu", r > 0.001, "5.4s-IR render of 3.0s took %.1fs, wet rms=%.4f" % (dt, r))


ALL = [("dryonly", t_dryonly), ("unity", t_unity), ("swap", t_swap),
       ("delay5k", t_delay5k), ("stereo2ch", t_stereo2ch),
       ("resample", t_resample), ("drywet", t_drywet),
       ("predelay", t_predelay), ("len200", t_len200), ("len50", t_len50),
       ("hpf", t_hpf), ("lpf", t_lpf), ("dryfilter", t_dryfilter),
       ("serpath", t_serpath), ("index", t_index), ("cpu", t_cpu)]


def main():
    global IN_L, IN_R
    os.makedirs(WORK, exist_ok=True)
    IN_L, IN_R = input_channels()
    write_wav_f32(os.path.join(WORK, "input.wav"), SR, [IN_L, IN_R])
    write_wav_f32(os.path.join(WORK, "filt.wav"), SR, filt_channels())
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
