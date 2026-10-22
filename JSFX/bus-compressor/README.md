# Bus Compressor

A REAPER JSFX model of the SSL G-series bus compressor, with a custom
interface.

It follows the topology and control set of the hardware (and of its DIY
descendant, the Gyraf GSSL): a feed-forward VCA compressor, stereo linked, with
**one shared attack/release element**, an **Auto release** that follows the
programme, and stepped controls. It is a behavioural model, **not** a circuit
simulation.

Added to the original: a sidechain high-pass, an external key, dry/wet
(parallel) mixing, a light **Colour** stage whose drive follows the gain
reduction, and a bypass.

**Latency: a constant 24 samples**, reported to the host (PDC). It comes from
the 2x oversampler used by Colour and is present whatever the settings, so
toggling Colour, Bypass or Dry/Wet never shifts the timing.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and nothing in REAPER warns you:

```
ln -s "$PWD/Magnolius_BusCompressor.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_BusCompressor.jsfx"
ln -s "$PWD/Magnolius_BusCompressor.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_BusCompressor.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Bus Compressor** to a track.

The interface loads its artwork at runtime, so `gui_kit/` has to be reachable
from the plugin **as REAPER sees it**. The Magnolius Effects folder is flat and
every plugin there shares one `gui_kit/`; this plugin needs the usual files
plus `toggle_orange.png` and `knob_orange_grid.png`. If nothing draws and the
header says *images failed to load*, that folder is what is missing.

If a change to the source seems to have no effect, check the link first:

```
readlink -f ~/.config/REAPER/Effects/Magnolius/"Magnolius_BusCompressor.jsfx"
```

For the external key the track needs 4 channels (channels 3/4 are the key).

## Controls

| Control | Range | What it does |
|---|---|---|
| Threshold | −40 … 0 dBFS | Continuous. Peak level above which compression starts. |
| Ratio | 2:1, 4:1, 10:1 | 10:1 is a true 10:1 slope, which behaves essentially as a limiter. |
| Attack | 0.1, 0.3, 1, 3, 10, 30 ms | Time constant of the gain reduction (see below). |
| Release | 0.1, 0.3, 0.6, 1.2 s, **Auto** | Time constant of the recovery. Auto is the last detent. |
| Makeup | 0 … +20 dB | Wet path only. |
| Key HPF | Off, 20 … 500 Hz | 12 dB/octave high-pass on the detector only; the audio is never filtered. Log taper; the bottom of the travel is Off. |
| Ext key | off / on | Channels 3/4 are the key instead of the input. The HPF applies to it too. |
| Listen | off / on | Output the key signal (after the HPF), to set the HPF by ear. |
| Colour | 0 … 100 % | Light 2nd/3rd harmonic colour that grows with the gain reduction. 0 is bit-transparent. |
| Dry / Wet | 0 … 100 % | Parallel compression. Makeup is on the wet path only. |
| Bypass | off / on | Header button. 10 ms crossfade; the latency is unchanged. |

Every control is a hidden, automatable parameter (the panel replaces REAPER's
generic slider list). The stepped knobs move one detent per 18 pixels of drag
(Shift: 54) or per wheel click; Ctrl-click resets. Threshold, Makeup, Key HPF,
Colour and Dry/Wet have typed value fields: click to type, drag to scrub.

### The display

- **Needle** — gain reduction, 0–20 dB, red above 14 dB, like the hardware. REAPER's
  own FX meter also shows it.
- **IN / OUT** — peak bars (−60…0 dBFS) with a hold marker and the held value.

## How it works

```
key  = input, or the external key       -> 2nd-order HPF (detector only)
     -> peak envelope of max(|L|,|R|)   -> dB -> gain computer (3 dB knee)
     -> shared timing element (GR domain) -> VCA gain on the input
     -> Colour (2x oversampled)          -> makeup -> dry/wet -> bypass
