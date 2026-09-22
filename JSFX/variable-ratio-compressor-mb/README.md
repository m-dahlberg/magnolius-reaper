# Variable Ratio Compressor MB

Four bands of a compressor that **solves for the ratio** each passage needs
instead of being told one, split by an LR4 crossover. Add it as **JS: Variable
Ratio Compressor MB**. Use it for mixes and mastering, or for one problem
region.

The single-band version is next door in
[`../variable-ratio-compressor/`](../variable-ratio-compressor/) — use that on
tracks and busses, where the whole signal should move together.

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
ln -s "$PWD/Magnolius_VariableRatioCompressorMB.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_VariableRatioCompressorMB.jsfx"
ln -s "$PWD/Magnolius_VariableRatioCompressorMB.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_VariableRatioCompressorMB.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.)

The plugin loads its interface from `gui_kit/` and its help text from
`Magnolius_VariableRatioCompressorMB.help.txt`, and both paths are resolved relative to the `.jsfx`
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

### The crossover

A sequential LR4 tree with allpass compensation, so the bands sum flat:

```
x --LR4(f1)--> L1                                  -> AP(f2) -> AP(f3) -> band 1
           \-> H1 --LR4(f2)--> L2                  -> AP(f3) -> band 2
                           \-> H2 --LR4(f3)--> L3  ->           band 3
                                           \-> H3  ->           band 4
```

An LR4 lowpass and highpass sum to a 2nd-order allpass at the crossover, so
the compensating filters are plain Q = 0.707 allpass biquads at f2 and f3. The
total is `AP(f1)·AP(f2)·AP(f3)` — flat magnitude, phase rotation only.

Two things worth knowing:

- **The ceiling is per band, and four bands each held at the ceiling can sum
  above it.** In the MB version the ceiling is a shaping control, not the
  output level — use **Output Gain** for level. As of v1.2 there is no safety
  clipper behind it either, so put a limiter after this if you need a true
  ceiling on the output.
- **The ceiling is a line, not a number.** **Tilt** (dB/oct) tips it across
  frequency and each band takes the value at its own geometric centre. Most
  material has less energy the higher you go, so at a flat ceiling the top
  band's peaks never reach the target and the band does nothing; tilting the
  ceiling down is what puts it to work. The pivot is the geometric mean of the
  four band centres, so the Ceiling knob stays the average of the four and the
  offsets sum to zero.
- **A disabled band still runs its delay line**, so bands stay sample-aligned
  and toggling one never shifts the others in time.

## Controls

As of v1.2 this plugin has its own interface, a tilting ceiling, and the same
simplification as the single band: **Safety Clip** and **Trim Position** are
gone, **Output Trim** is now **Output Gain** and is always applied last, and
**Max Ratio** runs 1–10 in steps of 0.1 defaulting to 3. A project saved with
the old version keeps every value it still has a control for; Max Ratio clamps
to 10 and a file saved in Pre now behaves as if it had been saved in Post.

Shared, in the bottom row: **Crossover Low / Mid / High** | **Ceiling**,
**Tilt**, **Max Ratio**, **Lookahead** | **Input Gain**, **Blend**,
**Output Gain** and the two meters.

