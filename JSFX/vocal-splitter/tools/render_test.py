#!/usr/bin/env python3
"""Headless render tests for Magnolius_VocalSplitter.jsfx.

Usage: render_test.py [test ...]     (no args = all)
Tests: params unity canary features stems midword_cons dark_cons vowel_onset
       quiet_cons sustained_cons realclip cons_prom cons_dur sib_onset
       breath_split breath_gap listen sum_vs_split rates
Work dir: ~/.cache/vocalsplitter-rendertest (override: VSPLIT_WORK)

The unity test alone would pass vacuously if @init died (dead JSFX =
passthrough = perfect null), so `canary` proves the gain path is alive and
`params` proves every slider parsed.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_harness import (Harness, ReaperProject, slider_line, maxdiff,
                            rms, db, decode_dbg, DBG_SLOT, DBG_SCALE,
                            DBG_MAGIC)  # noqa: E402
from wavio import read_wav  # noqa: E402

SRATE = 48000
H = Harness("vocalsplitter", "Magnolius_VocalSplitter.jsfx", srate=SRATE,
            work=os.environ.get("VSPLIT_WORK"))

# slider order (1..27) — must match the .jsfx header
SLIDERS = ["cons_prom", "cons_mindur", "cons_lvl", "cons_maxdur", "cons_att",
           "cons_rel", "sib_sens", "sib_lo", "sib_hi", "sib_mindur",
           "br_sens", "br_below", "br_zcr", "br_mindur", "br_tc",
           "hardness", "transition", "lookahead", "outmode", "listen",
           "gain_res", "gain_br", "gain_sib", "gain_cons",
           "cons_lo", "cons_hi", "cons_aper"]
DEFAULTS = dict(cons_prom=2, cons_mindur=8, cons_lvl=25, cons_maxdur=80,
                cons_att=0.5, cons_rel=8, sib_sens=0, sib_lo=3000,
                sib_hi=8000, sib_mindur=40, br_sens=0, br_below=25,
                br_zcr=0.15, br_mindur=80, br_tc=1500, hardness=0,
                transition=8, lookahead=10, outmode=0, listen=0,
                gain_res=0, gain_br=0, gain_sib=0, gain_cons=0,
                cons_lo=1500, cons_hi=6000, cons_aper=0.58)


def sl(**over):
    vals = dict(DEFAULTS)
    vals.update(over)
    return slider_line([vals[k] for k in SLIDERS])


# 8-channel variant: JSFX only sees channels that exist on the track (NCHAN),
# the MASTER bus truncates to its own width unless MASTER_NCH is raised
# (measured: without it channels 3-8 render as digital silence), and
# RENDER_FMT's 2nd field is the rendered channel count.
class Project8(ReaperProject):
    TEMPLATE = (ReaperProject.TEMPLATE
                .replace('NAME "test"', 'NAME "test"\n    NCHAN 8')
                .replace("TEMPO 120 4 4", "TEMPO 120 4 4\n  MASTER_NCH 8")
                .replace("RENDER_FMT 0 2", "RENDER_FMT 0 8"))


def render8(name, sliders, **kw):
    old = H.proj
    H.proj = Project8()
    try:
        return H.render(name, sliders, **kw)
    finally:
        H.proj = old


# ---------------------------------------------------------------------------
# synthetic inputs
# ---------------------------------------------------------------------------

def _tone(n, freq, amp, srate=SRATE):
    return [amp * math.sin(2 * math.pi * freq * i / srate) for i in range(n)]


def _voiced(n, amp, srate=SRATE):
    """220 Hz pulse-train vowel, harmonics to ~8 kHz with 1/k^1.7 rolloff.
    Real vowels carry strong presence-band energy (F2/F3): this measures
    ~-24 dB consonant-band share, matching the real reference clip's ~-20.
    The old 3-harmonic version had NOTHING above 660 Hz, so every consonant
    test passed vacuously against a band reference stuck at the floor while
    the plugin failed on real vocals."""
    nh = 36
    w = [1.0 / (k ** 1.7) for k in range(1, nh + 1)]
    # 1.365 calibrates the fast-envelope level (the plugin's phrase
    # reference) to the old 3-harmonic vowel at equal amp (-12.9 dBFS at
    # 0.35, measured), so no phrase-relative threshold in the suite moves.
    norm = amp * 1.365 / sum(w)
    out = []
    for i in range(n):
        t = 2 * math.pi * 220 * i / srate
        out.append(norm * sum(wk * math.sin((k + 1) * t)
                              for k, wk in enumerate(w)))
    return out


def _noise(n, amp, seed, lo=None, hi=None, srate=SRATE):
    """White noise, optionally band-limited by crude 2nd-order sections."""
    rng = random.Random(seed)
    x = [amp * (2 * rng.random() - 1) for _ in range(n)]
    if hi is not None:                       # one-pole LP applied twice
        a = math.exp(-2 * math.pi * hi / srate)
        for _ in range(2):
            acc = 0.0
            for i in range(n):
                acc = (1 - a) * x[i] + a * acc
                x[i] = acc
    if lo is not None:                       # one-pole HP applied twice
        a = math.exp(-2 * math.pi * lo / srate)
        for _ in range(2):
            acc = 0.0
            prev = 0.0
            for i in range(n):
                acc = a * (acc + x[i] - prev)
                prev = x[i]
                x[i] = acc
    return x


def _fade(x, ms=5, srate=SRATE):
    k = int(ms * 0.001 * srate)
    for i in range(min(k, len(x))):
        g = i / k
        x[i] *= g
        x[-1 - i] *= g
    return x


def sec(s):
    return int(s * SRATE)


VOWEL_RMS = 0.186          # RMS of _voiced(n, 0.35), the suite's standard vowel


def _stop(x, pos, seed, closure=0.030, burst=0.040, rel_db=-10,
          lo=400, hi=8000):
    """Write a physically real unvoiced stop into x at `pos` seconds.

    A stop is a CLOSURE (voicing stops - that is what makes it a stop)
    followed by a broadband release burst with energy from a few hundred Hz
    up. The earlier synthetics modelled a consonant as bright 2-9 kHz noise
    ADDED on top of continuing voicing, which is not a consonant at all: it
    is a vowel with a tick on it. They encoded the old brightness-based
    detector's assumptions, and the harmonicity ground truth contradicts
    them - so they are replaced rather than accommodated.
    Durations are realistic: English voice-onset time for /t/ /k/ runs
    60-80 ms including aspiration; 30 ms closure + 40 ms burst sits inside
    that.
    The burst is normalised to `rel_db` BELOW the standard vowel by measured
    RMS, because band-limiting costs 6-17 dB depending on the band - passing
    a raw amplitude silently produced bursts 23 dB down, far quieter than
    any real consonant (measured: 3-14 dB below the phrase average).
    """
    a, b = sec(pos), sec(pos + closure)
    for i in range(a, min(b, len(x))):
        x[i] = 0.0                              # closure: voicing stops
    seg = _noise(sec(burst), 0.5, seed, lo=lo, hi=hi)
    # A plosive release is a sharp transient that DECAYS through its
    # aspiration; a flat-amplitude noise block is fricative-shaped and is
    # correctly claimed by the sibilance class instead (its presence factor
    # exists precisely to tell a decaying burst tail from a sustained /s/).
    tau = 0.012 * SRATE
    seg = [v * math.exp(-i / tau) for i, v in enumerate(seg)]
    cur = math.sqrt(sum(v * v for v in seg) / len(seg)) or 1e-12
    g = VOWEL_RMS * 10 ** (rel_db / 20) / cur
    seg = _fade([v * g for v in seg], 1)
    for i, v in enumerate(seg):
        if b + i < len(x):
            x[b + i] = v
    return pos + closure, pos + closure + burst  # burst window


def build_vocal_like(name):
    """Phrase tone – gap – breath – gap – sibilant – gap+closure – click."""
    n = sec(3.0)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(0.80), 0.35)))            # phrase
    put(sec(1.05), _fade(_noise(sec(0.30), 0.02, 1, lo=800, hi=6000)))  # breath
    put(sec(1.50), _fade(_voiced(sec(0.40), 0.35)))            # phrase
    put(sec(2.00), _fade(_noise(sec(0.15), 0.15, 2, lo=5000, hi=9000), 3))  # /s/
    put(sec(2.55), _fade(_voiced(sec(0.45), 0.35)))
    _stop(x, 2.40, 3)                                          # /t/
    return H.write_input(name, [x, x]), x


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

def t_params():
    names, _ = H.probe_params()
    bad = []
    # REAPER exposes labels, not var names: assert count and spot-check labels.
    ok = len([i for i in names if i < 27]) == 27
    checks = {0: "Cons peak prominence", 9: "Sib min duration",
              15: "Confidence hardness", 23: "Consonant gain",
              24: "Cons band low", 25: "Cons band high",
              26: "Cons periodicity"}
    for i, frag in checks.items():
        if frag.lower() not in names.get(i, "").lower():
            ok = False
            bad.append("param %d = %r (want ~%r)" % (i, names.get(i), frag))
    H.report("params", ok, "; ".join(bad) or "%d sliders parsed" % len(SLIDERS))


def _unity_case(tag, hardness):
    p = H.write_input("uin.wav", [UIN0, UIN1])
    ref = read_wav(p)[1]           # compare against the float32 WAV as written
    out, secs = H.render("unity_%s" % tag, sl(hardness=hardness),
                         input_name="uin.wav", length=3.0)
    n = len(UIN0)
    d = max(maxdiff(out[0][:n], ref[0]), maxdiff(out[1][:n], ref[1]))
    # REAPER injects a ~1.5e-16 denormal-prevention DC into FX input buffers
    # (measured: constant additive offset present even where input is exactly
    # 0.0; the plugin's output path is multiply-only so it cannot add DC).
    # 5e-16 = that offset plus rounding slack; still a -307 dBFS null.
    H.report("unity", d < 5e-16,
             "hardness=%d maxdiff=%g (%.1fs)" % (hardness, d, secs))


def t_unity():
    for h in (0, 50, 100):
        _unity_case(str(h), h)


def t_canary():
    H.write_input("uin.wav", [UIN0, UIN1])
    g = 6.0
    lin = 10 ** (g / 20)
    out, _ = H.render("canary", sl(gain_res=g, gain_br=g, gain_sib=g,
                                   gain_cons=g),
                      input_name="uin.wav", length=3.0)
    n = len(UIN0)
    # all four gains equal => tot = 1 + (lin-1)*sum(c) = lin exactly
    d = maxdiff(out[0][:n], [v * lin for v in UIN0])
    H.report("canary", d < 1e-6, "all-gains +6 dB maxdiff=%g" % d)


def _stem_energy(chans, lo, hi):
    """Per-stem RMS in a sample window, stems as stereo pairs."""
    return [rms(chans[c][lo:hi]) for c in (0, 2, 4, 6)]


def t_stems():
    build_vocal_like("vocal.wav")
    out, _ = render8("stems", sl(outmode=1, hardness=100),
                     input_name="vocal.wav", length=3.0)
    ok_all = True
    msgs = []
    # (label, window, expected stem index): res=0 br=1 sib=2 cons=3
    cases = [
        ("residual", (sec(0.30), sec(0.80)), 0),
        ("breath",   (sec(1.07), sec(1.30)), 1),
        ("sib",      (sec(2.06), sec(2.13)), 2),
        ("cons",     (sec(2.435), sec(2.465)), 3),
    ]
    for label, (lo, hi), want in cases:
        e = _stem_energy(out, lo, hi)
        tot = sum(v * v for v in e) or 1e-30
        frac = e[want] ** 2 / tot
        ok = frac > 0.7
        ok_all = ok_all and ok
        msgs.append("%s %.0f%%" % (label, frac * 100))
    H.report("stems", ok_all, "  ".join(msgs))


def _cons_case(name, seed, **stop):
    """vowel - stop - vowel, asserting the burst lands in the consonant stem."""
    n = sec(2.2)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(0.80), 0.35)))
    put(sec(1.05), _fade(_voiced(sec(0.60), 0.35)))
    b0, b1 = _stop(x, 0.90, seed, **stop)
    H.write_input("%s_in.wav" % name, [x, x])
    out, _ = render8(name, sl(outmode=1, hardness=100),
                     input_name="%s_in.wav" % name, length=2.2)
    e = _stem_energy(out, sec(b0 + 0.002), sec(b1 - 0.002))
    tot = sum(v * v for v in e) or 1e-30
    return e, tot, e[3] ** 2 / tot


def t_midword_cons():
    """A mid-word /t/ between two vowels, with only its own 30 ms closure --
    no phrase-level pause anywhere. Voicing stops for the closure and burst,
    which is the whole signature; nothing about level or brightness is."""
    e, tot, frac = _cons_case("midword", 7)
    H.report("midword_cons", frac > 0.5,
             "cons stem %.0f%% (res %.0f%% sib %.0f%%)"
             % (frac * 100, e[0] ** 2 / tot * 100, e[2] ** 2 / tot * 100))


def t_dark_cons():
    """A dark /k/-like burst concentrated at 0.4-3 kHz, with no HF at all.
    Brightness-based detection could never see this one; voicing-based
    detection does not care how bright a consonant is."""
    e, tot, frac = _cons_case("darkcons", 41, lo=400, hi=3000)
    H.report("dark_cons", frac > 0.5,
             "cons stem %.0f%% (res %.0f%% sib %.0f%%)"
             % (frac * 100, e[0] ** 2 / tot * 100, e[2] ** 2 / tot * 100))


def t_vowel_onset():
    """A soft word onset after a pause (25 ms vowel fade, no burst) must NOT
    engage the consonant class. The old rise gate could not tell a slow fade
    from a burst when both rise out of quiet, and triggered on cons-band
    filter leakage alone (reported: 'engages on word onset even when there
    is no sharp transient')."""
    n = sec(2.0)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(0.60), 0.35)))
    put(sec(1.00), _fade(_voiced(sec(0.60), 0.35), 25))
    H.write_input("vowon_in.wav", [x, x])
    out, _ = render8("vowon", sl(outmode=1, hardness=100),
                     input_name="vowon_in.wav", length=2.0)
    e = _stem_energy(out, sec(1.00), sec(1.08))
    tot = sum(v * v for v in e) or 1e-30
    rfrac = e[0] ** 2 / tot
    H.report("vowel_onset", rfrac > 0.9,
             "onset residual %.0f%% (cons %.0f%%)"
             % (rfrac * 100, e[3] ** 2 / tot * 100))


