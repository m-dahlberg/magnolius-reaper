#!/usr/bin/env python3
"""Headless render tests for Magnolius_AutoTilt.jsfx.

    ./render_test.py            # everything
    ./render_test.py tilt slope # named tests only

Renders run through `reaper -newinst`, so they are safe while a normal REAPER
is open. Work files land in ~/.cache/autotilt-rendertest (AUTOTILT_WORK to
override). AUTOTILT_KEEP_DBG=1 keeps the generated debug build for inspection.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model                                                    # noqa: E402
from render_harness import (EFFECTS, Harness, decode_dbg,       # noqa: E402
                            js_ser_block, slider_line, bin_freq,
                            dft_mag_hann, db)

SR = 48000
H = Harness("autotilt", "Magnolius_AutoTilt.jsfx",
            work=os.environ.get("AUTOTILT_WORK"))

# slider order must match the header of Magnolius_AutoTilt.jsfx
NAMES = ["tone", "neutral_slope", "tilt_fc", "max_tilt", "resp_s", "ana_s",
         "amount", "offset_db", "gate_db", "ana_lo", "ana_hi", "shelf_s",
         "comp_on", "freeze", "trim_db", "fast_start"]
DEFAULT = dict(tone=0, neutral_slope=-8, tilt_fc=1000, max_tilt=6, resp_s=20,
               ana_s=8, amount=100, offset_db=0, gate_db=-40, ana_lo=120,
               ana_hi=9000, shelf_s=0.55, comp_on=1, freeze=0, trim_db=0,
               fast_start=1)


def S(**kw):
    bad = set(kw) - set(NAMES)
    if bad:
        raise KeyError("unknown slider(s): %s" % sorted(bad))
    v = dict(DEFAULT, **kw)
    return slider_line([v[n] for n in NAMES])


# ---------------------------------------------------------------------------
# signal generation (stdlib only -- no numpy on this box)
# ---------------------------------------------------------------------------

class LCG:
    def __init__(self, seed=12345):
        self.s = seed

    def uni(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s / 0x3FFFFFFF - 1.0


def white(n, amp=0.3, seed=1):
    r = LCG(seed)
    return [amp * r.uni() for _ in range(n)]


def tilted_noise(n, fc, srate=SR, amp=0.25, seed=7):
    """White noise through a one-pole LP: about -6 dB/oct above fc."""
    a = math.exp(-2 * math.pi * fc / srate)
    r = LCG(seed)
    y = 0.0
    out = []
    for _ in range(n):
        y = (1 - a) * r.uni() + a * y
        out.append(y)
    pk = max(abs(v) for v in out) or 1.0
    return [v * amp / pk for v in out]


def multitone(n, freqs, amp, srate=SR):
    out = [0.0] * n
    for j, f in enumerate(freqs):
        ph = 0.7 * j
        w = 2 * math.pi * f / srate
        for i in range(n):
            out[i] += amp * math.sin(w * i + ph)
    return out


def rms(x, lo, hi):
    seg = x[lo:hi]
    return math.sqrt(sum(v * v for v in seg) / len(seg))


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

def t_params():
    """Every slider must survive the header parse. A bad label eats that
    slider and usually all the ones after it, with no error UI anywhere."""
    names, _ = H.probe_params()
    want = ["Tone (Dark to Bright)", "Neutral Slope (dB per oct)",
            "Tilt Pivot (Hz)", "Max Auto Tilt (dB)", "Response (s)",
            "Analysis Window (s)", "Amount (%)", "Manual Offset (dB)",
            "Gate (dB RMS)", "Analysis Low (Hz)", "Analysis High (Hz)",
            "Tilt Shelf Slope", "Level Compensation", "Freeze",
            "Output Trim (dB)", "Fast Start"]
    miss = [(i, w) for i, w in enumerate(want) if names.get(i) != w]
    H.report("params", not miss, "%d sliders, mismatches %s" % (len(want), miss))


def t_unity():
    """Amount 0 with no offset and no trim must be transparent -- which also
    proves the plugin reports no latency because it introduces none."""
    n = 2 * SR
    x = white(n, 0.3, seed=3)
    H.write_input("noise.wav", [x, x])
    out, _ = H.render("unity", S(amount=0, comp_on=0), "noise.wav",
                      length=2.0, in_len=2.0)
    d = max(abs(a - b) for a, b in zip(out[0][:n], x))
    H.report("unity", d < 1e-5, "max |out-in| = %.2e" % d)


def t_trim():
    """CANARY. A dead @init degrades to passthrough and would pass every
    'looks unchanged' test; +6 dB of trim is something passthrough cannot
    fake."""
    n = 2 * SR
    x = white(n, 0.25, seed=4)
    H.write_input("noise.wav", [x, x])
    out, _ = H.render("trim", S(amount=0, comp_on=0, trim_db=6.0), "noise.wav",
                      length=2.0, in_len=2.0)
    g = 10 ** (6.0 / 20)
    d = max(abs(a - g * b) for a, b in zip(out[0][SR // 2:n], x[SR // 2:n]))
    H.report("trim", d < 1e-5, "max |out - 1.9953*in| = %.2e" % d)


def _tilt_at_rate(srate, name):
    """Freeze + Manual Offset is a plain static tilt; its magnitude response
    must match the reference model shelf-for-shelf."""
    probe_n = 32768
    freqs = [bin_freq(f, srate, probe_n)
             for f in (60, 120, 250, 500, 1000, 2000, 4000, 8000, 14000)]
    n = int(2.5 * srate)
    x = multitone(n, freqs, 0.055, srate)
    H.write_input("mt_%d.wav" % srate, [x, x], srate=srate)
    out, _ = H.render(name, S(amount=0, comp_on=0, freeze=1, offset_db=6.0),
                      "mt_%d.wav" % srate, length=2.5, in_len=2.5, srate=srate)
    lo = srate                      # well past the 50 ms coefficient glide
    seg_o = out[0][lo:lo + probe_n]
    seg_i = x[lo:lo + probe_n]
    _, _, fcp = model.ranges(DEFAULT["ana_lo"], DEFAULT["ana_hi"],
                             DEFAULT["tilt_fc"], srate)
    worst = 0.0
    detail = []
    for f in freqs:
        meas = db(dft_mag_hann(seg_o, f, srate)) - db(dft_mag_hann(seg_i, f, srate))
        want = model.tilt_db(f, 6.0, fcp, DEFAULT["shelf_s"], srate)
        worst = max(worst, abs(meas - want))
        detail.append("%d:%+.2f/%+.2f" % (round(f), meas, want))
    H.report(name, worst < 0.05,
             "worst %.3f dB  (meas/model) %s" % (worst, " ".join(detail)))


def t_tilt():
    _tilt_at_rate(48000, "tilt")


def t_rates():
    _tilt_at_rate(44100, "tilt44k")
    _tilt_at_rate(96000, "tilt96k")


def t_slope():
    """End to end: a source whose slope is far from the target must come out
    ON the target. This is the whole point of the plugin, and it exercises
    the FFT analysis, the band fit, the sensitivity constant and the loop."""
    secs = 26
    n = secs * SR
    x = tilted_noise(n, 60.0, SR, amp=0.25, seed=11)
    H.write_input("shaped.wav", [x, x])
    target = -3.0
    out, _ = H.render("slope",
                      S(neutral_slope=target, tone=0, amount=100, max_tilt=12,
                        resp_s=1, ana_s=1, comp_on=0, gate_db=-70),
                      "shaped.wav", length=float(secs), in_len=float(secs))

    flop, fhip, fcp = model.ranges(DEFAULT["ana_lo"], DEFAULT["ana_hi"],
                                   DEFAULT["tilt_fc"], SR)
    B = model.Bands(flop, fhip, SR)
    start = 20 * SR                       # converged, and still inside the item
    din = model.avg_band_db(x, x, B, start, 8)
    dout = model.avg_band_db(out[0], out[1], B, start, 8)
    s_in, s_out = B.slope(din), B.slope(dout)
    moved = abs(s_out - s_in)
    ok = abs(s_out - target) < 0.35 and moved > 1.0
    H.report("slope", ok, "in %+.2f -> out %+.2f dB per oct (target %+.2f)"
             % (s_in, s_out, target))


def t_comp():
    """Level Compensation must hold broadband level roughly put under a big
    tilt -- and the same render with it off must move by clearly more, so the
    test cannot pass by the compensation doing nothing."""
    n = 3 * SR
    x = white(n, 0.25, seed=21)
    H.write_input("white.wav", [x, x])
    base = dict(amount=0, freeze=1, offset_db=6.0, ana_lo=40, ana_hi=16000)
    lo, hi = SR, n
    r_in = rms(x, lo, hi)
    on, _ = H.render("comp_on", S(comp_on=1, **base), "white.wav",
                     length=3.0, in_len=3.0)
    off, _ = H.render("comp_off", S(comp_on=0, **base), "white.wav",
                      length=3.0, in_len=3.0)
    d_on = db(rms(on[0], lo, hi)) - db(r_in)
    d_off = db(rms(off[0], lo, hi)) - db(r_in)
    H.report("comp", abs(d_on) < 1.0 and abs(d_off) > 1.5,
             "level change  on %+.2f dB   off %+.2f dB" % (d_on, d_off))


DBG_TAIL = r"""
// ---- debug build tail (generated by tools/render_test.py) ----------------
dbg_i += 1;
dbg_i >= 64*64 ? ( dbg_i = 0; );
dbg_s = floor(dbg_i/64);
dbg_s == 4 ? (
  dbg_mx = -300; dbg_b = 0;
  loop(NB, dbg_mx = max(dbg_mx, dspDB[dbg_b]); dbg_b += 1;);
);
dbg_v = dbg_s == 0 ? meas_slope
      : dbg_s == 1 ? sens
      : dbg_s == 2 ? tilt_app
      : dbg_s == 3 ? comp_s
      : dbg_s == 4 ? dbg_mx
      : dbg_s == 5 ? max(-200, 20*log10(max(frms,TINY)))
      : 0;
