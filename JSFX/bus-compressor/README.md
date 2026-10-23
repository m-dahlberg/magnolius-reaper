# Bus Compressor

A REAPER JSFX model of a classic feedback VCA bus compressor, with a custom
interface.

It follows the topology and control set of that design: a **feedback** VCA
compressor (the detector hears the gain-reduced signal), stereo linked, with
**one shared RC timing network** for attack and release, an **Auto release**
made of two coupled capacitors that follows the programme, and stepped
controls. It is a behavioural model, **not** a circuit simulation: the
network and the loop are emulated at block level, the op-amps, VCAs and
rectifier are not.

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
| Threshold | −40 … 0 dBFS | Continuous. The sine peak level that gives about 1 dB of gain reduction (see below). There is no hard threshold: the onset is soft. |
| Ratio | 2:1, 4:1, 10:1 | Nominal. The effective ratio rises with the gain reduction, and the label is its value at 10 dB. 10:1 behaves essentially as a limiter. |
| Attack | 0.1, 0.3, 1, 3, 10, 30 ms | Nominal label for the attack resistor of the RC network (see below). |
| Release | 0.1, 0.3, 0.6, 1.2 s, **Auto** | Nominal label for the release network. Auto is the last detent and is selected by clicking or stepping to it, never by reaching an end stop. |
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

- **Gain reduction meter** — a backlit blue/black dial. 0 dB is at the right and
  the needle swings left as gain reduction grows. The scale ends at 15 dB (the
  needle stays pinned beyond that) and is stretched where bus work happens:
  0–5 dB takes the right half of the sweep, 5–15 dB the left half. The red
  zone starts at 10 dB. A small tick outside the scale holds the peak for about
  a second, and the readout in the corner gives the value. The needle shows
  the voltage of the timing network directly, with only a light mechanical
  damping (two 25 ms poles), so it includes the fast part of the Auto release.
  REAPER's own FX meter also shows the gain reduction.
- **IN / OUT** — peak bars (−60…0 dBFS) with a hold marker and the held value.

## How it works

```
key  = input, or the external key       -> 2nd-order HPF (detector only)
a    = max(|L|,|R|) x gain of the previous sample          (the feedback)
Vr   = K . a^eta                        -> rectifier, linear in amplitude
     -> RC timing network (state = gain reduction in dB; the diode only charges)
     -> VCA gain on the input  (10^(-GR/20), the same on both channels)
     -> Colour (2x oversampled) -> makeup -> dry/wet -> bypass
```

- **Feedback, stereo linked.** The detector reads the input multiplied by the
  gain being applied, so it sees the gain-reduced signal. The link is the
  maximum of the two channels, then one envelope and one gain for both. An
  external key goes through the same loop, multiplied by the same gain.
- **Static curve.** There is no gain computer and no knee. The detector is
  linear and drives a dB-linear VCA, so the curve comes out of the loop: the
  effective ratio rises with the gain reduction. With the Ratio switch setting
  an exponent `eta` on the rectifier, the effective ratio is
  `1 + eta · GR / 8.686`. The nominal labels are that value at 10 dB of
  gain reduction (`eta = (ratio − 1) / 1.1513`: 0.87, 2.61, 7.82), which gives
  (measured on the plugin against the analytic loop, `tools/render_test.py`):

  | Ratio | at 5 dB GR | at 10 dB | at 15 dB |
  |---|---|---|---|
  | 2:1 | 1.5 | 2.0 | 2.5 |
  | 4:1 | 2.5 | 4.0 | 5.5 |
  | 10:1 | 5.5 | 10 | 14.5 |

  Those are static slopes. No published measurement of the real unit was found
  to compare them with, so they are marked as inferred.
- **Threshold.** Because the onset is soft, Threshold is defined as the peak
  level of a steady sine that gives **about 1 dB** of gain reduction at the
  default Attack and Release (measured: 0.87 / 1.03 / 1.16 dB at 2:1 / 4:1 /
  10:1). The timing network then moves it a little with the settings, see the
  next point; this is the behaviour being modelled, not a calibration error.
- **Timing network.** The rectified signal charges a 0.47 µF capacitor through
  the Attack resistor (820 R, 2k7, 8k2, 27k, 82k, 270k). The capacitor
  discharges through the Release resistor (180k, 270k, 560k, 1M2) and an
  always-on 3M3 bleed. The diode only **charges**, so the discharge does not go
  through the attack resistor, and release can be faster than attack. Because
  the release resistor is connected while the capacitor charges, a slow
  attack settles at only `R_p / (R_att + R_p)` of the rectifier output (`R_p`
  is the release resistor in parallel with the bleed): a 30 ms attack with a
  0.1 s release compresses at 0.39x the gain reduction of a 0.1 ms attack.
  Slow attack with fast release therefore needs a lower Threshold.
- **The labels are nominal.** The attack time constant of the bare network
  is `(R_att ∥ R_p) · C`, which is about 4x the label, and closing the loop
  makes the real attack faster again (roughly divided by one plus the loop
  gain). Release is the pure RC: 80 ms, 117 ms, 225 ms and 414 ms for the
  four fixed positions, which is a recovery in about three time constants of
  roughly the labelled time. The gain reduction decays exponentially **in dB**.
- **Auto release.** A series stack of two parallel RC sections: 91k ∥ 0.47 µF
  (τ ≈ 43 ms) in series with 750k ∥ 6.8 µF (τ ≈ 5.1 s). It is modelled with two
  coupled state variables, not a crossfade. A short transient charges mostly
  the small capacitor (about 94 % of the voltage lands on it) and recovers
  quickly; sustained compression migrates the voltage to the big one (89 % at
  DC) and recovers over seconds. Time for the gain reduction to halve after a
  burst at about 12 dB: 33 ms after 20 ms, 39 ms after 100 ms, 0.19 s after
  0.5 s, 1.5 s after 1 s and 2.3 s after 3 s. Attack in Auto sees the two
  capacitors in series (≈ 0.44 µF), so the attack times hold.