| Control | Default | What it does |
| --- | --- | --- |
| Crossover Low / Mid / High (Hz) | 120 / 800 / 5000 | LR4 band splits. Log-scaled knobs, plain-Hz fields. Each is held at least 10% below the next one up, and the band headers show the frequencies actually used. |
| Ceiling (dB) | −6 | The level each band solves its peaks onto. Per band and shared by all four — the sum can and will sit above it. With Tilt at anything but 0 this is the *average* of the four bands' ceilings. |
| Tilt (dB/oct) | 0 | Tips the ceiling across frequency; each band takes the line's value at its own geometric centre, so the ceilings follow the crossovers. Negative lowers the ceiling as frequency rises, which is the useful direction. At Ceiling −6 and the default crossovers, −1 dB/oct gives −2.1 / −4.7 / −7.4 / −9.8 dB. Two interactions to watch: the low band's ceiling *rises* as you tilt and climbs past 0 dBFS (stops compressing) beyond about −1.5 dB/oct at Ceiling −6, so lower the Ceiling for a steeper tilt; and the high band's ceiling closes on its threshold, which asks for a very high ratio, so raise Max Ratio or that band's threshold if it is not reaching its new ceiling. |
| Max Ratio (:1) | 3 | Clamp on every band's solved ratio. Same range and meaning as the single band. |
| Lookahead (ms) | 5 | How far ahead peaks are found, in every band. Reported as PDC. |
| Input Gain (dB) | 0 | Drive into the plugin; every detector sees it. Alt-drag moves Output Gain the opposite way. |
| Blend (% wet) | 100 | Parallel blend, per band, solved for rather than bolted on. |
| Output Gain (dB) | 0 | Level out. Applied once, to the sum, outside every ratio solve. This is the output level control, since the ceiling is per band. Alt-drag moves Input Gain the opposite way. |
| Display History (s) | 6 | Scroll window of the display. Cosmetic, and has no on-screen control — the panel space went to Tilt — but it is still an automatable parameter. |
| Band *n* enable (header LED) | On | Bypasses that band's compression; its delay line keeps running. |
| Band *n* Thresh (dB) | −18 | Per-band threshold. Alt-drag moves all four bands by the same number of dB. |
| Band *n* Release (ms) | 400 / 250 / 150 / 80 | Per band, defaulting faster as frequency rises — low frequencies need slower ballistics or they modulate audibly. Alt-drag scales all four by the same *factor*, so their relationship survives. |
| Band *n* Gain (dB) | 0 | Per-band level, after compression and before the sum. Alt-drag moves all four bands by the same number of dB. |
| Band *n* SOLO | — | The Listen parameter, as four buttons: soloing one un-solos the others, and clicking a soloed band returns to all bands. |

### Interface

The same kit, the same gestures and the same colour meanings as the single
band, on a 986×668 window.

Across the top: the summed scrolling display, in dB on the same −66 dB centre
line, with the ceiling drawn on it. Its orange overlay and green trace are the
**aggregate** of the four bands — deepest reduction, highest ratio — which is
what the GR and RATIO meters show. There is no threshold line, because there
are four thresholds.

Under it, one lane per band on the same time axis: that band's gain reduction
hanging from the lane top and its solved ratio rising from the lane bottom. A
disabled band's lane goes grey and says "off".

The **CURVE** panel holds four live transfer curves, one per band in the
band's own colour — the same colour as its lane label — each drawn at the
ratio that band is holding at that instant. The dashed line is the ceiling:
one yellow line at Tilt 0, or one line per band in the band's own colour once
it is tilted, each at that band's own ceiling — the spread between them is the
tilt. The **B1–B4 labels under the plot are switches**: click one to hide or show that band's curve, which is how two
curves get compared without the other two in the way. A hidden curve's label
is greyed and loses its underline. All four start shown, and the state is
saved with the project rather than exposed as a parameter.

Each band then gets its own panel: enable LED and frequency range in the
header, Thresh / Release / Gain with typed value fields, SOLO, and a live GR
bar on the same fixed 0–24 dB scale as everything else.

**Alt-drag any of the three band controls and all four bands move together**,
preserving the offsets between them — a difference in dB for Threshold and
Gain, a ratio for Release. The group moves as one rigid body and stops when
the first band reaches an end of its range, so a balance can never be
flattened against a limit.

The bottom row is three panels rather than four columns: CROSSOVER, a wider
DYNAMICS holding Ceiling, Tilt, Max Ratio and Lookahead, and a wider GAIN that
also carries the GR and RATIO meters.

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

On the four-band version, use a band's **SOLO** button to set its threshold in
isolation, then un-solo and set **Output Gain** — the summed level will be
above the per-band ceiling and that is expected.

## Files

| File | What it is |
| --- | --- |
| `Magnolius_VariableRatioCompressorMB.jsfx` | The plugin. |
| `Magnolius_VariableRatioCompressorMB.help.txt` | Text shown by the **?** button. Read at runtime, so edits need no rebuild. |
| `gui_kit/` | Widget library and PNG assets for the interface. |
| `README.md` | This file. |