def t_quiet_cons():
    """An isolated consonant between phrases, sitting in room tone (-60 dB,
    above the silence gate). Room tone accumulates its own breath-evidence
    run, and the breath interlock must not swallow a real consonant inside
    one - it is scoped by the run's own level for exactly this case.
    The burst sits ~15 dB below the phrase average, which is where real
    consonants live (measured on the reference clip: 3-14 dB below)."""
    import random as _rnd
    n = sec(2.4)
    rng = _rnd.Random(51)
    x = [0.001 * (2 * rng.random() - 1) for _ in range(n)]   # -60 dB room

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(0.60), 0.35)))
    put(sec(1.45), _fade(_voiced(sec(0.60), 0.35)))
    b0, b1 = _stop(x, 1.05, 52, rel_db=-14)
    H.write_input("quietcons_in.wav", [x, x])
    out, _ = render8("quietcons", sl(outmode=1, hardness=100),
                     input_name="quietcons_in.wav", length=2.4)
    e = _stem_energy(out, sec(b0 + 0.002), sec(b1 - 0.002))
    tot = sum(v * v for v in e) or 1e-30
    frac = e[3] ** 2 / tot
    H.report("quiet_cons", frac > 0.6,
             "cons stem %.0f%% (res %.0f%% br %.0f%% sib %.0f%%)"
             % (frac * 100, e[0] ** 2 / tot * 100,
                e[1] ** 2 / tot * 100, e[2] ** 2 / tot * 100))


