#!/usr/bin/env python3
"""Generate test impulse responses for Magnolius_ConvolutionReverb.jsfx.

Writes 4-channel (and fallback-format) WAVs into REAPER's Data/ReverbIRs
directory, which the plugin's IR file slider serves.

True-stereo channel convention (input letter first):
  ch1 = L->L, ch2 = L->R, ch3 = R->L, ch4 = R->R

The plugin energy-normalizes IRs on load, so impulse amplitude (0.5 here,
to stay clear of integer clipping if files get converted) still yields
exactly unity gain through the wet path — that is what the render tests rely on.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import write_wav_f32


def impulse(n, pos, amp=0.5):
    v = [0.0] * n
    v[pos] = amp
    return v


def zeros(n):
    return [0.0] * n


def mixing_ir(srate, secs, pre_ms, mix_ms, seed, decay=4.0):
    """4-channel IR with a designed mixing time.

    Silence for pre_ms, a direct impulse, then sparse discrete reflections for
    mix_ms, then continuous decaying noise. That join is what the echo-density
    detector has to find, so it is the only fixture in here whose expected
    answer is a time rather than a gain.

    The two regions are level-matched: the sparse region's impulses are large
    and rare, the diffuse region's samples small and continuous, both landing
    at a comparable RMS. A step in level would let the detector cheat.
    """
    n = int(srate * secs)
    t_dir = int(srate * pre_ms * 0.001)
    t_mix = t_dir + int(srate * mix_ms * 0.001)
    rnd = random.Random(seed)
    chans = []
    for ch in range(4):
        v = [0.0] * n
        v[t_dir] = 0.6 if ch in (0, 3) else 0.25   # direct: cross paths quieter
        # sparse region: one reflection every ~1.2 ms, jittered
        t = t_dir + int(srate * 0.002)
        while t < t_mix:
            v[t] = (rnd.random() * 2 - 1) * 0.35 * math.exp(-2.0 *
                                                            (t - t_dir) / (t_mix - t_dir))
            t += max(8, int(srate * 0.0012 * (0.5 + rnd.random())))
        # diffuse region: continuous noise on the same decay
        for t in range(t_mix, n):
            v[t] = (rnd.random() * 2 - 1) * 0.05 * math.exp(-decay * (t - t_mix) / n)
        chans.append(v)
    return chans


def truestereo_ir(srate, secs, pre_ms, mix_ms, seed, itd_ms=0.35, cross=0.7):
    """4-channel IR that actually behaves like a true-stereo capture.

    Each input source gets ONE room response, and the two mic channels are
    that response at slightly different times and levels. LL and LR therefore
    carry the inter-channel relationship that places the source - which is
    exactly what the modulator's A/B pairing has to preserve.

    test_hall4.wav cannot test that: its four channels are independent noise,
    so LL and LR have no relationship to break and pairing by input or by
    output measures identically.
    """
    base = mixing_ir(srate, secs, pre_ms, mix_ms, seed)
    n = len(base[0])
    d = int(srate * itd_ms * 0.001)

    def lag(v):
        return [0.0] * d + v[:n - d]

    near_l, near_r = base[0], base[3]
    #      LL          LR (far mic)              RL (far mic)              RR
    return [near_l, [cross * x for x in lag(near_l)],
            [cross * x for x in lag(near_r)], near_r]


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.config/REAPER/Data/ReverbIRs")
    os.makedirs(outdir, exist_ok=True)

    n = 4096
    # identity: unit impulse in LL and RR -> wet output == input
    write_wav_f32(os.path.join(outdir, "test_unity4.wav"), 48000,
                  [impulse(n, 0), zeros(n), zeros(n), impulse(n, 0)])
    # cross only: impulse in LR and RL -> wet output == input with L/R swapped
    write_wav_f32(os.path.join(outdir, "test_swap4.wav"), 48000,
                  [zeros(n), impulse(n, 0), impulse(n, 0), zeros(n)])
    # delayed impulse crossing partition boundaries (P=2048 -> partition 2)
    n2 = 8192
    write_wav_f32(os.path.join(outdir, "test_delay5k4.wav"), 48000,
                  [impulse(n2, 5000), zeros(n2), zeros(n2), impulse(n2, 5000)])
    # 2-channel fallback: parallel stereo (LL, RR)
    write_wav_f32(os.path.join(outdir, "test_unity2.wav"), 48000,
                  [impulse(n, 0), impulse(n, 0)])
    # sample-rate mismatch: 96k IR, impulse at 9600 -> 4800 samples in a 48k project
    n96 = 19200
    write_wav_f32(os.path.join(outdir, "test_delay96k.wav"), 96000,
                  [impulse(n96, 9600), zeros(n96), zeros(n96), impulse(n96, 9600)])
    # dense decaying-noise true-stereo hall (~5.4 s): listening + worst-case CPU
    rnd = random.Random(1)
    nl = 260000
    chans = []
    for _ in range(4):
        chans.append([(rnd.random() * 2 - 1) * math.exp(-3.0 * t / nl) * 0.05
                      for t in range(nl)])
    write_wav_f32(os.path.join(outdir, "test_hall4.wav"), 48000, chans)

    # ---- onset-detector fixtures ----
    # A KNOWN mixing time: 5 ms of silence, a direct impulse, then discrete
    # sparse reflections for exactly MIX_MS, then continuous decaying noise.
    # The detector has to find the join. Seeded, so the file is reproducible
    # and the expected value does not move between runs.
    write_wav_f32(os.path.join(outdir, "test_mix60.wav"), 48000,
                  mixing_ir(48000, 3.0, pre_ms=5.0, mix_ms=60.0, seed=7))
    # Under the 500 ms floor: modulation must switch itself off entirely.
    write_wav_f32(os.path.join(outdir, "test_short4.wav"), 48000,
                  mixing_ir(48000, 0.3, pre_ms=2.0, mix_ms=30.0, seed=9))
    # Real inter-channel relationships, for the stereo-coherence tests.
    write_wav_f32(os.path.join(outdir, "test_ts4.wav"), 48000,
                  truestereo_ir(48000, 3.0, pre_ms=5.0, mix_ms=60.0, seed=11))

    print("wrote test IRs to", outdir)


if __name__ == "__main__":
    main()
