# Adaptive Compressor

A stereo compressor whose threshold **follows the loudness of the incoming
audio**, so one setting gives the same amount of compression whether the
source arrives at −6 or −26 dBFS.

An ordinary compressor's threshold is a fixed line in dBFS. That makes it a
setting you re-dial for every source, and it makes any preset a lie — the same
knobs on a quiet take barely touch it, and on a hot take flatten it. The usual
answers are to normalise first, or to ride an input trim until the gain
reduction meter looks right. Both work, and both mean the compressor is not
really the thing you are adjusting.

Here the threshold tracks a slow self-calibrating average of the programme and
moves with it:

```
activeThreshold = Threshold + Strength × clamp(L_short − L_slow, ±Range)
```

`L_short` is measured over **Window** ms on the undelayed signal; `L_slow` is a
roughly 8-second average that defines "normal" for this source. When a passage
runs louder than its own recent history, the threshold rises with it, so the
compressor responds to the *shape* of the performance instead of its absolute
level.

The audio path is delayed by **Look Ahead** ms and that delay is reported to
REAPER via `pdc_delay`, so the threshold anticipates loudness that has not
arrived yet while attack and release still act on present audio.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and there is no warning anywhere in REAPER when it happens:

```
ln -s "$PWD/Magnolius_AdaptiveCompressor.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_AdaptiveCompressor.jsfx"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Adaptive Compressor** to a track.

Or install it from ReaPack, which is the same file and saves the bookkeeping.

## How it works

1. **Detector.** Peak at `RMS Size = 0`, otherwise an RMS average over that
   window. This feeds both the adaptive threshold and the gain computer.
2. **Loudness tracking.** `L_short` over **Window**, `L_slow` over ~8 s. The
   difference, clamped to ±**Range** and scaled by **Strength**, is the offset
   added to **Threshold**.
3. **Gain computer.** The compression core follows the Tukan Compressor 3
   (BusTools) topology: knee width proportional to the threshold, gain slope
   `(1 − ratio) / ratio`, and a decoupled release→attack smoother so release
   is not re-triggered by every sample above the knee.
4. **Delay and PDC.** The wet path is delayed by **Look Ahead** and REAPER
   compensates, so the plugin is phase- and time-aligned with the rest of
   the project.

**Strength at 0% turns the adaptation off** and leaves an ordinary
fixed-threshold compressor — useful as an A/B against the adaptive behaviour,
and the first thing to try if the compressor is doing something you did not
expect.

## Controls

| Slider | Default | What it does |
| --- | --- | --- |
| Threshold (dB) | −20 | The base threshold. The adaptive offset is added to this, so it now sets the *centre* of the range rather than a hard line. |
| Ratio | 4 | Compression ratio above the active threshold. |
| Attack (ms) | 5 | Gain-reduction onset. |
| Release (ms) | 150 | Gain-reduction recovery. Decoupled, so it is not retriggered sample by sample. |
| Knee (%) | 50 | Knee width as a proportion of the threshold, so the knee scales with the threshold instead of staying a fixed dB width. |
| RMS Size (ms, 0 = peak) | 0 | 0 gives peak detection; any other value gives RMS over that window. Raise it for level, leave it at 0 for transients. |
| Look Ahead (ms) | 100 | Audio delay, reported as PDC. Lets the threshold see loudness before it arrives. **Changes plugin latency** — set and forget. |
| Window (ms) | 300 | Averaging window for `L_short`. Short values track phrases, long values track sections. |
| Speed (ms) | 200 | How quickly the active threshold is allowed to move. Slow it down if the compression audibly "breathes". |
| Range (dB) | 6 | Clamp on the adaptive offset, in both directions. The safety rail: the threshold can never run away further than this. |
| Strength (%) | 100 | How much of the clamped offset is applied. **0% = ordinary fixed-threshold compressor.** |
| Auto Gain | On | Compensates output level for the gain reduction being applied, so A/B comparisons are level-matched. |
| Manual Gain (dB) | 0 | Output trim, applied after auto gain. |

## Setting it up

Start with **Strength 0%** and dial Threshold, Ratio, Attack and Release until
the loudest passage sounds right. Then raise **Strength** to 100% and play a
quiet passage — it should now receive comparable treatment without touching
anything. If the quiet passages are over-compressed, lower **Range**; if the
compression audibly moves between phrases, raise **Speed**.

**Window** is the control that decides what "the programme" means. At 300 ms it
follows phrases; at 1000 ms it follows sections and largely ignores individual
words.

## Files

| File | What it is |
| --- | --- |
| `Magnolius_AdaptiveCompressor.jsfx` | The plugin. |
| `README.md` | This file. |