def t_sustained_cons():
    """A consonant interrupting a sustained note: the vowel runs continuously
    at one level either side, so there is no phrase pause and no level
    envelope to key off - only the voicing interruption. The old closure-gate
    design documented this case as an accepted miss."""
    n = sec(2.0)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(1.40), 0.35)))
    b0, b1 = _stop(x, 0.80, 61)
    H.write_input("suscons_in.wav", [x, x])
    out, _ = render8("suscons", sl(outmode=1, hardness=100),
                     input_name="suscons_in.wav", length=2.0)
    e = _stem_energy(out, sec(b0 + 0.002), sec(b1 - 0.002))
    tot = sum(v * v for v in e) or 1e-30
    frac = e[3] ** 2 / tot
    H.report("sustained_cons", frac > 0.5,
             "cons stem %.0f%% (res %.0f%% sib %.0f%%)"
             % (frac * 100, e[0] ** 2 / tot * 100, e[2] ** 2 / tot * 100))


CLIP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "Consonant test file.wav")


# Ground truth for the reference clip, derived INDEPENDENTLY of the plugin:
# normalized-autocorrelation harmonicity over the whole file, regions where
# voicing < 0.55 at usable level. Nothing here comes from the plugin's own
# metric - an earlier version of this test asserted consonants wherever the
# detector's own feature peaked, which is circular and validated a metric
# that (measured later) did not separate consonants from vowels at all.
GT_APERIODIC = [(0.005, 0.110), (1.520, 1.670), (2.135, 2.145),
                (2.460, 2.475), (2.560, 2.600), (2.700, 2.715),
                (2.910, 3.030), (4.255, 4.335), (4.790, 4.805),
                (4.930, 4.955), (5.060, 5.200), (5.295, 5.325),
                (5.415, 5.440), (5.520, 5.530)]
