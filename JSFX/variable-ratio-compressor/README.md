# Variable Ratio Compressor

A compressor that **solves for the ratio** each passage needs instead of being
told one. Add it as **JS: Variable Ratio Compressor**.

Four bands of the same core live next door in
[`../variable-ratio-compressor-mb/`](../variable-ratio-compressor-mb/) — use
that one for mixes and mastering, or for a single problem region.

## The idea

Set a ratio on an ordinary compressor and it is a constant: the same 4:1
applies to a peak 2 dB over threshold and one 20 dB over. So the tips get
flattened while everything below them keeps its original dynamics, and the
passage ends up sounding squashed at the top and untouched underneath.

Here the ratio is derived rather than dialled. Lookahead finds the loudest
peak that is coming, and the compressor solves for the exact ratio that lands
*that* peak on the output ceiling — then holds that ratio across the whole
passage. Everything between threshold and ceiling is compressed at the same
currently-valid ratio, so relative dynamics inside the passage survive while
the ceiling is still held.

You set the ceiling and the threshold. The ratio is whatever it takes.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and there is no warning anywhere in REAPER when it happens:

```
ln -s "$PWD/Magnolius_VariableRatioCompressor.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_VariableRatioCompressor.jsfx"
ln -s "$PWD/Magnolius_VariableRatioCompressor.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_VariableRatioCompressor.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.)

The plugin loads its interface from `gui_kit/` and its help text from
`Magnolius_VariableRatioCompressor.help.txt`, and both paths are resolved relative to the `.jsfx`
**as REAPER sees it** — that is, the Effects folder, not this repo. The
Magnolius Effects folder is flat and already carries a shared `gui_kit/`;
on a fresh install, symlink or copy this folder's `gui_kit/` alongside the
plugin too. If it is missing, the plugin still runs and still responds to the
mouse, but draws vector fallbacks and prints `images failed to load: N` across
its title bar.

Or install it from ReaPack, which is the same files and saves the bookkeeping.

## How it works

```
env -> sliding max (lookahead) -> required ratio -> ratio ballistics
    -> static curve applied to instantaneous env -> gain
    -> sliding min (lookahead) -> 2x boxcar -> applied to delayed audio
