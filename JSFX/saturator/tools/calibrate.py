#!/usr/bin/env python3
"""Measures the auto-gain table and writes it into Magnolius_Saturator.jsfx.

    python3 tools/calibrate.py            # measure, write, then check
    python3 tools/calibrate.py --check    # only the off-grid check

Auto gain is static (the brief): Input is divided out exactly, then a
correction in dB is looked up for the Input / Slew / Asymmetric / Symmetric
position and Knee.  Each grid point here runs model.py at 2x on pink noise
(band-limited to 20 Hz upward) at
-18 dBFS RMS with auto gain on and an all-zero table, and stores
    correction = RMS(input) - RMS(output)   [dB]
so that, at the reference level, the output RMS equals the input RMS.

Grid: Input -18..+18 dB in 6 dB steps, Slew / Asym / Sym 0..100 % in 25 %
steps.  With Symmetric at 0 the Knee does nothing, so that column is
measured once and shared.  A point with no colour at all (Slew, Asym and
Sym 0) is exactly 0 dB: the chain is linear there.

The check renders off-grid settings (between the grid points, where the
interpolation is worst) and reports the level error, which the brief wants
within +-1 dB.

Stdlib only; uses every core.  Takes a few minutes.
"""
import math
import multiprocessing as mp
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M  # noqa: E402

SR = 48000
REF_DB = -18.0          # pink noise RMS, dBFS (brief)
SETTLE = 0.1            # s skipped before measuring
DUR = 0.8               # s per measurement
OS_I = 1                # 2x, the default


