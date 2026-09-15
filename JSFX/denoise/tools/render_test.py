#!/usr/bin/env python3
"""Headless render-test harness for Magnolius_DeNoise.jsfx.

Renders a tiny REAPER project through the plugin with
`reaper -newinst -nosplash -renderproject` (works while a normal REAPER
instance is running) and checks the rendered audio with pure-Python analysis.

Adapted from ~/repos/PersonalSpace/perceptual-eq/tools/render_test.py.

Prerequisites:
  - Magnolius_DeNoise.jsfx symlinked as <resource>/Effects/Magnolius_DeNoise.jsfx

Usage:
  render_test.py               # run all tests
  render_test.py unity probe   # run selected tests
Work dir: ~/.cache/denoise-rendertest (override with DENOISE_TEST_DIR).
"""
import base64
import math
import os
import random
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav, write_wav_f32

WORK = os.environ.get("DENOISE_TEST_DIR",
                      os.path.expanduser("~/.cache/denoise-rendertest"))
SR = 48000
IN_LEN = 1.0  # seconds
FREQ_L, FREQ_R = 997.0, 1499.0
AMP = 0.4
# settled comparison region (skips latency edge + first-frame windowing)
REG0, REG1 = 24000, 45000

RENDER_CFG = base64.b64encode(b"evaw" + struct.pack("<i", 32)).decode()

SLIDER_NAMES = ["Mode", "Reduction dB", "Strength", "Smoothing",
                "Residual Listen", "FFT Size", "Reset Noise Profile",
                "Gate", "Gate Threshold dB", "Gate Attack ms", "Gate Hold ms",
                "Gate Release ms", "Gate Mode", "Expander Ratio",
                "Gate Auto Timing", "Residual Whitening %",
                "Musical Noise Smoothing NLM"]


def input_channels():
    n = int(SR * IN_LEN)
    left = [AMP * math.sin(2 * math.pi * FREQ_L * t / SR) for t in range(n)]
    right = [AMP * math.sin(2 * math.pi * FREQ_R * t / SR) for t in range(n)]
    return [left, right]


def slider_line(mode=0, reduction=0.0, strength=30.0, smoothing=50.0,
                residual=0, fftsel=1, reset=0, gate_on=0, gthresh=-50.0,
                gattack=5.0, ghold=100.0, grelease=200.0, gmode=0,
                gratio=3.0, gauto=0, whitening=0.0, nlm=0):
    vals = ["%d.000000" % mode, "%.6f" % reduction, "%.6f" % strength,
            "%.6f" % smoothing, "%d.000000" % residual,
            "%d.000000" % fftsel, "%d.000000" % reset,
            "%d.000000" % gate_on, "%.6f" % gthresh, "%.6f" % gattack,
            "%.6f" % ghold, "%.6f" % grelease, "%d.000000" % gmode,
            "%.6f" % gratio, "%d.000000" % gauto, "%.6f" % whitening,
            "%d.000000" % nlm]
    vals += ["-"] * 47
    return " ".join(vals)


def mode_env(points):
    """PARMENV automation for slider1 (Mode). points: [(time, value)],
    square shape so mode switches land exactly. Format confirmed against a
    REAPER-written chunk (values in slider units)."""
    pts = "\n".join("        PT %g %g 1" % (t, v) for t, v in points)
    return ('      <PARMENV 0 0 2 1 "Mode"\n'
            "        ACT 1 -1\n        VIS 1 1 1\n        ARM 0\n"
            "        DEFSHAPE 1 -1 -1\n%s\n      >" % pts)


def make_rpp(path, sliders, out_wav, input_wav=None, length=1.5, srate=SR,
             js_ser=None, in_len=IN_LEN, parmenv=None):
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
    if parmenv:
        ser += "\n" + parmenv
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
      <JS "Magnolius_DeNoise.jsfx" ""
        %s
      >%s
    >