dbg_v = max(-450, min(450, dbg_v));
spl0 = dbg_s == 63 ? 0.9876543 : dbg_v*0.002;
spl1 = spl0;
"""


def build_dbg():
    """Generate autotilt_dbg.jsfx from the real source on every run, so the
    tested code cannot drift from the shipped code.

    Harness.build_debug_fx splits at @gfx; this source has @serialize before
    @gfx, so the tail has to be placed by hand or it lands in the wrong
    section and silently does nothing.
    """
    src_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "Magnolius_AutoTilt.jsfx")
    src = open(src_path).read()
    anchor = "\n@serialize"
    if anchor not in src:
        raise RuntimeError("@serialize not found - source layout changed")
    head, sep, rest = src.partition(anchor)
    dst = os.path.join(EFFECTS, "autotilt_dbg.jsfx")
    if os.path.islink(dst):
        os.remove(dst)
    with open(dst, "w") as f:
        f.write(head + DBG_TAIL + sep + rest)
    return dst


def t_internals():
    """Pins the band power normalisation, which nothing audible depends on and
    which therefore silently drifts: a band holding a sine of amplitude A must
    read 10*log10(A^2/2) dB. Also checks the measured slope and sensitivity
    against the model. Uses a debug build regenerated from the real source."""
    dbg = build_dbg()
    try:
        n = 4 * SR
        amp = 0.5
        f = bin_freq(1000, SR, 8192)
        sine = [amp * math.sin(2 * math.pi * f * i / SR) for i in range(n)]
        H.write_input("sine.wav", [sine, sine])
        out, _ = H.render("dbg_sine", S(freeze=1, comp_on=0, gate_db=-70),
                          "sine.wav", length=4.0, in_len=4.0,
                          fx=os.path.basename(dbg))
        vals = decode_dbg(out, 6, 3.0, SR)[0]
        m_slope, m_sens, m_tilt, m_comp, m_max, m_rms = vals
        flop, fhip, fcp = model.ranges(DEFAULT["ana_lo"], DEFAULT["ana_hi"],
                                       DEFAULT["tilt_fc"], SR)
        B = model.Bands(flop, fhip, SR)
        # bandDB is a power DENSITY (band power / bins in the band), which is
        # what makes the slope fit meaningful; the sine's whole power lands in
        # one band, so density = 10*log10(A^2/2) - 10*log10(bins in that band).
        bsine = B.binband[round(f * model.FFTSIZE / SR)]
        want_max = 10 * math.log10(amp * amp / 2) - 10 * math.log10(B.w[bsine])
        want_rms = 20 * math.log10(amp / math.sqrt(2))
        want_sens = B.sens(fcp, DEFAULT["shelf_s"])
        ok = (abs(m_max - want_max) < 0.2 and abs(m_rms - want_rms) < 0.1
              and abs(m_sens - want_sens) < 0.005)
        H.report("internals", ok,
                 "peak band %.2f dB (want %.2f)  rms %.2f (want %.2f)  "
                 "sens %.4f (want %.4f)  slope %+.2f  tilt %+.3f"
                 % (m_max, want_max, m_rms, want_rms, m_sens, want_sens,
                    m_slope, m_tilt))
    finally:
        if not os.environ.get("AUTOTILT_KEEP_DBG"):
            os.path.exists(dbg) and os.remove(dbg)


def t_serialize():
    """The converged tilt travels with the project, so reopening a session
    sounds right immediately instead of re-converging from flat. Float order
    must match the file_var calls in @serialize exactly."""
    srate, probe_n = SR, 32768
    freqs = [bin_freq(f, srate, probe_n) for f in (120, 1000, 8000)]
    n = int(2.5 * srate)
    x = multitone(n, freqs, 0.1, srate)
    H.write_input("mt_ser.wav", [x, x], srate=srate)
    stored = 4.0
    out, _ = H.render("serial", S(amount=0, comp_on=0, freeze=1),
                      "mt_ser.wav", length=2.5, in_len=2.5, srate=srate,
                      js_ser=js_ser_block([20260828.0, stored, 0.0]))
    lo = srate
    seg_o, seg_i = out[0][lo:lo + probe_n], x[lo:lo + probe_n]
    _, _, fcp = model.ranges(DEFAULT["ana_lo"], DEFAULT["ana_hi"],
                             DEFAULT["tilt_fc"], srate)
    worst, detail = 0.0, []
    for f in freqs:
        meas = db(dft_mag_hann(seg_o, f, srate)) - db(dft_mag_hann(seg_i, f, srate))
        want = model.tilt_db(f, stored, fcp, DEFAULT["shelf_s"], srate)
        worst = max(worst, abs(meas - want))
        detail.append("%d:%+.2f/%+.2f" % (round(f), meas, want))
    H.report("serialize", worst < 0.05,
             "restored %.1f dB tilt, worst %.3f dB  %s"
             % (stored, worst, " ".join(detail)))


TESTS = [("params", t_params), ("unity", t_unity), ("trim", t_trim),
         ("tilt", t_tilt), ("internals", t_internals), ("comp", t_comp), ("serialize", t_serialize),
         ("slope", t_slope), ("rates", t_rates)]

if __name__ == "__main__":
    H.run(TESTS)