# stretches with no aperiodic frame anywhere near them
GT_VOICED = [(0.35, 0.55), (1.05, 1.25), (1.75, 1.95), (2.20, 2.40),
             (3.90, 4.05), (4.55, 4.70)]


def t_realclip():
    """The real reference clip (dark close-mic vocal, 48 k mono), scored
    against independent harmonicity ground truth: every unvoiced region must
    reach the consonant stem, and every voiced stretch must stay out of it.
    This is the anchor that keeps the synthetic tests honest."""
    if not os.path.exists(CLIP):
        H.report("realclip", True, "SKIPPED - reference clip not found")
        return
    srate, chans = read_wav(CLIP)
    if srate != SRATE:
        H.report("realclip", False, "clip is %d Hz, expected %d" % (srate, SRATE))
        return
    x = chans[0]
    H.write_input("realclip_in.wav", [x, x])
    dur = len(x) / srate
    out, _ = render8("realclip", sl(outmode=1, hardness=100),
                     input_name="realclip_in.wav", length=dur)

    def frac(lo, hi, want):
        e = _stem_energy(out, sec(lo), sec(hi))
        tot = sum(v * v for v in e) or 1e-30
        return e[want] ** 2 / tot

    # a consonant claim need only overlap the region: the detector confirms
    # 20 ms in and backfills, so edges are approximate by design
    missed = [(a, b) for a, b in GT_APERIODIC
              if frac(max(a - 0.02, 0), b + 0.02, 3) < 0.25]
    leaked = [(a, b) for a, b in GT_VOICED if frac(a, b, 3) > 0.10]
    ok = not missed and not leaked
    H.report("realclip", ok,
             "%d/%d unvoiced regions caught, %d/%d voiced stretches clean%s"
             % (len(GT_APERIODIC) - len(missed), len(GT_APERIODIC),
                len(GT_VOICED) - len(leaked), len(GT_VOICED),
                "" if ok else "  missed=%s leaked=%s"
                % ([round(a, 2) for a, _ in missed],
                   [round(a, 2) for a, _ in leaked])))