- **Switching.** Changing Attack, Release or Auto carries the capacitor voltage
  across (the series split when entering Auto, the sum when leaving it), so the
  gain reduction never jumps or resets.
- **Pre-fader.** The detector reads the signal before makeup, and nothing
  else changes its level, so the compression does not depend on the output
  level.
- **Limits.** The gain reduction is limited to 30 dB, like a control line
  with finite rails, and the rectifier output is limited too. The loop is
  stable at all sample rates tested (44.1–192 kHz) at 10:1 with 0.1 ms attack,
  with a one-sample delay in the loop.
- **Colour.** A 3rd-order polynomial shaper, run 2x oversampled with a 49-tap
  Kaiser halfband (−0.13 dB at 20 kHz). It is evaluated at the
  *pre-compression* level, so the harmonics follow the input level, and its
  drive follows the gain reduction (25 % with none, 100 % at 10 dB). The
  balance leans to the **3rd harmonic** (−37 dBc against −52 dBc for the 2nd at
  −6 dBFS and full drive), like a VCA whose symmetry has been trimmed for
  minimum distortion. A DC blocker follows it and a small gain trim keeps it
  roughly level-neutral (±0.2 dB across −24…−6 dBFS).
- **Smoothing.** Makeup, Dry/Wet and Colour glide with a 20 ms one-pole; Bypass,
  Listen and the Colour switch ramp over 10 ms; the HPF cutoff glides too.
  Threshold and Ratio act inside the loop, so the timing network already
  smooths them. At load the smoothed controls start at their saved values.
- **No threshold bit-transparency.** With no hard threshold the gain reduction
  is tiny but not zero for quiet signals (for a sine 40 dB below the threshold:
  about 0.02 dB at 2:1, far less at 4:1 and 10:1). Mix 0, Bypass and a signal
  the rectifier reads as zero are bit-exact.
- **Determinism.** There is no noise anywhere in the detector. Identical input
  gives identical output, so null tests work.

## What is documented, and what is inferred

The structure, the control set and the resistor and capacitor values of the
timing network are taken from the brief and the published descriptions of the
design. The numbers below are modelling decisions — hidden constants at the top
of `@init`, mirrored at the top of `tools/model.py` — and are the first place to
look if it does not sound like a real unit.

| Constant | Value | Why |
|---|---|---|
| `eta` rule | `(ratio − 1) / 1.1513` | The ratio network is not derived from the schematic. A power-law rectifier gives an effective ratio that rises with GR, and the label is its value at 10 dB. |
| `U_REF` | 1 dB | Gain reduction of a steady sine at Threshold (averaged, no divider). |
| `VR_CAP` / `GR_MAX` | 100 dB / 30 dB | Rectifier and control-line limits. They keep the loop finite and stable at extreme settings. |
| `SAT_A2` / `SAT_A3` / `SAT_BASE` / `SAT_GR_FULL` | 0.01 / 0.20 / 25 % / 10 dB | At full drive and −6 dBFS: 2nd −52 dBc, 3rd −37 dBc. |
| Detector | peak of max(\|L\|,\|R\|) | An instantaneous rectifier, no RMS and no extra smoothing: the ballistics come only from the RC network. |

## Quick sanity checks

- **Makeup** — +6.02 dB is exactly twice the level.
- **Mix 0 / Bypass** — bit-identical to the input, whatever the other settings.
- **Quiet signal** — Threshold 0 dBFS, 10:1: a signal 20 dB down is untouched (the
  rectifier reads zero).
- **Release** — a held burst at 4:1 takes about 0.4 s to fall to 1/e at 1.2 s and
  0.08 s at 0.1 s.
- **Auto** — a drum hit recovers in a fraction of a second; a held chord takes
  seconds.
- **Key HPF** — a 40 Hz tone at −6 dBFS compresses 16 dB with the HPF off and by
  0.1 dB at 150 Hz.

## Tests

`tools/` holds a pure-Python reference model (`model.py`), the test scripts and
the script that draws the meter face. The tests need `reaper` on the PATH and the
plugin symlinked as above.

```
python3 tools/render_test.py     # offline renders against the model and the behaviour list
python3 tools/gfx_test.py        # floats the panel in a throwaway REAPER and checks it runs
python3 tools/make_meter_face.py # regenerates gui_kit/meter_face.png
python3 ~/.claude/skills/jsfx-gui-kit/scripts/check_jsfx.py Magnolius_BusCompressor.jsfx
```

`render_test.py` asserts the render equals `model.py` sample for sample (the
first 32 samples are excluded, see the note in `t_model`; 44.1, 96 and 192 kHz
included), the static curve against the analytic fixed point of the loop and
the effective ratio at 5/10/15 dB, the Threshold, the attack and release time
constants against the RC maths, the divider, Auto against transient and
sustained material, release switching without a jump, loop stability from 44.1
to 192 kHz, the HPF response, the external key, Colour (harmonics, level,
aliasing, alignment), no zipper noise under automation, determinism, and that
dry, bypass and Colour-off are bit-exact against the delayed input. It cannot
check the *inferred* constants against hardware; there is no reference unit.

`model.py` and the `.jsfx` must be edited together. The meter face's geometry
is mirrored in `make_meter_face.py` and in the `@gfx` section; change all
three together.

## License

GPL-3.0-or-later, like the rest of the repository.
