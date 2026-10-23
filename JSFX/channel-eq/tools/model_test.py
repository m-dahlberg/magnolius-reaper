#!/usr/bin/env python3
"""Pure-Python checks of tools/model.py: the laws, the analog prototypes and the
digital design.  No REAPER needed.

    ./model_test.py              # everything
    ./model_test.py laws mirror

These assert what the design promises (tabulated gain law, exact mirror between
boost and cut, shelf dip, corner ranges, bell widths, filter slopes, stability,
accuracy of the digital design against its analog prototype).  They check the
model against the formulas it was built from; there is no reference unit, so
they cannot say the circuit was read correctly.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M                                                   # noqa: E402


def db(x):
    return 20 * math.log10(max(x, 1e-300))


def with_(**kw):
    p = dict(M.DEFAULTS)
    p.update(kw)
    return p


def sec(p, name, fs=96000):
    for n, _, proto in M.analog_sections(p, fs):
        if n == name:
            return proto
    raise KeyError(name)


def octave_width(proto, f0, drop=3.0):
    """Width in octaves where a bell is within `drop` dB of its peak."""
    pk = db(M.analog_mag(proto, f0))
    lo = hi = f0
    f = f0
    while f > 1 and db(M.analog_mag(proto, f)) > pk - drop:
        f /= 1.001
    lo = f
    f = f0
    while f < 1e6 and db(M.analog_mag(proto, f)) > pk - drop:
        f *= 1.001
    hi = f
    return math.log2(hi / lo)


def test_laws():
    # printed numbers sit at equal angles and the law passes through them
    bad = []
    for leg, xs0, dx in ((M.LEG_HF, 0, 1 / 6), (M.LEG_HMF, 0, 1 / 6), (M.LEG_LMF, 0, 1 / 6),
                         (M.LEG_LF, 0, 1 / 5), (M.LEG_Q, 0, 1 / 4)):
        n = len(leg)
        xs = [k / (n - 1) for k in range(n)]
        for k, v in enumerate(leg):
            if abs(math.exp(M.pw_log(xs[k], xs, leg)) - v) > 1e-9 * v:
                bad.append((leg, k))
    # monotone
    for leg in (M.LEG_HF, M.LEG_HMF, M.LEG_LMF, M.LEG_LF):
        us = [M.legend_u(i / 200, leg) for i in range(201)]
        if any(b <= a for a, b in zip(us, us[1:])) or abs(us[0]) > 1e-12 or abs(us[-1] - 1) > 1e-12:
            bad.append(("u", leg))
    qs = [M.q0_of(i / 100) for i in range(101)]
    if any(b <= a for a, b in zip(qs, qs[1:])) or abs(qs[0] - 0.73) > 1e-9 or abs(qs[-1] - 2.95) > 1e-9:
        bad.append("q0")
    return not bad, "legend values land on their knob positions, laws monotone, Q0 0.73 .. 2.95" if not bad else str(bad)


def test_gain_table():
    worst = 0.0
    for r in [i / 10 for i in range(1, 11)]:
        for tab, band in ((M.TAB_MID, "hmf"), (M.TAB_HF, "hf"), (M.TAB_LF, "lf"), (M.TAB_MID, "lmf")):
            want = M.tab_interp(tab, r)
            p = with_(**{band + "_g": r, band + "_f": 0.5})
            proto = sec(p, band)
            if band in ("hmf", "lmf"):
                # centre of the bell: sqrt(n0/d0 ... ) -> evaluate at w0 = sqrt(d0)
                f0 = math.sqrt(proto[5]) / (2 * math.pi)
                got = db(M.analog_mag(proto, f0))
            elif band == "hf":
                got = db(M.analog_mag(proto, 1e8))
            else:
                got = max(db(M.analog_mag(proto, 5 * (3000 / 5) ** (i / 400))) for i in range(401))
            worst = max(worst, abs(got - want))
    return worst < 0.06, "boost at the plateau / centre matches the table to %.3f dB (all bands, 10 steps)" % worst


def test_mirror():
    worst = 0.0
    rng = random.Random(2)
    for _ in range(30):
        r = rng.uniform(0.05, 1.0)
        for band in ("hf", "hmf", "lmf", "lf"):
            kw = {band + "_f": rng.random(), band + "_g": r}
            if band in ("hmf", "lmf"):
                kw[band + "_q"] = rng.random()
            pb, pc = with_(**kw), with_(**dict(kw, **{band + "_g": -r}))
            a, b = sec(pb, band), sec(pc, band)
            for i in range(60):
                f = 20 * (20000 / 20) ** (i / 59)
                worst = max(worst, abs(db(M.analog_mag(a, f)) + db(M.analog_mag(b, f))))
    return worst < 1e-9, "cut is the exact mirror of boost (%.2g dB)" % worst


def test_shelves():
    ok = True
    notes = []
    # HF dip below the corner at full boost: ~1.9 dB
    proto = sec(with_(hf_g=1.0, hf_f=0.5), "hf")
    dip = min(db(M.analog_mag(proto, 100 * 10 ** (i / 100))) for i in range(200))
    notes.append("HF dip %.2f dB (spec ~ -1.9)" % dip)
    ok &= -2.1 < dip < -1.7
    # HF corner at the low end of the knob: -3 dB from plateau ~ 2.3 kHz
    proto = sec(with_(hf_g=1.0, hf_f=0.0), "hf")
    plat = db(M.analog_mag(proto, 1e8))
    f = 100.0
    while db(M.analog_mag(proto, f)) < plat - 3:
        f *= 1.001
    notes.append("HF corner at the low stop %.2f kHz (spec 2.3)" % (f / 1000))
    ok &= abs(f - 2300) < 120
    # LF corners at full boost: 31 and 361 Hz, and the rollback below the corner
    for t, want, tol in ((0.0, 31, 2), (1.0, 361, 12)):
        proto = sec(with_(lf_g=1.0, lf_f=t), "lf")
        fs_ = [2 * (3000 / 2) ** (i / 3000) for i in range(3001)]
        ms = [db(M.analog_mag(proto, f)) for f in fs_]
        pk = max(ms)
        ip = ms.index(pk)
        corner = next(f for f, m in zip(fs_[ip:], ms[ip:]) if m < pk - 3)
        roll = pk - ms[0]
        notes.append("LF corner %.0f Hz (spec %d), peak %.2f dB, rollback to DC %.2f dB" % (corner, want, pk, roll))
        ok &= abs(corner - want) < tol and abs(pk - 18.4) < 0.06
        if t == 1.0:
            ok &= 0.5 < roll < 1.5          # spec says 0.5 .. 1.2 dB; see the README
    return ok, "; ".join(notes)


def test_bells():
    notes = []
    ok = True
    # width narrows as gain rises (Q0 = 0.73: 3.7 -> 1.85 octaves from +4 to +21 dB)
    ws = []
    r4 = 4.0 / 21.0 * 0.0
    # rotation whose table gain is +4 dB
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if M.tab_interp(M.TAB_MID, mid) < 4.0 else (lo, mid)
    for r, label in (((lo + hi) / 2, "+4"), (1.0, "+21")):
        p = with_(hmf_g=r, hmf_f=0.5, hmf_q=0.0)
        proto = sec(p, "hmf")
        f0 = math.sqrt(proto[5]) / (2 * math.pi)
        ws.append(octave_width(proto, f0))
    notes.append("width at Q0 0.73: %.2f oct at +4 dB, %.2f oct at +21 dB (spec 3.7 -> 1.85)" % tuple(ws))
    ok &= abs(ws[0] - 3.7) < 0.35 and abs(ws[1] - 1.85) < 0.2 and ws[1] < ws[0]
    # maximum boost holds across Q
    gains = []
    for t in (0, 0.25, 0.5, 0.75, 1.0):
        proto = sec(with_(lmf_g=1.0, lmf_f=0.5, lmf_q=t), "lmf")
        f0 = math.sqrt(proto[5]) / (2 * math.pi)
        gains.append(db(M.analog_mag(proto, f0)))
    notes.append("max boost across Q %.2f .. %.2f dB" % (min(gains), max(gains)))
    ok &= max(gains) - min(gains) < 1e-6 and abs(gains[0] - 21.0) < 1e-6
    # centre frequencies at the end-stops and the x3 / div switches
    a = sec(with_(hmf_g=1.0, hmf_f=0.0), "hmf")
    b = sec(with_(hmf_g=1.0, hmf_f=1.0, hmf_x3=1), "hmf")
    c = sec(with_(lmf_g=1.0, lmf_f=0.0, lmf_d3=1), "lmf")
    fa, fb, fc = (math.sqrt(x[5]) / (2 * math.pi) for x in (a, b, c))
    notes.append("HMF %.0f Hz .. x3 top %.1f kHz, LMF /3 bottom %.1f Hz" % (fa, fb / 1000, fc))
    ok &= abs(fa - 605) < 1 and abs(fb - 6200 * 5.02 / 1.72) < 5 and abs(fc - 202 / (62 / 15)) < 0.5
    return ok, "; ".join(notes)


def test_filters():
    notes = []
    ok = True
    # HPF: 3rd order Butterworth, -3 dB at its frequency, 18 dB/oct
    p = with_(hpf=0.6)
    h1, h2 = sec(p, "hpf1"), sec(p, "hpf2")
    f0 = h1[5] / (2 * math.pi)

    def hp(f):
        return M.analog_mag(h1, f) * M.analog_mag(h2, f)
    at = db(hp(f0))
    slope = db(hp(f0 / 10))
    notes.append("HPF %.0f Hz: %.2f dB at f0, %.1f dB a decade below" % (f0, at, slope))
    ok &= abs(at + 3.01) < 0.02 and abs(slope + 60) < 0.5
    # LPF: 2nd order, Q ~ 0.72, 12 dB/oct
    p = with_(lpf=0.5)
    s = sec(p, "lpf")
    f0 = math.sqrt(s[5]) / (2 * math.pi)
    at = db(M.analog_mag(s, f0))
    slope = db(M.analog_mag(s, f0 * 10))
    notes.append("LPF %.0f Hz: %.2f dB at f0, %.1f dB a decade above" % (f0, at, slope))
    ok &= abs(at - db(M.LPF_Q)) < 0.01 and abs(slope + 40) < 0.7
    # OUT at the stops, and the end-stops of the pots
    ok &= not M.analog_sections(with_(hpf=0.0), 48000) and not [n for n, _, _ in M.analog_sections(with_(lpf=1.0), 48000)]
    lo = sec(with_(hpf=0.05), "hpf1")[5] / (2 * math.pi)
    hi = sec(with_(hpf=1.0), "hpf1")[5] / (2 * math.pi)
    lp_lo = math.sqrt(sec(with_(lpf=0.0), "lpf")[5]) / (2 * math.pi)
    notes.append("HPF range %.1f .. %.0f Hz, LPF stop %.0f Hz" % (lo, hi, lp_lo))
    ok &= abs(lo - 14.8) < 0.1 and abs(hi - 350) < 1 and abs(lp_lo - 3200) < 1
    return ok, "; ".join(notes)


def test_neutral():
    p = dict(M.DEFAULTS)
    ok = all(c == M.IDENT for c in M.targets(p, 48000))
    p2 = with_(hf_g=1, lmf_g=0.5, hpf=0.5, lpf=0.2, eq_in=0, flt_in=0)
    ok &= all(c == M.IDENT for c in M.targets(p2, 48000))
    p3 = with_(sat_amt=1.0, sat_mode=1)
    ok &= all(c == M.IDENT for c in M.targets(p3, 48000))
    return ok, "defaults, both bypass switches and the saturation controls leave every slot at the identity"


def test_stable():
    rng = random.Random(4)
    worst = 0.0
    n = 0
    for fs in (8000, 11025, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000):
        for _ in range(15):
            p = dict(M.DEFAULTS)
            for k in ("lf_g", "lmf_g", "hmf_g", "hf_g"):
                p[k] = rng.choice([-1, 1, rng.uniform(-1, 1)])
            for k in ("lf_f", "lmf_f", "hmf_f", "hf_f", "lmf_q", "hmf_q"):
                p[k] = rng.choice([0, 1, rng.random()])
            p["hpf"] = rng.choice([0.05, 0.5, 1.0])
            p["lpf"] = rng.choice([0.0, 0.5, 0.9])
            p["hmf_x3"] = rng.choice([0, 1])
            for c in M.targets(p, fs):
                n += 1
                if not M.stable(c):
                    return False, "unstable section at %d Hz: %r" % (fs, c)
                worst = max(worst, abs(c[4]))
    return True, "%d sections stable at 8 .. 192 kHz (largest |a2| %.6f)" % (n, worst)


def test_accuracy():
    rng = random.Random(11)
    limits = {44100: 0.12, 48000: 0.12, 88200: 0.02, 96000: 0.02, 192000: 0.01}
    out = []
    ok = True
    f15 = [20 * (15000 / 20) ** (i / 60) for i in range(61)]
    f20 = [15000 + 5000 * i / 20 for i in range(21)]
    for fs, lim in limits.items():
        w15 = w20 = 0.0
        for _ in range(30):
            p = dict(M.DEFAULTS)
            for k in ("lf_g", "lmf_g", "hmf_g", "hf_g"):
                p[k] = rng.choice([-1, -.5, 0.3, 0.7, 1.0, rng.uniform(-1, 1)])
            for k in ("lf_f", "lmf_f", "hmf_f", "hf_f", "lmf_q", "hmf_q"):
                p[k] = rng.choice([0, 1, rng.random(), rng.random()])
            p["hpf"] = rng.choice([0, 0.05, 0.3, 0.7, 1.0])
            p["lpf"] = rng.choice([1.0, 0.9, 0.5, 0.0])
            p["hmf_x3"] = rng.choice([0, 1])
            p["lmf_d3"] = rng.choice([0, 1])
            p["gain_law"] = rng.choice([0, 1])
            w15 = max(w15, M.response_error_db(p, fs, f15))
            w20 = max(w20, M.response_error_db(p, fs, f20))
        out.append("%.1fk: %.3f dB (15-20k %.2f)" % (fs / 1000, w15, w20))
        ok &= w15 < lim
    return ok, "digital vs analog, whole chain, worst case to 15 kHz: " + ", ".join(out)


TESTS = [("laws", test_laws), ("table", test_gain_table), ("mirror", test_mirror),
         ("shelves", test_shelves), ("bells", test_bells), ("filters", test_filters),
         ("neutral", test_neutral), ("stable", test_stable), ("accuracy", test_accuracy)]

if __name__ == "__main__":
    sel = sys.argv[1:]
    bad = 0
    ran = 0
    for name, fn in TESTS:
        if sel and name not in sel:
            continue
        ran += 1
        try:
            ok, msg = fn()
        except Exception as e:                                      # noqa: BLE001
            import traceback
            traceback.print_exc()
            ok, msg = False, "EXCEPTION %s" % e
        print("%-9s %s  %s" % (name, "PASS" if ok else "FAIL", msg))
        bad += not ok
    print("----\n%d/%d passed" % (ran - bad, ran))
    sys.exit(1 if bad else 0)