```

The **sliding-min plus double-boxcar** pair is what stops the gain
overshooting. At the output instant of any peak, every gain sample entering the
smoother has already "seen" that peak, so the smoothed gain can never be higher
than the gain that peak required, and the ceiling is hit exactly rather than
approached.

That holds while the compressor is *allowed* to reach the ceiling. Once a peak
demands more than **Max Ratio**, the ratio is capped and the peak comes
through — and as of v1.2 there is no clipper behind it. Measured with the
threshold at −6 dB and the ceiling at −5.5 dB, where a full-scale peak asks for
about 12:1:

| Max Ratio | Peak lands |
| --- | --- |
| 3:1 | 1.5 dB over the ceiling |
| 5:1 | 0.7 dB over |
| 10:1 | 0.1 dB over |

So Output Ceiling is a target the compressor hits exactly until it runs out of
ratio, not an absolute guarantee. Put a limiter after this if you need one.

**Ratio Release** governs how quickly the solved ratio is allowed to fall back
once the loud passage ends. It is the main character control: short values
follow the performance closely, long values hold a consistent ratio across a
section.

## Controls

| Slider | Default | What it does |
| --- | --- | --- |
| Input Gain (dB) | 0 | Alt-drag moves Output Gain the opposite way. Drive into the compressor, not a trim — the detector, the curve and the dry half of the blend all see it, so turning it up asks the compressor for more work. |
| Output Ceiling (dB) | −0.3 | The level peaks are solved onto, and hit exactly while the ratio it takes is within Max Ratio. |
| Threshold (dB) | −18 | Where compression begins. The span between here and the ceiling is what gets the solved ratio. |
| Blend (% wet) | 100 | Parallel blend. |
| Output Gain (dB) | 0 | Alt-drag moves Input Gain the opposite way. Level out. Applied last, after the blend, and not part of the ratio solve — it moves the level and changes nothing else. Being post-blend it scales the dry path too, so it still works at Blend 0%. |
| Lookahead (ms) | 5 | How far ahead peaks are found. Reported as PDC. |
| Ratio Release (ms) | 200 | How fast the solved ratio recovers. The main character control. |
| Max Ratio (:1) | 3 | Clamp on the solved ratio, so a single extreme peak cannot demand a limiter-like ratio for the whole passage. Range 1–10 in steps of 0.1. At 10 the clamp is effectively off and the ratio holds the ceiling alone; held low (1.5–2) it turns the plugin into a gentle leveller that still picks its own moments; 1:1 pins the solver at unity — compression off, Blend and Output Gain still live. It does not change the display: the ratio trace and the RATIO meter are on a fixed 1:1–10:1 scale. |
| Display History (s) | 6 | Scroll window of the display. Cosmetic; it changes nothing about the sound. Lives in the GAIN panel to keep the layout even. |

### Interface

The single-band plugin has a custom interface built on the Magnolius GUI kit.
Every knob has a value field under it: click to type, drag to scrub,
Ctrl-click to reset, Shift-drag for fine adjustment.

**Alt-drag on Input Gain or Output Gain moves the other one the opposite way
by the same number of dB.** Input Gain is part of the ratio solve and Output
Gain is not, so the pair is the difference between "more compressed" and
"louder" — alt-drag changes the first without touching the second. It works on
the knob, the wheel and the value field, and each value still clamps to its
own range, so the link goes one-sided once either end runs out of travel. The
four-band plugin has the same gesture on its own two gains.

The scrolling display plots **dB**, not linear amplitude — the centre line is
−66 dB and the top and bottom edges are 0 dBFS. Grey is the input, cyan the
output, orange the gain reduction hanging from the top edge, green the solved
ratio rising from the bottom on a fixed log scale — 1:1 at the bottom edge,
10:1 at the top, regardless of Max Ratio.
The dotted line is the threshold and the solid yellow one the ceiling, both
drawn on the same dB scale as the waveform.

The **CURVE** panel is the live transfer curve, redrawn at the ratio the
plugin is holding at that instant, so it visibly bends as the compressor
works. Blend and Output Gain are folded in, so what is drawn is what actually
leaves the plugin.

The **?** button opens the built-in help. The percentage box beside it scales
the whole interface and is shared with every other Magnolius plugin in the
session. A JSFX cannot resize its own window, so a scale larger than the
window will clip — drag the FX window bigger, or pick a smaller percentage.

## Setting it up


Set the **Ceiling** first — it is the level peaks are solved onto. Then bring
**Threshold** down until the gain reduction looks right on the loudest
passage. Then set **Max Ratio**, which starts at 3:1: raise it towards 10:1 if
peaks are getting past the ceiling, lower it
if a single transient is dragging the ratio up for a whole phrase — and expect
to lower the threshold or the ceiling afterwards, since the peaks it was
holding down now come through.

Max Ratio only bites when the threshold and the ceiling are close together.
The ratio a peak demands is `(peak − threshold) / (ceiling − threshold)`, so
with the threshold at −24 dB and the ceiling at −0.3 dB even a full-scale peak
asks for barely 1.01:1 and Max Ratio does nothing at any setting. Narrow that
window — say −6 and −5.5 — and the same peak asks for about 12:1, where the
control decides the whole character.

## Files

| File | What it is |
| --- | --- |
| `Magnolius_VariableRatioCompressor.jsfx` | The plugin. |
| `Magnolius_VariableRatioCompressor.help.txt` | Text shown by the **?** button. Read at runtime, so edits need no rebuild. |
| `gui_kit/` | Widget library and PNG assets for the interface. |
| `README.md` | This file. |