def _claimed_fraction(tag, x, dur, **over):
    """Fraction of the timeline where the consonant stem owns the moment."""
    step = int(0.010 * SRATE)
    out, _ = render8(tag, sl(outmode=1, hardness=100, **over),
                     input_name="promsweep_in.wav", length=dur)
    n = min(len(out[0]), len(x))
    claimed = 0
    for p in range(0, n - step, step):
        e = _stem_energy(out, p, p + step)
        tot = sum(v2 * v2 for v2 in e) or 1e-30
        claimed += (e[3] ** 2 / tot) > 0.5
    return claimed * step / n


def t_cons_prom():
    """The prominence slider must MOVE the detector, monotonically - the
    user-reported symptom across two designs now was 'I have experimented
    with the parameters but have not found any clear improvement'. Also
    guards the class of latch bug this suite has caught twice: a re-arm
    condition defined relative to the threshold and unreachable at high
    sensitivity, so MORE sensitivity fired LESS. The de-duplication guard
    (claim_end_fr) is exactly that shape of state, so it is what this test is
    watching now. Measures claimed timeline fraction, not event count:
    adjacent claims correctly merge into long runs at low thresholds."""
    if not os.path.exists(CLIP):
        H.report("cons_prom", True, "SKIPPED - reference clip not found")
        return
    srate, chans = read_wav(CLIP)
    x = chans[0]
    H.write_input("promsweep_in.wav", [x, x])
    dur = len(x) / srate
    # LOWER prominence = more claimed, so the sequence must be decreasing
    got = [_claimed_fraction("promsweep%d" % v, x, dur, cons_prom=v)
           for v in (2, 4, 9)]
    lo, mid, hi = got
    ok = lo > mid > hi and mid > 0.02
    H.report("cons_prom", ok,
             "claimed timeline: prom>=2 dB %.1f%%  >=4 dB %.1f%%  >=9 dB %.1f%%"
             % (lo * 100, mid * 100, hi * 100))


