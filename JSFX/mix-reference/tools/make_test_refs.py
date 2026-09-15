#!/usr/bin/env python3
"""Writes the reference WAVs the render tests select in the file sliders.

They land in <resource>/Data/mixref/ because that is the directory
`slider1:/mixref:none:...` serves, and a file slider can only see files that
are already there when REAPER starts.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import write_wav_f32

DEST = os.path.expanduser("~/.config/REAPER/Data/mixref")


def sine(freq, amp, n, sr):
    return [amp * math.sin(2 * math.pi * freq * t / sr) for t in range(n)]


def main():
    os.makedirs(DEST, exist_ok=True)

    # 0.25 s @ 48k = 12000 frames = 24000 items: fits in one LCHUNK, so the
    # slot is live from the first audio block and the tests can predict where
    # the loop phase starts. 200/300 Hz are whole cycles in 0.25 s, so the
    # loop point is seamless apart from the plugin's 64-sample edge fade.
    n = 12000
    write_wav_f32(os.path.join(DEST, "t_tone2.wav"), 48000,
                  [sine(200, 0.5, n, 48000), sine(300, 0.5, n, 48000)])

    # -6.02 dB 1 kHz, for the analyser calibration test
    write_wav_f32(os.path.join(DEST, "t_cal1k.wav"), 48000,
                  [sine(1000, 0.25, n, 48000)] * 2)

    # steady 1.5 kHz: near-zero dynamic range, the dynamics reference
    write_wav_f32(os.path.join(DEST, "t_steady15.wav"), 48000,
                  [sine(1500, 0.5, n, 48000)] * 2)

    # mono file: readref() must mirror channel 0 to the right output
    write_wav_f32(os.path.join(DEST, "t_mono.wav"), 48000,
                  [sine(200, 0.5, n, 48000)])

    # 96 kHz source: must play back at the same pitch in a 48 kHz project,
    # which only works if r_rate = file_sr / srate is applied.
    write_wav_f32(os.path.join(DEST, "t_96k.wav"), 96000,
                  [sine(1000, 0.5, 24000, 96000)] * 2)

    # 30 ms: shorter than the 50 ms floor, must be rejected instead of
    # looping at audio rate as a buzz
    write_wav_f32(os.path.join(DEST, "t_tiny.wav"), 48000,
                  [sine(200, 0.5, 1440, 48000)] * 2)

    for f in sorted(os.listdir(DEST)):
        print(os.path.join(DEST, f))


if __name__ == "__main__":
    main()
