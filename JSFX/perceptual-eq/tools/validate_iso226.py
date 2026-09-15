#!/usr/bin/env python3
"""Validate the ISO 226:2003 equal-loudness math used in Magnolius_PerceptualEQ.jsfx.

Re-implements the same formula and parameter tables as the EEL2 code, then:
  1. asserts the formula identity Lp(1 kHz, phon) == phon (within 0.1 dB),
  2. asserts structural sanity of the contour shape,
  3. cross-checks the 40-phon contour against published reference values
     (the widely circulated iso226.m test vector),
  4. prints the band offsets relative to 1 kHz at the default 60 phon --
     these are the ISOREL values the plugin computes, for manual comparison.
"""

import math
import sys

FREQ = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500]

AF = [0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330,
      0.315, 0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244,
      0.243, 0.243, 0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301]

LU = [-31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5,
      -3.1, -2.0, -1.1, -0.4, 0.0, 0.3, 0.5, 0.0, -2.7, -4.1,
      -1.0, 1.7, 2.5, 1.2, -2.1, -7.1, -11.2, -10.7, -3.1]

TF = [78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9,
      14.4, 11.4, 8.6, 6.2, 4.4, 3.0, 2.2, 2.4, 3.5, 1.7,
      -1.3, -4.2, -6.0, -5.4, -1.5, 6.0, 12.6, 13.9, 12.3]

# Published 40-phon contour (iso226.m reference vector), dB SPL:
REF_40PHON = [99.85, 93.94, 88.17, 82.63, 77.78, 73.08, 68.48, 64.37, 60.59,
              56.70, 53.41, 50.40, 47.58, 44.98, 43.05, 41.34, 40.06, 40.01,
              41.82, 42.51, 39.23, 36.51, 35.61, 36.65, 40.01, 45.83, 51.80,
              54.28, 51.49]

BANDS = [40, 80, 125, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000,
         8000, 12000, 16000]


def contour(phon):
    """ISO 226:2003 contour: SPL (dB) at each table frequency for a phon level."""
    out = []
    for af, lu, tf in zip(AF, LU, TF):
        afv = 4.47e-3 * (10 ** (0.025 * phon) - 1.15) \
            + (0.4 * 10 ** ((tf + lu) / 10 - 9)) ** af
        out.append(10 / af * math.log10(afv) - lu + 94)
    return out


def interp_logf(f, spl):
    """Log-frequency linear interpolation, edge values held (same as plugin)."""
    if f <= FREQ[0]:
        return spl[0]
    if f >= FREQ[-1]:
        return spl[-1]
    i = 0
    while FREQ[i + 1] < f:
        i += 1
    x = (math.log(f) - math.log(FREQ[i])) / (math.log(FREQ[i + 1]) - math.log(FREQ[i]))
    return spl[i] + x * (spl[i + 1] - spl[i])


def main():
    failures = 0

    # 1. 1 kHz identity across the valid phon range
    for phon in range(20, 81, 5):
        got = contour(phon)[FREQ.index(1000)]
        if abs(got - phon) > 0.1:
            print(f"FAIL: Lp(1 kHz, {phon} phon) = {got:.3f}, expected ~{phon}")
            failures += 1

    # 2. Structural sanity at 60 phon: bass needs much more SPL than 1 kHz,
    #    3-4 kHz region needs less (ear canal resonance dip in the contour)
    c60 = contour(60)
    if not c60[0] > c60[FREQ.index(1000)] + 20:
        print("FAIL: 20 Hz should sit far above 1 kHz on the 60-phon contour")
        failures += 1
    if not c60[FREQ.index(3150)] < c60[FREQ.index(1000)]:
        print("FAIL: 3.15 kHz should sit below 1 kHz on the 60-phon contour")
        failures += 1

    # 3. Cross-check against the published 40-phon vector
    c40 = contour(40)
    worst = max(abs(a - b) for a, b in zip(c40, REF_40PHON))
    if worst > 0.3:
        print(f"FAIL: 40-phon contour deviates from published values "
              f"(worst {worst:.2f} dB)")
        for f, a, b in zip(FREQ, c40, REF_40PHON):
            if abs(a - b) > 0.3:
                print(f"       {f:>7} Hz: computed {a:.2f}, published {b:.2f}")
        failures += 1
    else:
        print(f"OK: 40-phon contour matches published values "
              f"(worst deviation {worst:.3f} dB)")

    if failures:
        print(f"\n{failures} check(s) FAILED")
        return 1

    print("OK: 1 kHz identity holds for 20..80 phon")
    print("OK: contour shape sanity checks pass")

    # 4. ISOREL values at the plugin's band frequencies, 60 phon
    ref1k = c60[FREQ.index(1000)]
    print("\nISOREL @ 60 phon (dB offset vs 1 kHz — compare with plugin bands):")
    for f in BANDS:
        rel = interp_logf(f, c60) - ref1k
        print(f"  {f:>6} Hz: {rel:+7.2f} dB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