def t_cons_dur():
    """Duration is a real discriminator now, not a formality: a short burst
    is a consonant, a long fricative is not. A sustained /s/ has no low point
    on its trailing side anywhere inside a cons_maxdur window, so the shape
    never resolves and the consonant class never claims it - which is what
    hands long fricatives cleanly to the sibilance class instead of relying
    on the stage-2 reclaim to take them back."""
    n = sec(2.6)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(0.60), 0.35)))
    b0, b1 = _stop(x, 0.90, 71)                      # short burst
    put(sec(1.40), _fade(_voiced(sec(0.50), 0.35)))
    f0, f1 = 2.00, 2.15                              # 150 ms fricative
    put(sec(f0), _fade(_noise(sec(f1 - f0), 0.10, 72, lo=4000, hi=9000), 8))
    H.write_input("consdur_in.wav", [x, x])
    out, _ = render8("consdur", sl(outmode=1, hardness=100),
                     input_name="consdur_in.wav", length=2.6)

    def frac(lo, hi):
        e = _stem_energy(out, sec(lo), sec(hi))
        tot = sum(v * v for v in e) or 1e-30
        return e[3] ** 2 / tot

    burst = frac(b0 + 0.002, b1 - 0.002)
    fric = frac(f0 + 0.04, f1 - 0.01)
    ok = burst > 0.5 and fric < 0.25
    H.report("cons_dur", ok,
             "15-40 ms burst %.0f%% cons, 150 ms fricative %.0f%% cons"
             % (burst * 100, fric * 100))


def t_sib_onset():
    """The reported symptom: the first part of an /s/ classified residual,
    the rest sibilance. Worst case is a /s/ right after a vowel (the vowel
    holds the HF-ratio denominator up via the envelope release). The onset
    backfill must hand the front of the /s/ to the sibilance stem."""
    n = sec(2.0)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    put(sec(0.10), _fade(_voiced(sec(0.50), 0.35)))
    put(sec(0.60), _fade(_noise(sec(0.15), 0.15, 11, lo=5000, hi=9000), 3))
    put(sec(0.95), _fade(_voiced(sec(0.40), 0.35)))
    H.write_input("sibonset_in.wav", [x, x])
    out, _ = render8("sibonset", sl(outmode=1, hardness=100),
                     input_name="sibonset_in.wav", length=2.0)
    front = _stem_energy(out, sec(0.602), sec(0.618))
    mid = _stem_energy(out, sec(0.618), sec(0.640))   # prov->confirm stretch
    body = _stem_energy(out, sec(0.64), sec(0.72))
    ftot = sum(v * v for v in front) or 1e-30
    mtot = sum(v * v for v in mid) or 1e-30
    btot = sum(v * v for v in body) or 1e-30
    ffrac = front[2] ** 2 / ftot
    mfrac = mid[2] ** 2 / mtot
    bfrac = body[2] ** 2 / btot
    H.report("sib_onset", ffrac > 0.5 and mfrac > 0.7 and bfrac > 0.8,
             "front(2-18ms) sib %.0f%%  mid(18-40ms) %.0f%%  body %.0f%%"
             % (ffrac * 100, mfrac * 100, bfrac * 100))


def t_breath_split():
    """A breath whose middle swells louder (toward the level threshold) must
    not be split into two breaths with a residual stutter in between --
    a breath is one gesture (the reported stuttering bug)."""
    n = sec(2.4)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    amp_lo = 10 ** (-35 / 20)
    amp_hi = 10 ** (-28 / 20)   # mid-breath swell: kills the level evidence
    put(sec(0.10), _fade(_voiced(sec(0.70), 0.35)))
    # breath parts fade slowly (real breaths have no percussive edges), and
    # the swell is darker than the rest -- a swell with /s/-like spectrum
    # would legitimately classify as sibilance
    put(sec(0.95), _fade(_noise(sec(0.15), amp_lo, 21, lo=800, hi=6000), 15))
    put(sec(1.10), _fade(_noise(sec(0.10), amp_hi, 22, lo=600, hi=3500), 8))
    put(sec(1.20), _fade(_noise(sec(0.15), amp_lo, 23, lo=800, hi=6000), 15))
    put(sec(1.55), _fade(_voiced(sec(0.60), 0.35)))
    H.write_input("brsplit_in.wav", [x, x])
    out, _ = render8("brsplit", sl(outmode=1, hardness=100),
                     input_name="brsplit_in.wav", length=2.4)
    whole = _stem_energy(out, sec(1.00), sec(1.33))
    mid = _stem_energy(out, sec(1.11), sec(1.19))
    wtot = sum(v * v for v in whole) or 1e-30
    mtot = sum(v * v for v in mid) or 1e-30
    wfrac = whole[1] ** 2 / wtot
    mfrac = mid[1] ** 2 / mtot
    H.report("breath_split", wfrac > 0.85 and mfrac > 0.7,
             "whole breath %.0f%%  swell middle %.0f%% (res %.0f%%)"
             % (wfrac * 100, mfrac * 100, mid[0] ** 2 / mtot * 100))


