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
ln -s "$PWD/gui_kit" ~/.config/REAPER/Effects/Magnolius/gui_kit
ln -s "$PWD/Magnolius_AdaptiveCompressor.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) The `gui_kit` folder
holds the GUI's images and widget library and must sit next to the plugin —
without it the plugin fails to load. The `.help.txt` is symlinked too because
the **?** button reads it at runtime; the plugin works without it, the help
panel just reports the file is missing. Then add **JS: Adaptive Compressor** to a
track.

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

## The display

The graph is a scrolling waveform of the **detector signal** — the delayed,
pre-gain audio the compressor is actually acting on — over the last 8 seconds.
Three things are drawn over it:

- **The yellow line pair** is the *active* threshold, mirrored above and below
  the centre. Watching it move with the programme is the whole point of the
  plugin; at **Strength 0%** it is flat.
- **The faint yellow pair** is Threshold ± Range, the rails the active
  threshold can never pass.
- **The red trace**, hanging from the top of the plot, is gain reduction on a
  0–24 dB scale, matching the GR meter to the right of the graph.

The waveform is drawn on a linear amplitude scale with 12 dB of display gain,
and the threshold lines use the same scale, so where the waveform crosses the
yellow line is where compression starts.

**Active Thr** in the Adaptation panel reads the current threshold in dB.

Every control is a knob: drag vertically, hold Shift for fine adjustment, use
the mouse wheel, and Ctrl-click to reset to the default.

The number box under each knob takes typed input: click it, type a value and
press Enter (Esc cancels, clicking away commits). The boxes also scrub on a
vertical drag. The read-only displays — Active Thr, Output Gain and GR — are
not editable.

## If the knobs look flat

The knobs, the toggle and the gain-reduction meter are drawn from PNG
filmstrips in `gui_kit/`. If one of those images fails to load, the knobs and
meter fall back to being drawn with plain graphics — flat bodies and a thin
ring instead of the shaded artwork — and the title bar shows **images failed to
load**.

That means one of the `filename:` lines in the plugin does not resolve to a
file. The usual cause is the path itself: a `filename:` line takes the whole
rest of the line as the path, so adding a trailing `//` comment to one makes
the filename include the comment and the image quietly fails to load. Check
that `gui_kit/` sits next to the plugin and that every `filename:` line is
bare. The controls keep working either way, so this is cosmetic.

## Help button

The **?** at the far right of the title bar opens
`Magnolius_AdaptiveCompressor.help.txt` inside the plugin as a scrollable user
guide. Mouse wheel scrolls; **?** again closes it. The rest of the interface is
frozen while it is open, so a stray click or scroll cannot move a control you
cannot see.

That file is the reference for *using* the plugin, kept separate from this
README, which also covers installation and how the thing works internally. Edit
it as plain text wrapped to about 68 columns — it is read at runtime, so there
is nothing to rebuild.

## Interface scale

The dropdown at the far right of the title bar sets the interface scale.

**Fit** (the default) scales the interface to whatever size you drag the FX
window to, so resizing the window is the normal way to make it bigger. The
fixed percentages — 100%, 125%, 150%, 200% — hold a scale regardless of window
size; a JSFX cannot resize its own window, so if you pick a scale larger than
the window the interface is clipped. The dropdown always stays on screen in
that case, so **Fit** is one click away.

The artwork is drawn at 2x, so 100% and 200% are pixel-exact and the
percentages between them are resampled and very slightly soft. On a HiDPI
display the percentages are relative to REAPER's own scaling, so 100% remains
crisp there.

The scale is **global, not per instance**. Every open window reads it from
shared memory each frame, so changing it in one plugin window changes all of
them at once, and any instance added afterwards opens at that size. It is not a
parameter, so it never appears in automation lists.

Each instance also saves its own copy with the project and with presets. That
copy is only used to seed the global: the first instance to load in a fresh
REAPER session sets the size everything else then follows. Because the global
wins once set, opening an old project whose instances were saved at different
sizes gives them all the same one.

The sharing is **session-scoped**: REAPER frees that shared memory once the
last instance is removed, so adding the plugin to an empty project in a fresh
session starts from the default again. A JSFX cannot write a settings file
(`file_open` is read-only outside `@serialize`), so there is no way to persist
the choice from inside the plugin.

## Making it open at a different size

The plugin cannot resize its own window. `gfx_w`/`gfx_h` are read-only in JSFX
and nothing in the format lets an effect ask REAPER for a window size, so the
scale selector can only scale the interface *within* the window REAPER gives
it — which is why a fixed percentage larger than the window clips rather than
growing the window.

The size REAPER opens the window at comes from the `@gfx` line in the plugin
source, and that is the only way to change it. Edit those two numbers and leave
the scale on **Fit**:

| Scale | `@gfx` line |
| --- | --- |
| 100% | `@gfx 720 488` |
| 125% | `@gfx 900 610` |
| 150% | `@gfx 1080 732` |
| 200% | `@gfx 1440 976` (pixel-exact — the artwork is 2x) |

Because it lives in the source file, this survives deleting every instance,
restarting REAPER and reinstalling — it is the one genuinely global setting.

The shared memory is namespaced `Magnolius`, so if other plugins in this
repository adopt the same GUI kit they will share one interface scale.

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
| `gui_kit/` | GUI images, the Magnolius wordmark and `gui_kit.jsfx-inc`, the widget library. Must be installed next to the plugin. |
| `Magnolius_AdaptiveCompressor.help.txt` | The user guide shown by the **?** button, read at runtime. Must be installed next to the plugin. |
| `README.md` | This file. |