%s  >
>
""" % (srate, out_wav, srate, length, RENDER_CFG, sliders, ser, item)
    with open(path, "w") as f:
        f.write(rpp)


def render(name, sliders, with_input=True, length=1.5, srate=SR,
           js_ser=None, input_name="input.wav", in_len=IN_LEN, parmenv=None):
    out_wav = os.path.join(WORK, name + ".wav")
    rpp = os.path.join(WORK, name + ".rpp")
    if os.path.exists(out_wav):
        os.remove(out_wav)
    make_rpp(rpp, sliders, out_wav,
             input_wav=os.path.join(WORK, input_name) if with_input else None,
             length=length, srate=srate, js_ser=js_ser, in_len=in_len,
             parmenv=parmenv)
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


def check_matches(out, ref_l, ref_r, delay=0, tol=0.0005):
    dl = maxdiff(out[0][REG0:REG1], ref_l[REG0 - delay:REG1 - delay])
    dr = maxdiff(out[1][REG0:REG1], ref_r[REG0 - delay:REG1 - delay])
    ok = dl < tol and dr < tol
    return ok, "maxdiff L=%.2e R=%.2e (tol %g)" % (dl, dr, tol)


RESULTS = []


def report(name, ok, detail):
    RESULTS.append((name, ok))
    print("%-14s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


IN_L, IN_R = None, None


def t_probe():
    # ReaScript ground truth: all 7 sliders parsed (a broken slider line or
    # label eats that slider and often the rest of the header, silently).
    probe_out = os.path.join(WORK, "probe_out.txt")
    if os.path.exists(probe_out):
        os.remove(probe_out)
    lua = os.path.join(WORK, "probe.lua")
    with open(lua, "w") as f:
        f.write("""
local tr = reaper.GetTrack(0, 0)
local fx = reaper.TrackFX_AddByName(tr, "Magnolius_DeNoise.jsfx", false, -1)
local n = reaper.TrackFX_GetNumParams(tr, fx)
local f = io.open("%s", "w")
f:write("fx=" .. tostring(fx) .. " nparams=" .. tostring(n) .. "\\n")
if fx >= 0 then
  for i = 0, n - 1 do
    local ok, name = reaper.TrackFX_GetParamName(tr, fx, i, "")
    f:write(i .. "=" .. tostring(name) .. "\\n")
  end