```

- **Feed-forward, stereo linked.** The detector reads the input, never the
  output. One gain-reduction value is applied to both channels.
- **Knee.** A fixed 3 dB quadratic knee: firm, as on the hardware, and not
  dependent on the threshold. Gain reduction is `slope · (over + 1.5)² / 6`
  inside the knee and `slope · over` above it, `slope = 1 − 1/ratio`.
- **Attack and release labels** are one-pole time constants in the gain-reduction
  domain: the gain has covered 63 % of a step after the labelled time. The
  coefficient is `1 − exp(−1 / (τ · sampleRate))`. The tests measure these to
  within a few percent.
- **Shared element.** Attack and release act on the same single state. The
  release time constant is `max(Release, Attack)`, so release can never be
  effectively faster than attack.
- **Auto release.** The same element is released at 0.12 s, and a second, slow
  element charges at 1 s and releases at 2 s while the gain reduction is held.
  The gain reduction is the larger of the two. A 20 ms transient barely charges
  the slow element, so it recovers in about 0.3 s; 3 s of sustained compression
  charges it fully and takes more than 4 s to let go. In between it is
  gradual — there is no switch point and it depends on the signal history.
  It is only engaged on the last Release detent.
- **Colour.** A 3rd-order polynomial shaper, run 2x oversampled with a 49-tap
  Kaiser halfband (−0.13 dB at 20 kHz, aliases below −110 dB). It is evaluated at the
  *pre-compression* level, so the harmonics follow the input level, and its
  drive follows the gain reduction (25 % with none, 100 % at 10 dB). A DC
  blocker follows it and a small gain trim keeps it roughly level-neutral
  (±0.2 dB across −24…−6 dBFS).
- **Smoothing.** Makeup, Dry/Wet and Colour glide with a 20 ms one-pole; Bypass,
  Listen and the Colour switch ramp over 10 ms; the HPF cutoff glides too.
  Threshold and Ratio act on the target gain reduction, which already passes
  through the timing element. At load the smoothed controls start at their
  saved values.
- **Determinism.** There is no noise anywhere in the detector. Identical input
  gives identical output, so null tests work.

## What is documented, and what is inferred

The structure and the control set are taken from the brief and the published
GSSL descriptions. The numbers below are modelling decisions — hidden constants
at the top of `@init`, mirrored at the top of `tools/model.py` — and are the
first place to look if it does not sound like a real unit.

| Constant | Value | Why |
|---|---|---|
| `KNEE_W` | 3 dB | "Fairly firm". Fixed, not threshold dependent. |
| `DET_REL` | 2 ms | Peak envelope fall. Long enough not to ripple at 100 Hz. |
| `AUTO_TF` / `AUTO_TSC` / `AUTO_TSR` | 0.12 / 1 / 2 s | Tuned in `model.py` against: 20 ms burst recovers 90 % in < 0.3 s; 3 s of compression takes > 1.5 s. |
| `SAT_A2` / `SAT_A3` / `SAT_BASE` / `SAT_GR_FULL` | 0.08 / 0.20 / 25 % / 10 dB | At full drive and −6 dBFS: 2nd −34 dBc, 3rd −38 dBc. |
| Detector | peak of max(\|L\|,\|R\|) | The hardware's detector is not modelled. The Threshold is in peak dBFS. |

## Quick sanity checks

- **Nothing triggering** — Threshold 0 dBFS: the output is bit-identical to the input.
- **Makeup** — +6.02 dB is exactly twice the level.
- **Mix 0 / Bypass** — bit-identical to the input, whatever the other settings.
- **Attack** — a loud burst at 10:1 with Attack 30 ms takes about 30 ms to reach 63 %
  of its gain reduction.
- **Auto** — a drum hit recovers in a quarter of a second; a held chord takes seconds.
- **Key HPF** — a 40 Hz tone at −6 dBFS compresses 16 dB with the HPF off and not at
  all at 150 Hz.

## Tests

`tools/` holds a pure-Python reference model (`model.py`) and two test scripts.
They need `reaper` on the PATH and the plugin symlinked as above.

```
python3 tools/render_test.py     # offline renders against the model and the behaviour list
python3 tools/gfx_test.py        # floats the panel in a throwaway REAPER and checks it runs
python3 ~/.claude/skills/jsfx-gui-kit/scripts/check_jsfx.py Magnolius_BusCompressor.jsfx
```

`render_test.py` asserts the render equals `model.py` sample for sample (the
first 32 samples are excluded, see the note in `t_model`), the static curve and
knee, the labelled attack and release time constants, Auto against transient
and sustained material, the HPF response, the external key, Colour (harmonics,
level, aliasing, alignment), no zipper noise under automation, determinism,
and that dry, bypass and Colour-off are bit-exact against the delayed input.
It cannot check the *inferred* constants against hardware; there is no
reference unit.

`model.py` and the `.jsfx` must be edited together.

## License

GPL-3.0-or-later, like the rest of the repository.
