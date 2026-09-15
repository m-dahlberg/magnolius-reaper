#!/usr/bin/env python3
"""Generate test impulse responses for the PerceptualEQ convolution reverb.

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
    # L->L only: mutes everything the crossfeed sent to the right channel,
    # so it distinguishes crossfeed-before-reverb from reverb-before-crossfeed
    # (unlike unity/swap/delay IRs, which all commute with the crossfeed)
    write_wav_f32(os.path.join(outdir, "test_lonly4.wav"), 48000,
                  [impulse(n, 0), zeros(n), zeros(n), zeros(n)])
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

    print("wrote test IRs to", outdir)


if __name__ == "__main__":
    main()