end
f:close()
reaper.Main_SaveProject(0, false)
reaper.Main_OnCommand(40004, 0)
""" % probe_out)
    rpp = os.path.join(WORK, "probe.rpp")
    make_rpp(rpp, slider_line(), os.path.join(WORK, "probe_unused.wav"))
    subprocess.run(["reaper", "-newinst", "-nosplash", rpp, lua],
                   check=True, timeout=120,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(probe_out):
        report("probe", False, "probe script produced no output")
        return
    with open(probe_out) as f:
        lines = f.read().splitlines()
    names = {}
    for ln in lines[1:]:
        if "=" in ln:
            i, name = ln.split("=", 1)
            names[int(i)] = name
    missing = [n for i, n in enumerate(SLIDER_NAMES) if names.get(i) != n]
    ok = not missing and "fx=-1" not in lines[0]
    report("probe", ok, lines[0] + (" missing=%s" % missing if missing else ""))


def t_unity():
    # Reduction 0, no profile: output must equal input (validates FFT scaling,
    # COLA normalization and PDC alignment in one shot).
    out, _ = render("unity", slider_line(reduction=0.0))
    ok, det = check_matches(out, IN_L, IN_R)
    report("unity", ok, det)


def t_unity_sizes():
    for fftsel, label in ((0, "1024"), (2, "4096")):
        out, _ = render("unity" + label, slider_line(reduction=0.0,
                                                     fftsel=fftsel))
        ok, det = check_matches(out, IN_L, IN_R)
        report("unity" + label, ok, det)


def t_impulse():
    # A lone impulse catches latency misreports the periodic sine cannot:
    # if actual latency != pdc_delay the peak lands off-position.
    n = int(SR * IN_LEN)
    imp = [0.0] * n
    imp[36000] = 0.9
    write_wav_f32(os.path.join(WORK, "imp_in.wav"), SR, [imp, imp])
    out, _ = render("impulse", slider_line(reduction=0.0),
                    input_name="imp_in.wav")
    peak_pos = max(range(30000, 44000), key=lambda i: abs(out[0][i]))
    d = maxdiff(out[0][30000:44000], imp[30000:44000])
    ok = peak_pos == 36000 and d < 0.0005
    report("impulse", ok, "peak at %d (want 36000), maxdiff=%.2e" % (peak_pos, d))


def t_residual_silence():
    # Non-vacuous guard: with gains at 1, residual listen must output silence.
    # A dead @init (silent passthrough) would output the full sine instead.
    out, _ = render("residual", slider_line(reduction=0.0, residual=1))
    r = rms(out[0], REG0, REG1)
    ok = r < 0.001
    report("residual", ok, "residual rms=%.2e (input rms %.3f)" %
           (r, rms(IN_L, REG0, REG1)))


def dft_db(x, f, sr=SR):
    re = im = 0.0
    for n, v in enumerate(x):
        w = 2 * math.pi * f * n / sr
        re += v * math.cos(w)
        im -= v * math.sin(w)
    return 20 * math.log10(max(math.sqrt(re * re + im * im), 1e-12))


def learn_input():
    """0-0.65s: white noise only; 0.65-1.45s: noise + 997 Hz tone."""
    rng = random.Random(1234)
    n = int(SR * 1.45)
    noise = [0.05 * rng.uniform(-1, 1) for _ in range(n)]
    sig = list(noise)
    for t in range(int(SR * 0.65), n):
        sig[t] += AMP * math.sin(2 * math.pi * FREQ_L * t / SR)
    return sig, noise


def t_learn():
    # Learn the profile from the noise-only lead-in (Mode envelope: Learn
    # until 0.5s, then Denoise), then check the noise floor drops while the
    # tone survives.
    sig, noise = learn_input()
    write_wav_f32(os.path.join(WORK, "learn_in.wav"), SR, [sig, sig])
    out, _ = render("learn", slider_line(reduction=40.0),
                    input_name="learn_in.wav", in_len=1.45,
                    parmenv=mode_env([(0, 1), (0.5, 0)]))
    # denoised noise-only region (after mode switch, before tone starts)
    a, b = int(SR * 0.53), int(SR * 0.63)
    drop_db = 20 * math.log10(max(rms(out[0], a, b), 1e-12) /
                              rms(noise, a, b))
    # tone region: same DFT window on input and output, leakage cancels
    ta, tb = int(SR * 1.0), int(SR * 1.4)
    tone_delta = dft_db(out[0][ta:tb], FREQ_L) - dft_db(sig[ta:tb], FREQ_L)
    # passthrough while learning
    la, lb = int(SR * 0.2), int(SR * 0.45)
    learn_diff = maxdiff(out[0][la:lb], sig[la:lb])
    # Berouti oversubtraction at default strength 30 measures ~-12 dB
    ok = drop_db < -8.0 and abs(tone_delta) < 1.5 and learn_diff < 0.0005
    report("learn", ok,
           "noise %.1f dB (want < -8), tone %+.2f dB (tol 1.5), "
           "learn-passthrough maxdiff=%.2e" % (drop_db, tone_delta, learn_diff))


def t_adaptive():
    # Adaptive mode for the whole render, no learning: SPP-MMSE must converge
    # on the stationary noise floor by itself, then hold while the tone plays.
    # Badly-seeded bins recover slowly (SPP stagnation cap), so give it a
    # realistic 2.5 s lead-in before measuring.
    # The signal is a 0.5 s tone BURST, not a sustained tone: the estimator
    # deliberately absorbs anything steady for seconds (a constant tone IS a
    # hum to an adaptive tracker), while speech-like bursts must survive.
    rng = random.Random(1234)
    n = int(SR * 3.5)
    noise = [0.05 * rng.uniform(-1, 1) for _ in range(n)]
    sig = list(noise)
    for t in range(int(SR * 2.5), int(SR * 3.0)):
        sig[t] += AMP * math.sin(2 * math.pi * FREQ_L * t / SR)
    write_wav_f32(os.path.join(WORK, "adaptive_in.wav"), SR, [sig, sig])
    out, _ = render("adaptive", slider_line(mode=2, reduction=40.0),
                    input_name="adaptive_in.wav", in_len=3.5, length=3.5)
    a, b = int(SR * 2.0), int(SR * 2.4)
    drop_db = 20 * math.log10(max(rms(out[0], a, b), 1e-12) /
                              rms(noise, a, b))
    ta, tb = int(SR * 2.55), int(SR * 2.95)
    tone_delta = dft_db(out[0][ta:tb], FREQ_L) - dft_db(sig[ta:tb], FREQ_L)
    ok = drop_db < -9.0 and abs(tone_delta) < 1.5
    report("adaptive", ok, "noise %.1f dB (want < -9), tone %+.2f dB (tol 1.5)"
           % (drop_db, tone_delta))


def js_ser_block(fft_size, learn_frames, prof_l, prof_r):
    """@serialize stream: fft_size, learn_frames, profaccL[2049],
    profaccR[2049] as raw 32-bit LE floats, base64 inside <JS_SER."""
    floats = [float(fft_size), float(learn_frames)] + prof_l + prof_r
    raw = struct.pack("<%df" % len(floats), *floats)
    b64 = base64.b64encode(raw).decode()
    lines = [b64[i:i + 128] for i in range(0, len(b64), 128)]
    return "<JS_SER\n" + "\n".join("        " + ln for ln in lines) + "\n      >"


def t_serialize():
    # Restore a synthetic flat profile through project state: the plugin must
    # denoise from the first samples without any learning pass. Expected bin
    # power for uniform noise of amplitude a through a periodic Hann window:
    # (a^2/3) * 0.375 * fft_size.
    rng = random.Random(4321)
    n = int(SR * 1.0)
    noise = [0.05 * rng.uniform(-1, 1) for _ in range(n)]
    write_wav_f32(os.path.join(WORK, "ser_in.wav"), SR, [noise, noise])
    frames = 40
    n0 = (0.05 ** 2 / 3.0) * 0.375 * 2048
    prof = [frames * n0] * 2049
    out, _ = render("serialize", slider_line(reduction=40.0),
                    input_name="ser_in.wav", in_len=1.0, length=1.0,
                    js_ser=js_ser_block(2048, frames, prof, prof))
    a, b = int(SR * 0.3), int(SR * 0.9)
    drop_db = 20 * math.log10(max(rms(out[0], a, b), 1e-12) /
                              rms(noise, a, b))
    ok = drop_db < -8.0
    report("serialize", ok, "noise %.1f dB (want < -8) from restored profile"
           % drop_db)


def t_whitening():
    # Residual whitening: learn a strongly LP-colored noise profile, denoise
    # at 20 dB with whitening 0 vs 100. The whitened floor is anchored to the
    # profile median, so the starved HF valleys get their floor raised: HF
    # residual must come up several dB while the (dominant LF) broadband
    # output stays well below the input.
    # Two cascaded one-pole LPs (-12 dB/oct): the anchor is the profile
    # MEDIAN, which for linear bins sits near 12 kHz, so probe well above it
    # at 20 kHz where the valley-fill lift is ~(20/12)^4 = +18 dB.
    rng = random.Random(99)
    n = int(SR * 1.1)
    a = math.exp(-2 * math.pi * 500.0 / SR)
    y1 = y2 = 0.0
    noise = []
    for _ in range(n):
        y1 = a * y1 + (1 - a) * 1.2 * rng.uniform(-1, 1)
        y2 = a * y2 + (1 - a) * y1
        noise.append(y2)
    write_wav_f32(os.path.join(WORK, "wht_in.wav"), SR, [noise, noise])
    env = mode_env([(0, 1), (0.5, 0)])  # learn until 0.5 s, then denoise
    # strength 100 crushes the Wiener gains so the residual rides the floor
    # under test instead of the oversubtraction tail
    out0, _ = render("wht0", slider_line(reduction=20.0, strength=100.0,
                                         whitening=0.0),
                     input_name="wht_in.wav", in_len=1.1, length=1.1,
                     parmenv=env)
    out100, _ = render("wht100", slider_line(reduction=20.0, strength=100.0,
                                             whitening=100.0),
                       input_name="wht_in.wav", in_len=1.1, length=1.1,
                       parmenv=env)
    # probe well above the median pivot (~15 kHz for this profile: the
    # discrete pole flattens toward Nyquist, compressing the HF contrast)
    a0, b0 = int(SR * 0.65), int(SR * 1.05)
    hf_delta = dft_db(out100[0][a0:b0], 23000.0) - dft_db(out0[0][a0:b0], 23000.0)
    bb_drop = 20 * math.log10(max(rms(out100[0], a0, b0), 1e-12) /
                              rms(noise, a0, b0))
    ok = hf_delta > 6.0 and bb_drop < -6.0
    report("whitening", ok, "HF residual %+.1f dB vs wht=0 (want > +6), "
           "broadband %.1f dB vs input (want < -6)" % (hf_delta, bb_drop))


def t_nlm_align():
    # NLM on, reduction 0, no profile: unity gains, but the signal now runs
    # through the 4-hop delayed-spectrum path and PDC reports 2*fft_size.
    # A lone impulse must land exactly on-position after compensation — a
    # dead delay path or a wrong PDC shifts it by fft_size. Also unity sine.
    n = int(SR * IN_LEN)
    imp = [0.0] * n
    imp[36000] = 0.9
    write_wav_f32(os.path.join(WORK, "imp_in.wav"), SR, [imp, imp])
    out, _ = render("nlmimp", slider_line(reduction=0.0, nlm=1),
                    input_name="imp_in.wav")
    peak_pos = max(range(30000, 44000), key=lambda i: abs(out[0][i]))
    d = maxdiff(out[0][30000:44000], imp[30000:44000])
    out2, _ = render("nlmunity", slider_line(reduction=0.0, nlm=1))
    ok2, det2 = check_matches(out2, IN_L, IN_R)
    ok = peak_pos == 36000 and d < 0.0005 and ok2
    report("nlmalign", ok, "peak at %d (want 36000), maxdiff=%.2e; sine %s"
           % (peak_pos, d, det2))


def flutter_db(x, a, b, freqs, win=960):
    """Mean over freqs of the temporal std (dB) of short-window DFT
    magnitudes: a direct musical-noise ('watery flutter') metric."""
    stds = []
    for f in freqs:
        series = []
        pos = a
        while pos + win <= b:
            series.append(dft_db(x[pos:pos + win], f))
            pos += win
        m = sum(series) / len(series)
        stds.append(math.sqrt(sum((v - m) ** 2 for v in series) / len(series)))
    return sum(stds) / len(stds)


def t_nlm_flutter():
    # Learn a white-noise profile, then denoise the noise bed hard
    # (40 dB / strength 50): per-bin gains chatter between floor and open,
    # which IS the watery artifact. NLM-smoothed SNR must cut the flutter
    # while keeping a comparable broadband reduction depth.
    rng = random.Random(4242)
    n = int(SR * 1.5)
    noise = [0.05 * rng.uniform(-1, 1) for _ in range(n)]
    write_wav_f32(os.path.join(WORK, "flut_in.wav"), SR, [noise, noise])
    # smoothing 80 -> h = 2.5; the NLM distance threshold 4*(h*freq_scale)^2
    # only admits noise-vs-noise patch matches (typical distance ~2*patch^2)
    # from the mid frequencies up, so probe 4-20 kHz where the reference
    # tuning actually smooths.
    env = mode_env([(0, 1), (0.5, 0)])
    base = dict(input_name="flut_in.wav", in_len=1.5, length=1.5, parmenv=env)
    out_off, _ = render("flutoff", slider_line(reduction=40.0, strength=50.0,
                                               smoothing=80.0), **base)
    out_eco, _ = render("fluteco", slider_line(reduction=40.0, strength=50.0,
                                               smoothing=80.0, nlm=1), **base)
    out_full, _ = render("flutfull", slider_line(reduction=40.0, strength=50.0,
                                                 smoothing=80.0, nlm=2), **base)
    a, b = int(SR * 0.8), int(SR * 1.4)
    freqs = [4000 * 1.13 ** i for i in range(14)]  # ~4 kHz .. 20 kHz
    fl_off = flutter_db(out_off[0], a, b, freqs)
    fl_eco = flutter_db(out_eco[0], a, b, freqs)
    fl_full = flutter_db(out_full[0], a, b, freqs)
    r_off = 20 * math.log10(max(rms(out_off[0], a, b), 1e-12) /
                            rms(noise, a, b))
    r_eco = 20 * math.log10(max(rms(out_eco[0], a, b), 1e-12) /
                            rms(noise, a, b))
    # NLM legitimately deepens reduction (fewer spurious gain openings), so
    # only reject if the NLM render is notably SHALLOWER than baseline
    ok = (fl_eco < fl_off * 0.85 and fl_full < fl_off * 0.85 and
          r_eco < -6.0 and r_eco < r_off + 3.0)
    report("nlmflutter", ok,
           "flutter off %.2f eco %.2f full %.2f dB-std (want <0.85x), "
           "depth off %.1f eco %.1f dB" % (fl_off, fl_eco, fl_full,
                                           r_off, r_eco))


def t_nlm_adaptive():
    # NLM over the adaptive (SPP-MMSE) noise estimate: the noise floor must
    # still drop and the 0.5 s tone burst must survive the T-F smoothing
    # (patches containing signal reject noise matches, so bursts stay intact).
    rng = random.Random(1234)
    n = int(SR * 3.5)
    noise = [0.05 * rng.uniform(-1, 1) for _ in range(n)]
    sig = list(noise)
    for t in range(int(SR * 2.5), int(SR * 3.0)):
        sig[t] += AMP * math.sin(2 * math.pi * FREQ_L * t / SR)
    write_wav_f32(os.path.join(WORK, "adaptive_in.wav"), SR, [sig, sig])
    out, _ = render("nlmadapt", slider_line(mode=2, reduction=40.0, nlm=1),
                    input_name="adaptive_in.wav", in_len=3.5, length=3.5)
    a, b = int(SR * 2.0), int(SR * 2.4)
    drop_db = 20 * math.log10(max(rms(out[0], a, b), 1e-12) /
                              rms(noise, a, b))
    ta, tb = int(SR * 2.55), int(SR * 2.95)
    tone_delta = dft_db(out[0][ta:tb], FREQ_L) - dft_db(sig[ta:tb], FREQ_L)
    ok = drop_db < -9.0 and abs(tone_delta) < 3.0
    report("nlmadaptive", ok, "noise %.1f dB (want < -9), tone %+.2f dB (tol 3)"
           % (drop_db, tone_delta))


def gate_input():
    """997 Hz tone: 0-0.4 s at 0.4 (-8 dBFS, above -20 dB threshold),
    0.4-1.2 s at 0.01 (-40 dBFS, below threshold)."""
    n = int(SR * 1.2)
    loud = int(SR * 0.4)
    sig = [(0.4 if t < loud else 0.01) *
           math.sin(2 * math.pi * FREQ_L * t / SR) for t in range(n)]
    return sig


def t_gate():
    # Gate mode: unity above threshold, hard mute (post release) below.
    sig = gate_input()
    write_wav_f32(os.path.join(WORK, "gate_in.wav"), SR, [sig, sig])
    out, _ = render("gate", slider_line(reduction=0.0, gate_on=1,
                                        gthresh=-20.0, gattack=5.0,
                                        ghold=50.0, grelease=50.0),
                    input_name="gate_in.wav", in_len=1.2, length=1.2)
    a, b = int(SR * 0.15), int(SR * 0.35)
    open_diff = maxdiff(out[0][a:b], sig[a:b])
    closed_rms = rms(out[0], int(SR * 0.8), int(SR * 1.15))
    ok = open_diff < 0.001 and closed_rms < 0.0001
    report("gate", ok, "open maxdiff=%.2e (tol 1e-3), closed rms=%.2e "
           "(want < 1e-4, input there %.2e)" %
           (open_diff, closed_rms, rms(sig, int(SR * 0.8), int(SR * 1.15))))


def t_expander():
    # Expander 1:2, threshold -20 dB: the -40 dB tone sits 20 dB below
    # threshold, so it must come out 20 dB quieter (at -60 dB); the loud
    # region stays untouched.
    sig = gate_input()
    write_wav_f32(os.path.join(WORK, "gate_in.wav"), SR, [sig, sig])
    out, _ = render("expander", slider_line(reduction=0.0, gate_on=1,
                                            gthresh=-20.0, gattack=5.0,
                                            ghold=50.0, grelease=50.0,
                                            gmode=1, gratio=2.0),
                    input_name="gate_in.wav", in_len=1.2, length=1.2)
    a, b = int(SR * 0.15), int(SR * 0.35)
    open_diff = maxdiff(out[0][a:b], sig[a:b])
    qa, qb = int(SR * 0.8), int(SR * 1.15)
    delta = dft_db(out[0][qa:qb], FREQ_L) - dft_db(sig[qa:qb], FREQ_L)
    ok = open_diff < 0.002 and abs(delta + 20.0) < 1.5
    report("expander", ok, "open maxdiff=%.2e (tol 2e-3), quiet %+.1f dB "
           "(want -20 +/- 1.5)" % (open_diff, delta))


def t_gateauto():
    # Auto vocal timing must OVERRIDE the manual sliders: attack is set to a
    # uselessly slow 300 ms and release to a choppy 5 ms — if auto mode is
    # honored the gate still opens in ~1 ms (open region matches input) and
    # closes with a program-dependent ~170 ms tail (early-tail rms is neither
    # near-zero nor full level), then reaches silence.
    n = int(SR * 2.0)
    t_on, t_off = int(SR * 0.2), int(SR * 0.5)
    sig = [0.0] * n
    for t in range(t_on, n):
        amp = 0.4 if t < t_off else 0.01
        sig[t] = amp * math.sin(2 * math.pi * FREQ_L * t / SR)
    write_wav_f32(os.path.join(WORK, "gateauto_in.wav"), SR, [sig, sig])
    out, _ = render("gateauto", slider_line(reduction=0.0, gate_on=1,
                                            gthresh=-20.0, gattack=300.0,
                                            ghold=20.0, grelease=5.0,
                                            gauto=1),
                    input_name="gateauto_in.wav", in_len=2.0, length=2.0)
    open_diff = maxdiff(out[0][int(SR * 0.25):int(SR * 0.45)],
                        sig[int(SR * 0.25):int(SR * 0.45)])
    tail_rms = rms(out[0], int(SR * 0.56), int(SR * 0.64))
    closed_rms = rms(out[0], int(SR * 1.4), int(SR * 1.9))
    ok = (open_diff < 0.001 and 0.003 < tail_rms < 0.008 and
          closed_rms < 0.0002)
    report("gateauto", ok, "open maxdiff=%.2e (tol 1e-3), tail rms=%.2e "
           "(want 3e-3..8e-3), closed rms=%.2e (want < 2e-4)" %
           (open_diff, tail_rms, closed_rms))


ALL = [("probe", t_probe), ("unity", t_unity), ("unitysizes", t_unity_sizes),
       ("impulse", t_impulse), ("residual", t_residual_silence),
       ("learn", t_learn), ("adaptive", t_adaptive),
       ("serialize", t_serialize), ("whitening", t_whitening),
       ("nlmalign", t_nlm_align), ("nlmflutter", t_nlm_flutter),
       ("nlmadaptive", t_nlm_adaptive),
       ("gate", t_gate),
       ("expander", t_expander), ("gateauto", t_gateauto)]


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
        except Exception as e:
            report(name, False, "EXCEPTION %s" % e)
    bad = [n for n, ok in RESULTS if not ok]
    print("----\n%d/%d passed" % (len(RESULTS) - len(bad), len(RESULTS)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