def t_breath_gap():
    """Two breath phases separated by a near-silent turn-around (inhale /
    pause / exhale) are one gesture. The second phase must be classified
    breath from its first sample - no re-confirmation stutter - because the
    hangover bridges straight through the silent gap."""
    n = sec(2.6)
    x = [0.0] * n

    def put(pos, seg):
        for i, v in enumerate(seg):
            x[pos + i] += v

    amp = 10 ** (-35 / 20)
    put(sec(0.10), _fade(_voiced(sec(0.70), 0.35)))
    put(sec(0.95), _fade(_noise(sec(0.12), amp, 31, lo=800, hi=6000), 15))
    # 120 ms of digital silence: the mid-breath turn-around
    put(sec(1.19), _fade(_noise(sec(0.15), amp, 32, lo=800, hi=6000), 15))
    put(sec(1.60), _fade(_voiced(sec(0.60), 0.35)))
    H.write_input("brgap_in.wav", [x, x])
    out, _ = render8("brgap", sl(outmode=1, hardness=100),
                     input_name="brgap_in.wav", length=2.6)
    # first window deliberately starts inside the provisional-to-confirmed
    # stretch (onset+15ms..) - the region the gate-ramp split used to hole out
    first = _stem_energy(out, sec(0.965), sec(1.06))
    second = _stem_energy(out, sec(1.195), sec(1.33))
    ftot = sum(v * v for v in first) or 1e-30
    stot = sum(v * v for v in second) or 1e-30
    ffrac = first[1] ** 2 / ftot
    sfrac = second[1] ** 2 / stot
    H.report("breath_gap", ffrac > 0.8 and sfrac > 0.85,
             "phase1 %.0f%%  phase2 %.0f%% breath (phase2 res %.0f%%)"
             % (ffrac * 100, sfrac * 100, second[0] ** 2 / stot * 100))


def t_listen():
    build_vocal_like("vocal.wav")
    out, _ = H.render("listen_sib", sl(listen=3, hardness=100),
                      input_name="vocal.wav", length=3.0)
    sib = rms(out[0][sec(2.06):sec(2.13)])
    vowel = rms(out[0][sec(0.30):sec(0.80)])
    ok = sib > 0.01 and vowel < sib * 0.05
    H.report("listen", ok, "solo sib: sib-win %.4f vowel-win %.5f" % (sib, vowel))


def t_sum_vs_split():
    build_vocal_like("vocal.wav")
    o8, _ = render8("svs_split", sl(outmode=1, hardness=50),
                    input_name="vocal.wav", length=3.0)
    o2, _ = H.render("svs_sum", sl(outmode=0, hardness=50),
                     input_name="vocal.wav", length=3.0)
    n = sec(3.0)
    summed = [o8[0][i] + o8[2][i] + o8[4][i] + o8[6][i] for i in range(n)]
    d = maxdiff(summed, o2[0][:n])
    # sum mode uses the exact-unity form 1+sum(c*(g-1)); split multiplies out.
    # identical algebra, different rounding -> tiny tolerance.
    H.report("sum_vs_split", d < 1e-6, "maxdiff=%g" % d)


def t_rates():
    for sr in (44100, 96000):
        n = int(1.5 * sr)
        x = [0.3 * math.sin(2 * math.pi * 220 * i / sr)
             + 0.05 * math.sin(2 * math.pi * 6000 * i / sr) for i in range(n)]
        p = H.write_input("rin%d.wav" % sr, [x, x], srate=sr)
        ref = read_wav(p)[1]
        out, _ = H.render("rate%d" % sr, sl(), input_name="rin%d.wav" % sr,
                          length=1.5, srate=sr)
        d = maxdiff(out[0][:n], ref[0])
        # same 5e-16 bound as unity (REAPER's denormal-prevention DC)
        H.report("rates", d < 5e-16, "%d Hz maxdiff=%g" % (sr, d))


# --- feature probe (debug build) -------------------------------------------

