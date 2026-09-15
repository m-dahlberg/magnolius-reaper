# Magnolius_DeClick.jsfx

A real-time REAPER JSFX port of Paul Licameli's Audacity/Nyquist **De-Clicker**
(the one distributed on the Audacity forum for removing mouth noises, clicks
and crackle from speech).

## What it does

The signal is split into log-spaced frequency bands (default: twelve
half-octave bands, 150–9600 Hz). Each band is reduced to a per-step peak
envelope (default step: 5 ms). A **click** in a band is a short run of steps
(≤ *Max click length*) whose level stands above the background **both before
and after** it by the *Sensitivity threshold*, subject to the separation and
dense-click (crackle) rules of the original. Detections across bands at the
same step combine into one click event, which is repaired by crossfaded
peaking-EQ cuts at the affected band centers, with depth equal to each band's
measured overshoot. With *Passes* > 1 the repaired signal is re-detected and
re-repaired serially.

Ported faithfully: wide detection bands, skewed separation, the late
steepness test (per-band detection at half the threshold, combined click kept
only at full threshold), min(before, after) overshoot for stop-consonant
protection, and the crackle exception. Adapted for real time: the flat-top
FIR convolution bands became 4th-order constant-peak-gain IIR bandpass
filters, and the lookahead became PDC-reported latency (~50 ms per pass at
default settings — REAPER compensates automatically, live and in renders).

## Controls

Same as the original, with ranges restricted to keep latency sane. **Action**:
*Apply changes* outputs the repaired signal; *Isolate changes* outputs only
the difference (repaired − dry), useful for auditioning what is being removed.
The label modes of the original have no JSFX equivalent; instead the @gfx
panel shows a scrolling waveform (~4 s) of the input with a vertical marker
at every detected click — thin yellow for detections just over the threshold,
growing thicker and redder with severity (up to +30 dB over threshold) — plus
a per-band activity strip with red flashes on detecting bands. Channels are
detected and repaired independently, as in the original.

Changing any structural slider (everything except Action, Sensitivity and
Dense click threshold) resets the audio state and causes a brief dropout.

CPU: light at defaults; the extremes (30 bands × 4 passes) run near 1×
realtime, intended for offline render.

## Install

```
ln -sfn "$(pwd)/Magnolius_DeClick.jsfx" ~/.config/REAPER/Effects/Magnolius_DeClick.jsfx
```

Then insert "DeClicker" from the JS section of the FX browser.

## Tests

Headless render-based verification (runs while your normal REAPER is open):

```
python3 tools/render_test.py
```

Renders a synthetic clicky signal through the plugin via
`reaper -newinst -renderproject` and asserts: all sliders parse, no false
positives on steady tone, bit-exact passthrough outside repairs (proves
actual latency == reported PDC), click peaks reduced, `apply == input +
isolate`, and per-channel independence. Work dir:
`~/.cache/declicker-rendertest`.
