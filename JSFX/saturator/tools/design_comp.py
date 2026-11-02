#!/usr/bin/env python3
"""Designs the ADAA droop-compensation FIRs used by Magnolius_Saturator.jsfx.

    python3 tools/design_comp.py

At 2x and 4x the Asymmetric and Symmetric curves run first-order ADAA.  For
the linear part of a curve, ADAA is exactly (1 + z^-1)/2 -- half a sample of
delay and a cos(w/2) droop -- so two stages give cos^2(w/2).  This fits a
symmetric FIR to 1/cos^2(w/2) up to 20 kHz at the LOWEST base rate we care
about (44.1 kHz, the worst case), with a light pull above that so the boost
stays bounded where the decimator has to clean up anyway.  DC is renormalised
to exactly 1.

The taps are odd in count, (2L + 1), with L odd, so the ADAA delay (1 OS
sample) plus the FIR delay (L) is a whole number of base samples:
    2x: L = 5 -> 6 OS samples = 3 base samples
    4x: L = 3 -> 4 OS samples = 1 base sample

Paste the printed taps into COMP2_* / COMP4_* in the .jsfx and model.py.
"""
import math


def solve(A, b):
    n = len(b)
    M = [r[:] + [b[i]] for i, r in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]
                for k in range(c, n + 1):
                    M[r][k] -= f * M[c][k]
    return [M[i][n] / M[i][i] for i in range(n)]


def design(wmax, L, hiw=0.02, hicap=2.0):
    rows, tgt, wts = [], [], []
    for i in range(400):
        w = wmax * i / 399
        rows.append([1] + [2 * math.cos(k * w) for k in range(1, L + 1)])
        tgt.append(1 / math.cos(w / 2) ** 2)
        wts.append(1.0)
    for i in range(1, 200):
        w = wmax + (math.pi - wmax) * i / 199
        rows.append([1] + [2 * math.cos(k * w) for k in range(1, L + 1)])
        tgt.append(min(hicap, 1 / max(math.cos(w / 2) ** 2, 1e-9)))
        wts.append(hiw)
    n = L + 1
    A = [[0.0] * n for _ in range(n)]
    b = [0.0] * n
    for r, t, wt in zip(rows, tgt, wts):
        for i in range(n):
            b[i] += wt * r[i] * t
            for j in range(n):
                A[i][j] += wt * r[i] * r[j]
    c = solve(A, b)
    s = c[0] + 2 * sum(c[1:])
    return [x / s for x in c]


def resp(c, w):
    return c[0] + 2 * sum(c[k] * math.cos(k * w) for k in range(1, len(c)))


def main():
    for name, os_f, L in (("COMP2", 2, 5), ("COMP4", 4, 3)):
        wmax = 2 * math.pi * 20000 / (44100 * os_f)
        c = design(wmax, L)
        err = max(abs(20 * math.log10(resp(c, w) * math.cos(w / 2) ** 2))
                  for w in [wmax * i / 400 for i in range(401)])
        print("%s (L=%d): pass-band error %.3f dB to 20 kHz at 44.1k" % (name, L, err))
        for k, v in enumerate(c):
            print("  %s_%d = %.15f;" % (name, k, v))


if __name__ == "__main__":
    main()
