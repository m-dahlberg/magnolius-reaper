# Channel Compressor

A REAPER JSFX model of the compressor in the SSL SL 4000 E channel strip
(611E / 82E-series dynamics), with a custom interface.

It reproduces the way the original behaves: it reacts to energy rather than
single peaks, takes longer to clamp down the harder it is hit, has two knee
voicings and two release laws, and adds make-up gain by itself as you lower
the threshold. It is a behavioural model, **not** a circuit simulation.

Zero latency. No lookahead, no PDC. Expander/gate and VCA colouration are not
in this version.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and nothing in REAPER warns you:

```
ln -s "$PWD/Magnolius_ChannelCompressor.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelCompressor.jsfx"
ln -s "$PWD/Magnolius_ChannelCompressor.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelCompressor.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Channel Compressor** to a track.

The interface loads its artwork at runtime, so `gui_kit/` has to be reachable
from the plugin **as REAPER sees it**. The Magnolius Effects folder is flat and
every plugin there shares one `gui_kit/`, so if a sibling plugin is installed
the assets are already in place. If nothing draws and the header says *images
failed to load*, that folder is what is missing.

If a change to the source seems to have no effect, check the link first:

```
readlink -f ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelCompressor.jsfx"
```

## Controls

| Control | Range | What it does |
|---|---|---|
| Ratio | 1:1 – ∞:1 | 1:1 is off; fully clockwise is a limiter. The knob is tapered so 2–10:1 gets most of the travel. In the field, 20 means ∞. |
| Threshold | +10 … −30 dB | Relative to the Reference level. Below it nothing is compressed. |
| Release | 0.1 – 4 s | Log taper. The time constant of the release. |
| Output | ±12 dB | Trim after the make-up. |
| Fast Att | off / on | 3 ms per 20 dB of gain reduction instead of 30 ms. |
| Hard Knee | off / on | Hard knee **and** a peak-sensing detector, instead of Over Easy (soft knee, RMS). |
| Lin Rel | off / on | Linear release instead of logarithmic; also raises the threshold by 6 dB. |
| Auto Make-up | off / on | On by default. Gain is added as Threshold goes down and Ratio goes up. |
| Stereo link | Max / Avg | Detector follows the louder channel, or the average power. Both channels always get the same gain. |
| Reference | −30 … −6 dBFS | The level that counts as 0 dB on the Threshold knob. Default −18 dBFS (a +4 dBu console). |

Every control is a hidden, automatable parameter (the panel replaces REAPER's
generic slider list). Ratio, Threshold, Release and Output have typed value
fields: click to type, drag to scrub.

### The display

- **Transfer curve** — input level across, output level up, with the make-up
  included. Grey diagonal = no change, amber line = threshold, white dot = the
  level the detector is reading now.
- **GR ladder** — gain reduction, 0–20 dB, 12 LEDs, yellow with red above
  14 dB, as on the hardware. REAPER's own FX meter also shows it.
- **Detector** — read-only: RMS (Over Easy) or Peak (Hard Knee).

## What is documented, and what is inferred

The *documented* list is taken from SSL's X-Rack E Series Dynamics User's
Guide. The *inferred* list is modelling decisions, marked as such in the
source, and is where to look first if it does not sound like a real unit.

**Documented**

- True-RMS side-chain; Class-A VCA gain element.
- Ratio 1:1 to ∞:1; Threshold +10 dB to −30 dB; Release 0.1–4 s.
- Attack 30 ms per 20 dB of gain reduction, or 3 ms per 20 dB with Fast Att.
- Over Easy by default; the Hard Knee button "switches this to peak sensing"
  and replaces Over Easy with a hard knee.
- Logarithmic release by default; Lin Rel switches to linear **and raises the
  threshold by 6 dB**.
- Threshold and Ratio "provide automatic make-up gain, so as you lower the
  threshold and introduce more compression, the output level is increased,
  maintaining a steady output level regardless of the amount of compression".

**Inferred** (hidden constants at the top of `@init`)

| Constant | Value | Why |
|---|---|---|
| `TAU_RMS` | 10 ms | RMS averaging time is not published. |
| `KNEE_W` | 12 dB | Over Easy width is not published; quadratic knee. |
| `PK_ATT` / `PK_REL` / `PK_OFF_DB` | 0.1 ms / 30 ms / −2.76 dB | Peak detector is not described; the offset makes a steady sine read at its RMS level so the threshold means the same in both modes. |
| `MU_K` | 1 | Make-up law is not published. Used: `(1 − 1/R) × max(0, −Threshold)`, so a compressed signal at the Reference level comes out at the Reference level. Taken from the Threshold knob, not the extra 6 dB of Lin Rel. |
| Linear release rate | 20 dB per Release time | Only the 0.1–4 s range is published. |
| `ATK_RC` | 0 | Pure slew attack. A short RC can be blended in to soften the onset. |

Two consequences worth knowing. First, because make-up is a fixed amount, quiet
material **below** the threshold is also raised by it. Second, the RMS detector
has its own fall time, so after a loud passage the gain reduction starts to let
go some tens of milliseconds later than the Release knob alone would suggest.

One calibration step in the manual (L.4.4: +24 dBu in, ratio fully clockwise,
button in, output −4 dBu) could not be reconciled with the make-up law above.
The step does not state the Threshold position, and the result depends on it,
so the law has not been bent to fit it.

## Quick sanity checks

- **Ratio at 1:1** — the output is bit-identical to the input.
- **Reference level steady** — Threshold −12, Ratio 4:1, a −18 dBFS sine comes
  out at −18 dBFS with Auto Make-up on.
- **Attack depends on how hard it is hit** — a loud burst with Fast Att off takes
  ~13 ms to reach 90% of the reduction at 10 dB over, ~40 ms at 30 dB over.
- **Lin Rel** — a loud tone at 10 dB over the threshold gets about 4.5 dB less
  reduction at 4:1 with Lin Rel on.

## Tests

`tools/` holds a pure-Python reference model (`model.py`) and two test scripts.
They need `reaper` on the PATH and the plugin symlinked as above.

```
python3 tools/render_test.py     # offline renders: model, static curve, attack, release, ...
python3 tools/gfx_test.py        # floats the panel in a throwaway REAPER and checks it runs
python3 ~/.claude/skills/jsfx-gui-kit/scripts/check_jsfx.py Magnolius_ChannelCompressor.jsfx
```

`render_test.py` asserts the render equals `model.py` sample for sample, plus
the documented behaviours: attack time per 20 dB (normal and fast), exponential
log release and straight-line linear release, the +6 dB Lin Rel shift, the
Max / Avg link modes, and the make-up holding the reference level. It cannot
check the *inferred* constants against hardware; there is no reference unit.

`model.py` and the `.jsfx` must be edited together.

## License

GPL-3.0-or-later, like the rest of the repository.