class LCG:
    def __init__(self, seed):
        self.s = seed

    def uni(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s / 0x3FFFFFFF - 1.0


def pink(n, seed=7, level_db=REF_DB):
    """Pink noise band-limited to 20 Hz upward, scaled to an exact RMS.

    Paul Kellet's refined pink filter on uniform white noise, then two
    one-pole high-passes at 20 Hz (1 s of pre-roll discarded).  Without the
    high-pass the filter's slowest pole (~9 Hz) makes the RMS of a one-second
    excerpt wander with the seed, and at heavy drive the measured level change
    then moved by +-1 dB from one seed to the next; band-limited, it moves by
    under 0.2 dB."""
    r = LCG(seed)
    b0 = b1 = b2 = b3 = b4 = b5 = b6 = 0.0
    hp_r = math.exp(-2 * math.pi * 20.0 / SR)
    xp1 = yp1 = xp2 = yp2 = 0.0
    out = []
    pre = SR
    for k in range(n + pre):
        w = r.uni()
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        v = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        yp1 = v - xp1 + hp_r * yp1
        xp1 = v
        yp2 = yp1 - xp2 + hp_r * yp2
        xp2 = yp1
        if k >= pre:
            out.append(yp2)
    rms = math.sqrt(sum(v * v for v in out) / n)
    g = 10 ** (level_db / 20) / rms
    return [v * g for v in out]


NOISE = None


def noise():
    global NOISE
    if NOISE is None:
        NOISE = pink(int((SETTLE + DUR) * SR) + M.LAT[OS_I])
    return NOISE


def level_change(kw, table=None, os_i=OS_I, srate=SR, x=None):
    """Output RMS minus input RMS, in dB, for one setting (mono, model)."""
    x = x or noise()
    m = M.Model(srate=srate, os_i=os_i,
                ag_table=table if table is not None else [0.0] * len(M.read_ag_table()),
                auto_gain=1, mix=100.0, **kw)
    lat = M.LAT[os_i]
    y = []
    for v in x:
        m.tick()
        y.append(m.chL.process(v) * m.gout)
    a = int(SETTLE * srate)
    seg_in = x[a:len(x) - lat]
    seg_out = y[a + lat:]
    ri = sum(v * v for v in seg_in) / len(seg_in)
    ro = sum(v * v for v in seg_out) / len(seg_out)
    return 10 * math.log10(ro / ri)


def grid_kw(gi, si, ai, yi, k):
    return dict(input_db=M.AG_GMIN + gi * M.AG_GSTEP, slew=100.0 * si / (M.AG_NS - 1),
                asym=100.0 * ai / (M.AG_NA - 1), sym=100.0 * yi / (M.AG_NY - 1), knee=k)


def job(args):
    k, gi, si, ai, yi = args
    if si == 0 and ai == 0 and yi == 0:
        return args, 0.0
    return args, -level_change(grid_kw(gi, si, ai, yi, k))


def index(k, gi, si, ai, yi):
    return (((k * M.AG_NG + gi) * M.AG_NS + si) * M.AG_NA + ai) * M.AG_NY + yi


def measure():
    jobs = [(k, gi, si, ai, yi)
            for k in range(3) for gi in range(M.AG_NG) for si in range(M.AG_NS)
            for ai in range(M.AG_NA) for yi in range(M.AG_NY)
            if yi > 0 or k == 0]
    tab = [0.0] * (3 * M.AG_NG * M.AG_NS * M.AG_NA * M.AG_NY)
    with mp.Pool() as pool:
        done = 0
        for (k, gi, si, ai, yi), v in pool.imap_unordered(job, jobs, chunksize=4):
            tab[index(k, gi, si, ai, yi)] = v
            if yi == 0:
                for kk in (1, 2):
                    tab[index(kk, gi, si, ai, yi)] = v
            done += 1
            if done % 100 == 0:
                print("  %d / %d" % (done, len(jobs)), flush=True)
    return tab


def write_table(tab):
    rows = []
    n = M.AG_NY
    for r in range(len(tab) // n):
        vals = ",".join("%.4f" % (tab[r * n + j] + 0.0) for j in range(n))
        rows.append("  ag_row(%d,%s);" % (r, vals))
    block = ("// >>> AUTOGAIN TABLE (generated by tools/calibrate.py - do not edit by hand)\n"
             "  // rows: [knee][input][slew][asym], five Sym values each, dB\n"
             + "\n".join(rows) + "\n// <<< AUTOGAIN TABLE")
    src = open(M.JSFX).read()
    new, n_sub = re.subn(r"// >>> AUTOGAIN TABLE.*?// <<< AUTOGAIN TABLE",
                         lambda _m: block, src, flags=re.S)
    if n_sub != 1:
        raise RuntimeError("AUTOGAIN TABLE markers not found in the .jsfx")
    open(M.JSFX, "w").write(new)


CHECK = [  # off-grid points: (input, slew, asym, sym, knee)
    (0, 0, 0, 12.5, 1), (0, 0, 12.5, 0, 1), (0, 12.5, 0, 0, 1),
    (3, 37.5, 62.5, 87.5, 0), (-9, 62.5, 37.5, 12.5, 2), (9, 87.5, 12.5, 62.5, 1),
    (15, 12.5, 87.5, 37.5, 2), (-15, 87.5, 87.5, 87.5, 0), (15, 87.5, 87.5, 87.5, 2),
    (18, 100, 100, 100, 0), (18, 0, 0, 100, 2), (12, 50, 0, 70, 0),
    (-3, 30, 50, 50, 1), (6, 0, 100, 0, 1), (9, 40, 20, 90, 2), (0, 100, 0, 0, 1),
]


def check_job(c):
    g, s, a, y, k = c
    return c, level_change(dict(input_db=g, slew=s, asym=a, sym=y, knee=k),
                           table=M.read_ag_table())


def check():
    worst = 0.0
    with mp.Pool() as pool:
        for c, d in pool.imap(check_job, CHECK):
            worst = max(worst, abs(d))
            print("  input %+5.1f slew %5.1f asym %5.1f sym %5.1f knee %d : %+.2f dB" % (c + (d,)))
    print("worst off-grid error %.2f dB" % worst)
    return worst


def main():
    if "--check" not in sys.argv:
        print("measuring %d-point grid at 2x ..." % (3 * M.AG_NG * M.AG_NS * M.AG_NA * M.AG_NY))
        write_table(measure())
        print("table written to", os.path.normpath(M.JSFX))
    sys.exit(0 if check() <= 1.0 else 1)


if __name__ == "__main__":
    main()
