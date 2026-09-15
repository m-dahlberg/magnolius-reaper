# Loudness Simulator

Makes quiet monitoring sound like loud monitoring. A single **Simulated
Loudness** control drives an equal-loudness contour EQ, a two-band upward
compressor and optional bs2b crossfeed together.

Mixing quietly is the right thing to do for your ears and the wrong thing for
your decisions. At low SPL the ear's frequency response tilts away from the
extremes (the Fletcher–Munson effect), so a mix judged quietly tends to arrive
bass-heavy and bright when anyone plays it loud. The usual workaround is to
turn it up periodically and hope you remember what you heard.

This restores the *perceptual* balance of loud listening at whatever level you
are actually monitoring at — a monitoring aid, not a mastering processor.

> **Monitoring only.** Put it last on the master bus and **bypass it before
> rendering**. Everything it does is intended to be undone by listening
> louder; printing it bakes in a correction for a room you are not in.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and there is no warning anywhere in REAPER when it happens:

```
ln -s "$PWD/Magnolius_LoudnessSimulator.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_LoudnessSimulator.jsfx"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Loudness Simulator** to the master.

Or install it from ReaPack, which is the same file and saves the bookkeeping.

## How it works

Everything scales from `amt = Simulated Loudness / 100`.

1. **Contour EQ.** A low shelf at 200 Hz reaching **+10 dB** and a high shelf
   at 6.5 kHz reaching **+4 dB** at full setting. The asymmetry is the point —
   the low end is where quiet listening loses the most.
2. **Two-band upward compression.** The detector splits at 250 Hz and 5 kHz
   and runs a 30 ms RMS with separate ballistics per band (low 40/200 ms, high
   15/120 ms) — low frequencies need slower ballistics to avoid modulation.
   Maximum lift is `amt × Comp Max Lift` in the low band and half that in the
   high band.
3. **Noise gate on the lift.** Below −70 dBFS the lift tapers off over 6 dB, so
   hiss and room tone stay where they are instead of being pulled up with
   everything else.
4. **Crossfeed.** A port of libbs2b, including its two distinct poles. Bleeds
   a filtered, delayed copy of each channel into the other so hard-panned
   material stops sounding like it is inside your head. Set **Crossfeed Level**
   to 0 to bypass it — on speakers you want it off.

The detector runs *before* the contour shelves. Detecting after them would
close a feedback loop: the lift lives inside the shelves, so post-shelf
detection would measure its own output.

Shelf coefficients are redesigned every 32 samples rather than per sample,
which is inaudible and keeps the CPU cost flat.

## Controls

| Slider | Default | What it does |
| --- | --- | --- |
| Simulated Loudness | 0 | The master control. 0 is a clean bypass of contour and lift; 100 simulates the largest level difference. Set it to roughly how much louder you *wish* you were listening. |
| Makeup Gain (dB) | 0 | Output trim. The contour adds energy, so pull this down to keep the comparison level-matched. |
| Crossfeed Freq (Hz) | 700 | bs2b corner frequency. |
| Crossfeed Level (dB) | 5.0 | Crossfeed amount. **0 = off.** Headphones only. |
| Comp Threshold (dB) | −24 | Below this, upward compression starts lifting. |
| Comp Ratio (1:N) | 2.0 | How much of the distance below the threshold is made up. |
| Comp Max Lift (dB) | 8 | Ceiling on the lift in the low band; the high band gets half. Scaled by Simulated Loudness. |
| Comp Knee (dB) | 6 | Soft-knee width around the threshold. |

## Calibrating it

Set **Simulated Loudness** to 0, play a mix you know well at your normal
working level, then raise the control until it sounds like the same mix played
loud. Use **Makeup Gain** to keep the perceived level matched as you go —
otherwise you are judging "louder", not "better balanced". That setting is now
your working value; leave it alone and mix into it.

The honest check is still to turn the monitors up occasionally. This is a way
of doing that less often, not never.

## Files

| File | What it is |
| --- | --- |
| `Magnolius_LoudnessSimulator.jsfx` | The plugin. |
| `tools/model.py` | Pure-Python reference implementation, mirroring `@init`/`@slider`/`@sample` sample for sample. Keep in lockstep with the plugin. |
| `tools/render_test.py` | Headless render tests comparing a real REAPER render against `model.py`. |
| `tools/wavio.py` | WAV read/write helper for the tests. |
| `README.md` | This file. |
