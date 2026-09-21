#!/usr/bin/env python3
"""Offline mixing-time (modulation onset) detector for reverb IRs.

Step 1 of the late-tail modulation work: this is the reference implementation
of the detector that Magnolius_ConvolutionReverb.jsfx runs inside rvb_build().
Keep the two in step - the .jsfx is the shipping copy, this one is what says
whether the numbers are plausible across a whole library.

Primary detector: Abel-Huang normalised echo density. For a window sliding
along the IR, measure the (Hann-weighted) fraction of samples whose magnitude
exceeds the window's standard deviation. For Gaussian noise that fraction
converges to erfc(1/sqrt(2)) = 0.3173, so dividing by it puts the profile near
0 in the sparse early region and at 1.0 once the response has gone diffuse.
The mixing time is the first point at which the profile reaches THRESH and
stays there for HOLD ms - the hold is what stops a dense early-reflection
cluster triggering it early.

Cross-check: excess kurtosis over the same window, large and positive while a
few big reflections dominate, falling toward 0 as the distribution turns
Gaussian. If the two disagree badly the IR is unusual; that is reported, not
silently averaged away.

Usage:
    ir_onset.py <file.wav|dir> ...        table of one line per IR
    ir_onset.py --profile <file.wav>      dump the full profile for one IR
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav  # noqa: E402

# erfc(1/sqrt(2)): the fraction of Gaussian samples above 1 sigma.
GAUSS_FRAC = 0.3173105078629141

WIN_MS = 20.0       # sliding window length
HOP_MS = 2.0        # hop between windows
THRESH = 0.90       # normalised echo density that counts as "diffuse"
HOLD_MS = 30.0      # ...and how long it must stay there
KURT_MAX = 1.0      # excess kurtosis that counts as "Gaussian enough"
SCAN_MS = 400.0     # how far in to look; widest raw result seen was 203
CLAMP_LO_MS = 10.0
CLAMP_HI_MS = 150.0
DEFAULT_MS = 60.0   # fallback when the detector does not converge
MIN_IR_MS = 500.0   # shorter than this: no modulation at all


def hann(n):
    if n < 2:
        return [1.0] * n
    return [0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1)) for i in range(n)]


def direct_index(x, frac=0.01):
    """First sample at or above frac of the channel peak.

    IRs carry leading silence and a pre-delay; the mixing time is a property
    of the room, measured from the direct sound, not from the file's frame 0.
    """
    pk = max((abs(v) for v in x), default=0.0)
    if pk <= 0.0:
        return None
    lim = pk * frac
    for i, v in enumerate(x):
        if abs(v) >= lim:
            return i
    return None


def profile(x, srate, t0, scan_ms=SCAN_MS):
    """(times_ms, echo_density, excess_kurtosis) from t0, in ms after t0.

    Times are the window CENTRE, not its start. The profile value describes
    the whole 20 ms span, and a window straddling the join is already mostly
    diffuse, so start-timing declares the mixing time about half a window
    early - which is the direction that costs us, since modulating before the
    mixing time is what the split exists to prevent.
    """
    win = max(8, int(round(WIN_MS * 0.001 * srate)))
    hop = max(1, int(round(HOP_MS * 0.001 * srate)))
    last = min(len(x) - win, t0 + int(scan_ms * 0.001 * srate))
    w = hann(win)
    wsum = sum(w)
    times, dens, kurt = [], [], []
    pos = t0
    while pos <= last:
        s2 = 0.0
        s4 = 0.0
        for i in range(win):
            v = x[pos + i]
            vv = v * v
            s2 += w[i] * vv
            s4 += w[i] * vv * vv
        m2 = s2 / wsum
        tc = (pos + win * 0.5 - t0) * 1000.0 / srate
        if m2 <= 0.0:
            times.append(tc)
            dens.append(0.0)
            kurt.append(0.0)
            pos += hop
            continue
        sigma = math.sqrt(m2)
        above = 0.0
        for i in range(win):
            if abs(x[pos + i]) > sigma:
                above += w[i]
        times.append(tc)
        dens.append((above / wsum) / GAUSS_FRAC)
        kurt.append(s4 / wsum / (m2 * m2) - 3.0)
        pos += hop
    return times, dens, kurt


def first_sustained(times, vals, ok, hold_ms=HOLD_MS):
    """First time in `times` where ok(val) holds continuously for hold_ms."""
    run_from = None
    for t, v in zip(times, vals):
        if ok(v):
            if run_from is None:
                run_from = t
            elif t - run_from >= hold_ms:
                return run_from
        else:
            run_from = None
    # a run that reaches the end of the scan still counts if it is long enough
    if run_from is not None and times and times[-1] - run_from >= hold_ms:
        return run_from
    return None


def analyse_channel(x, srate):
    t0 = direct_index(x)
    if t0 is None:
        return None
    times, dens, kurt = profile(x, srate, t0)
    if not times:
        return None
    ed = first_sustained(times, dens, lambda v: v >= THRESH)
    kt = first_sustained(times, kurt, lambda v: v <= KURT_MAX)
    return {"t0": t0, "t0_ms": t0 * 1000.0 / srate,
            "echo_ms": ed, "kurt_ms": kt,
            "times": times, "dens": dens, "kurt": kurt}


def median(vals):
    s = sorted(vals)
    n = len(s)
    if not n:
        return None
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def analyse(path, combine="median"):
    srate, chans = read_wav(path)
    frames = len(chans[0])
    dur_ms = frames * 1000.0 / srate
    per = [analyse_channel(c, srate) for c in chans]
    good = [p for p in per if p]
    echo = [p["echo_ms"] for p in good if p["echo_ms"] is not None]
    kur = [p["kurt_ms"] for p in good if p["kurt_ms"] is not None]
    t0s = [p["t0_ms"] for p in good]

    converged = len(echo) >= 1
    if converged:
        raw = median(echo) if combine == "median" else max(echo)
    else:
        raw = DEFAULT_MS
    onset = min(max(raw, CLAMP_LO_MS), CLAMP_HI_MS)

    # The IR's own pre-delay sits in front of the direct sound; the plugin
    # needs an offset from frame 0, which is where its partitions start.
    t0_ms = median(t0s) if t0s else 0.0
    abs_ms = t0_ms + onset

    disagree = None
    if converged and kur:
        disagree = abs(median(kur) - raw)

    return {"path": path, "srate": srate, "nch": len(chans),
            "dur_ms": dur_ms, "t0_ms": t0_ms,
            "per_ch_echo": echo, "per_ch_kurt": kur,
            "raw_ms": raw, "onset_ms": onset, "abs_ms": abs_ms,
            "converged": converged, "disagree_ms": disagree,
            "too_short": dur_ms < MIN_IR_MS}


def fmt(v, w=6, p=1):
    return ("%*.*f" % (w, p, v)) if v is not None else "%*s" % (w, "-")


def wavs(args):
    out = []
    for a in args:
        if os.path.isdir(a):
            for name in sorted(os.listdir(a)):
                if name.lower().endswith(".wav"):
                    out.append(os.path.join(a, name))
        else:
            out.append(a)
    return out


def main():
    args = sys.argv[1:]
    if args and args[0] == "--profile":
        path = args[1]
        srate, chans = read_wav(path)
        p = analyse_channel(chans[0], srate)
        print("# %s  ch0  t0=%d (%.1f ms)" % (path, p["t0"], p["t0_ms"]))
        print("# ms_after_direct  echo_density  excess_kurtosis")
        for t, d, k in zip(p["times"], p["dens"], p["kurt"]):
            print("%8.1f %12.4f %14.3f" % (t, d, k))
        return
    if not args:
        print(__doc__)
        sys.exit(2)

    print("%-46s %5s %4s %7s %6s %7s %7s %5s  %s"
          % ("IR", "sr/k", "ch", "len_ms", "pre_ms", "onset", "abs_ms",
             "parts", "notes"))
    for path in wavs(args):
        try:
            r = analyse(path)
        except Exception as e:
            print("%-46s  ERROR %s" % (os.path.basename(path)[:46], e))
            continue
        notes = []
        if not r["converged"]:
            notes.append("NO-CONVERGE(default)")
        if r["too_short"]:
            notes.append("TOO-SHORT(bypass)")
        if r["disagree_ms"] is not None and r["disagree_ms"] > 40.0:
            notes.append("KURT-DISAGREE(%.0fms)" % r["disagree_ms"])
        if r["raw_ms"] != r["onset_ms"]:
            notes.append("CLAMPED(from %.0f)" % r["raw_ms"])
        spread = (max(r["per_ch_echo"]) - min(r["per_ch_echo"])) \
            if len(r["per_ch_echo"]) > 1 else 0.0
        if spread > 40.0:
            notes.append("CH-SPREAD(%.0fms)" % spread)
        # the plugin can only split on a partition boundary (2048 samples)
        parts = int(r["abs_ms"] * 0.001 * r["srate"] // 2048)
        print("%-46s %5.1f %4d %7.0f %6.1f %s %s %5d  %s"
              % (os.path.basename(path)[:46], r["srate"] / 1000.0, r["nch"],
                 r["dur_ms"], r["t0_ms"], fmt(r["onset_ms"]), fmt(r["abs_ms"]),
                 parts, " ".join(notes)))


if __name__ == "__main__":
    main()