DBG_TAIL = """
// ---- debug tail (generated by render_test.py, never shipped) ----
dbg_cnt += 1;
dbg_k = floor(dbg_cnt / %(slot)d) %% 64;
dbg_v = 0;
dbg_k == 0 ? ( dbg_v = cprom; );
dbg_k == 1 ? ( dbg_v = hffrac_db; );
dbg_k == 2 ? ( dbg_v = cper * 100; );
dbg_k == 3 ? ( dbg_v = fb_db; );
dbg_k == 4 ? ( dbg_v = phr_db; );
dbg_k == 5 ? ( dbg_v = e_cons * 100; );
dbg_k == 6 ? ( dbg_v = es_dbg * 100; );
dbg_k == 7 ? ( dbg_v = eb_dbg * 100; );
dbg_k == 8 ? ( dbg_v = cs_r * 100; );
dbg_k == 9 ? ( dbg_v = cs_b * 100; );
dbg_k == 10 ? ( dbg_v = cs_s * 100; );
dbg_k == 11 ? ( dbg_v = cs_c * 100; );
dbg_v = max(-440, min(440, dbg_v)) * %(scale)g;
spl0 = dbg_k == 63 ? %(magic)g : dbg_v;
spl1 = spl0;
""" % dict(slot=DBG_SLOT, scale=DBG_SCALE, magic=DBG_MAGIC)

FEAT = ["cprom_db", "hffrac_db", "cper100", "fb_db", "phr_db",
        "e_cons100", "e_sib100", "e_br100",
        "cs_r100", "cs_b100", "cs_s100", "cs_c100"]


def t_features():
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "Magnolius_VocalSplitter.jsfx")
    dbg = H.build_debug_fx(src, DBG_TAIL)
    try:
        build_vocal_like("vocal.wav")
        out, _ = H.render("features", sl(), input_name="vocal.wav",
                          length=3.0, fx=os.path.basename(dbg))
        frames = {}
        for label, at in [("phrase", 0.55), ("breath", 1.25),
                          ("sib", 2.10), ("silence", 1.90)]:
            vals = decode_dbg(out, 12, at, srate=SRATE)[0]
            frames[label] = dict(zip(FEAT, vals))
        f = frames
        checks = [
            ("phrase is loud", f["phrase"]["fb_db"] > -30),
            ("phrase tracks level", abs(f["phrase"]["phr_db"]
                                        - f["phrase"]["fb_db"]) < 12),
            ("phrase not sib", f["phrase"]["e_sib100"] < 30),
            ("phrase not breath", f["phrase"]["e_br100"] < 30),
            ("breath quiet", f["breath"]["fb_db"] < f["breath"]["phr_db"] - 12),
            # a breath is noise, so its envelope must read APERIODIC
            ("breath aperiodic", f["breath"]["cper100"] < 70),
            ("breath evidence", f["breath"]["e_br100"] > 50),
            # LR4 edges + envelope smoothing keep even in-band noise a few dB
            # below 0; the plugin's default threshold is -8 for this reason.
            ("sib HF dominant", f["sib"]["hffrac_db"] > -12),
            ("sib evidence", f["sib"]["e_sib100"] > 50),
            ("sib confidence", f["sib"]["cs_s100"] > 50),
            ("breath confidence", f["breath"]["cs_b100"] > 50),
        ]
        bad = [name for name, ok in checks if not ok]
        detail = "; ".join(bad) if bad else "%d checks" % len(checks)
        if bad:
            for k, fr in frames.items():
                print("  frame %-8s %s" % (k, " ".join(
                    "%s=%.1f" % (n, v) for n, v in fr.items())))
        H.report("features", not bad, detail)
    finally:
        if os.environ.get("VSPLIT_KEEP_DBG") != "1":
            os.remove(dbg)


# unity/canary shared input: tone + quiet HF so several detectors get poked
UIN0 = [0.3 * math.sin(2 * math.pi * 220 * i / SRATE)
        + 0.05 * math.sin(2 * math.pi * 5500 * i / SRATE)
        for i in range(sec(2.0))]
UIN1 = [0.98 * v for v in UIN0]

if __name__ == "__main__":
    H.run([
        ("params", t_params),
        ("unity", t_unity),
        ("canary", t_canary),
        ("features", t_features),
        ("stems", t_stems),
        ("midword_cons", t_midword_cons),
        ("dark_cons", t_dark_cons),
        ("vowel_onset", t_vowel_onset),
        ("quiet_cons", t_quiet_cons),
        ("sustained_cons", t_sustained_cons),
        ("realclip", t_realclip),
        ("cons_prom", t_cons_prom),
        ("cons_dur", t_cons_dur),
        ("sib_onset", t_sib_onset),
        ("breath_split", t_breath_split),
        ("breath_gap", t_breath_gap),
        ("listen", t_listen),
        ("sum_vs_split", t_sum_vs_split),
        ("rates", t_rates),
    ])
