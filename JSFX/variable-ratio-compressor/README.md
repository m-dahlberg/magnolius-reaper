# Variable Ratio Compressor

Two plugins sharing one core: a compressor that **solves for the ratio** each
passage needs instead of being told one.

| File | Add as | Use it for |
| --- | --- | --- |
| `Magnolius_VariableRatioCompressor.jsfx` | **JS: Variable Ratio Compressor** | Single band. Tracks, busses, anything where the whole signal should move together. |
| `Magnolius_VariableRatioCompressorMB.jsfx` | **JS: Variable Ratio Compressor MB** | Four bands with an LR4 crossover. Mixes and mastering, or one problem region. |

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
the ceiling is still guaranteed.

You set the ceiling and the threshold. The ratio is whatever it takes.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and there is no warning anywhere in REAPER when it happens:

```
ln -s "$PWD/Magnolius_VariableRatioCompressor.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_VariableRatioCompressor.jsfx"
ln -s "$PWD/Magnolius_VariableRatioCompressorMB.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_VariableRatioCompressorMB.jsfx"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.)

Or install them from ReaPack, which is the same files and saves the bookkeeping.

## How it works

```
env -> sliding max (lookahead) -> required ratio -> ratio ballistics
    -> static curve applied to instantaneous env -> gain
    -> sliding min (lookahead) -> 2x boxcar -> applied to delayed audio
```

The **sliding-min plus double-boxcar** pair is what turns the ceiling from a
target into a guarantee. At the output instant of any peak, every gain sample
entering the smoother has already "seen" that peak, so the smoothed gain can
never be higher than the gain that peak required. No overshoot, and no
clipping stage needed to clean up after it — the safety clip is genuinely a
last resort rather than part of the sound.

**Ratio Release** governs how quickly the solved ratio is allowed to fall back
once the loud passage ends. It is the main character control: short values
follow the performance closely, long values hold a consistent ratio across a
section.

### Four-band version

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
  output level — use **Output Trim** for level, and note the safety clip sits
  at 0 dBFS rather than at the ceiling.
- **A disabled band still runs its delay line**, so bands stay sample-aligned
  and toggling one never shifts the others in time.

## Controls — single band

| Slider | Default | What it does |
| --- | --- | --- |
| Input Gain (dB) | 0 | Pre-gain into the detector and the compressor. |
| Output Ceiling (dB) | −0.3 | The level peaks are solved onto. The guarantee. |
| Threshold (dB) | −18 | Where compression begins. The span between here and the ceiling is what gets the solved ratio. |
| Blend (% wet) | 100 | Parallel blend. |
| Makeup Gain (dB) | 0 | Output gain. |
| Makeup Position | Post | **Pre** applies makeup before the ceiling, so the ceiling still holds. **Post** applies it after, making the ceiling internal — the output can then exceed it. |
| Lookahead (ms) | 5 | How far ahead peaks are found. Reported as PDC. |
| Ratio Release (ms) | 200 | How fast the solved ratio recovers. The main character control. |
| Max Ratio (:1) | 200 | Clamp on the solved ratio, so a single extreme peak cannot demand a limiter-like ratio for the whole passage. |
| Safety Clip | On | Last-resort clip. Should be inaudible; if it is working, lower the threshold or raise Max Ratio. |

## Controls — four band

Shared: **Input Gain**, **Ceiling (per band)**, **Blend**, **Output Trim**,
**Trim Position**, **Safety Clip (0 dBFS)**, **Lookahead**, **Max Ratio** —
all as above.

| Slider | Default | What it does |
| --- | --- | --- |
| Crossover 1 / 2 / 3 (Hz) | 120 / 800 / 5000 | LR4 band splits. |
| Listen | All bands | Solo one band to set its threshold. Remember to set it back. |
| Band *n* Enable | On | Bypasses that band's compression; its delay line keeps running. |
| Band *n* Threshold (dB) | −18 | Per-band threshold. |
| Band *n* Ratio Release (ms) | 400 / 250 / 150 / 80 | Per band, defaulting faster as frequency rises — low frequencies need slower ballistics or they modulate audibly. |
| Band *n* Gain (dB) | 0 | Per-band output gain, applied after compression. |

## Setting it up

Set the **Ceiling** first — it is the thing you are guaranteeing. Then bring
**Threshold** down until the gain reduction looks right on the loudest
passage. Leave **Max Ratio** alone unless a single transient is dragging the
ratio up for a whole phrase, in which case lower it.

On the four-band version, use **Listen** to set each band's threshold in
isolation, then return to **All bands** and set **Output Trim** — the summed
level will be above the per-band ceiling and that is expected.

## Files

| File | What it is |
| --- | --- |
| `Magnolius_VariableRatioCompressor.jsfx` | Single-band plugin. |
| `Magnolius_VariableRatioCompressorMB.jsfx` | Four-band plugin. |
| `README.md` | This file. |
