# Channel Dynamics

A REAPER JSFX model of a classic console channel-strip dynamics section: a
compressor and an expander / gate that share one detector and one gain stage,
with a custom interface.

It reproduces the way that design behaves: a nearly instantaneous RMS detector,
an over-easy knee that is gentle at low gain reduction and firm at high, an
attack that is a simple RC, a release with a fast and a slow time constant
(so short transients recover quickly and sustained compression lingers),
automatic make-up gain, and a gate whose hysteresis is fixed in dB. It is a
behavioural model, **not** a circuit simulation.

Zero latency. No lookahead, no PDC. No sidechain filter or external key in this
version.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and nothing in REAPER warns you:

```
ln -s "$PWD/Magnolius_ChannelDynamics.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelDynamics.jsfx"
ln -s "$PWD/Magnolius_ChannelDynamics.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelDynamics.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Channel Dynamics** to a track.

The interface loads its artwork at runtime, so `gui_kit/` has to be reachable
from the plugin **as REAPER sees it**. The Magnolius Effects folder is flat and
every plugin there shares one `gui_kit/`, so if a sibling plugin is installed
most of the assets are already in place — but this plugin also needs
`knob_green_grid.png` and `button_green.png`, so link those too. If nothing
draws and the header says *images failed to load*, that folder is what is
missing.

If a change to the source seems to have no effect, check the link first:

```
readlink -f ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelDynamics.jsfx"
```

## How it is put together

```
                      +--> compressor gain computer -> RC attack, 2-state release --+
input -> RMS (dB) ----+                                                              +--> max --> gain
                      +--> gate gain computer -------> timing cap ------------------+
```

- **One detector.** Both sections read the input level, so the gate never sees
  the compressed signal.
- **Max, not sum.** Each section yields a gain reduction in dB; the larger one
  is applied. The two ladders show which section is winning.
- **Make-up** belongs to the compressor and is applied after the max. A closed
  gate is therefore lifted by it: with 4.5 dB of make-up, a Range of 40 dB
  gives about 35 dB of attenuation.
- Both channels always get the same gain, so the stereo image does not move.

## Controls

### Compressor (cyan)

| Control | Range | What it does |
|---|---|---|
| Ratio | 1:1 – ∞:1 | 1:1 is off; fully clockwise is a limiter. The knob is tapered so 2–10:1 gets most of the travel. In the field, 20 means ∞. |
| Threshold | +10 … −30 dB | Relative to the Reference level. Below it nothing is compressed. |
| Release | 0.1 – 4 s | Log taper. Sets the fast release time constant (a quarter of the value); the slow one is 6.7× longer. |
| Output | ±12 dB | Trim after the make-up. |
| Fast Att | off / on | Attack time constant 1 ms instead of 33 ms (Auto). |
| Auto Make-up | off / on | On by default. Gain is added as Threshold goes down and Ratio goes up, so a signal at the Reference level stays there. |
| Stereo link | Max / Avg | Detector follows the louder channel, or the average power. |
| Reference | −30 … −6 dBFS | The level that counts as 0 dB on both Threshold knobs. Default −18 dBFS (a +4 dBu console). |

### Gate / expander (green)

| Control | Range | What it does |
|---|---|---|
| In | off / on | Off by default. Off resets the gate, so switching it in always starts open. |
| Mode | Expand / Gate | Expand: a gentle downward expansion, 1.1 dB of gain reduction per dB below Threshold (about 2:1). Gate: a Schmitt trigger. |
| Threshold | +10 … −30 dB | Relative to the Reference level. |
| Range | 0 – 40 dB | How far the gain can fall. At 0 the gate does nothing. |
| Release | 0.1 – 4 s | Time to settle; time constant 68 ms … 1.77 s. Range is the asymptote of the release. |
| Fast Att | off / on | Attack time constant 40 µs instead of 0.68 ms. |

In Gate mode the gate closes when the level falls **11.6 dB** below Threshold and
re-opens at **2.2 dB** below it: 9.4 dB of hysteresis, fixed in dB, so a decaying
note can fall well below the opening level before the gate shuts. For the gate,
*attack* lowers the gain reduction (it opens) and *release* raises it (it closes).

Every control is a hidden, automatable parameter (the panel replaces REAPER's
generic slider list). Each knob has a typed value field: click to type, drag to
scrub.

### The displays

- **Transfer curve** — input level across, output level up, with the make-up
  included. Grey diagonal = no change, amber line = threshold, white dot = the
  level the detector is reading now.
- **GR ladder (compressor)** — gain reduction, 0–20 dB, 12 LEDs, yellow with red
  above 14 dB. REAPER's own FX meter shows the larger of the two sections.
- **Gate level strip** — the detector level against the gate's threshold. In Gate
  mode the shaded band runs from the close line to the open line and the lamp
  reads OPEN / CLOSED; in Expand mode there is one threshold line. Greyed while
  the gate is out.
- **GR ladder (gate)** — gain reduction, 0–40 dB, 12 LEDs.

## Fixed by the design, and fitted by ear

The behaviour below is fixed by the design this models. The *fitted* values are
modelling decisions, marked FIT in the source, and are where to look first if it
does not sound like the real thing.

**Fixed by the design**

- Shared true-RMS detector, about 80 µs averaging.
- Compressor: Ratio 1:1 to ∞:1, Threshold +10 to −30 dB, Release 0.1–4 s.
- Over-easy knee, closed-form fit within about 0.3 dB of a circuit simulation:
  `x = overshoot × (1 − 1/ratio)`, `GR = 0.45 x + 1.012 ln(1 + e^((x − 9.8)/1.84))`.
  At 2:1 and 10 dB over the threshold that is about 2.3 dB of reduction, not 5.
- Attack: one-pole RC, 33 ms (Auto) or 1 ms (Fast).
- Release: two states, the slow one 6.7× slower than the fast one.
- Gate: Threshold +10 to −30 dB, Range 0–40 dB, release time constant 68 ms to
  1.77 s, attack 0.68 ms (slow); fixed 9.4 dB hysteresis.

**Fitted** (hidden constants at the top of `@init`)

| Constant | Value | Why |
|---|---|---|
| `REL_FAST_K` | 0.25 | Release knob → fast release time constant. |
| `SLOW_ATK_X` | 4 | How much slower the slow release state charges. |
| `K_SLOW` | 0.6 | Weight of the slow release state. |
| `MU_K` | 1 | Make-up scale. Used: the compressor's own curve evaluated at the Reference level, so a signal there comes out where it went in. |
| `GATE_ATK_FAST` | 40 µs | Fast gate attack. |

Things worth knowing:

- **Low frequencies.** With 80 µs averaging the detector follows the signal
  within a cycle, so a low tone ripples through both gain computers. The
  compressor reads a 1 kHz tone up to about 0.7 dB hotter than its RMS level, and
  more at bass frequencies. The gate does not chatter on a low note that is well
  above its opening level, but a note whose *peaks* stay below the opening level
  can close it.
- **Open-gate residue.** Because the timing cap is always charging toward Range,
  an open gate leaves a little gain reduction, about
  `Range × attack / (attack + release)` — 0.1 dB typically, at most about 0.4 dB
  at Range 40 with the fastest release and slow attack.
- **Fast gate attack.** 40 µs is faster than a bass period and can click on low
  frequencies.
- Make-up is applied after the max (see above).

## Quick sanity checks

- **Ratio at 1:1, gate out** — the output is bit-identical to the input.
- **Reference level steady** — Threshold −12, Ratio 4:1, a −18 dBFS sine comes
  out at −18 dBFS with Auto Make-up on.
- **Attack** — the gain reduction reaches 63% of its final value after 33 ms
  (Fast Att: 1 ms), whatever the overshoot.
- **Release** — at Release 0.4 s, after a short burst the reduction has fallen to
  37% in about 100 ms; after two seconds of compression it takes about 350 ms.
- **Gate** — in Gate mode with Threshold −10 dB (−28 dBFS) a downward sweep closes
  it near −39.6 dBFS and the upward sweep re-opens it near −30.2 dBFS.

## Tests

`tools/` holds a pure-Python reference model (`model.py`) and two test scripts.
They need `reaper` on the PATH and the plugin symlinked as above.

```
python3 tools/render_test.py     # offline renders: model, knee, attack, release, gate, ...
python3 tools/gfx_test.py        # floats the panel in a throwaway REAPER and checks it runs
python3 ~/.claude/skills/jsfx-gui-kit/scripts/check_jsfx.py Magnolius_ChannelDynamics.jsfx
```

`render_test.py` asserts the render equals `model.py` sample for sample, plus
the behaviours above: the knee table, attack and release time constants, the
make-up holding the reference level, the Max / Avg link modes, and for the gate
the expansion slope, Range as the release asymptote, the hysteresis points, the
attack and release times, that the compressor and gate combine by max on one
shared detector, and that a low tone well above the opening level does not make
it chatter. It cannot check the *fitted* constants against hardware; there is no
reference unit.

REAPER feeds a plugin silence before an item starts, and a gate on silence has
its timing cap charging toward Range, so the model comparison for the gate cases
begins with three seconds of silence to let both sides converge.

`model.py` and the `.jsfx` must be edited together.

## License

GPL-3.0-or-later, like the rest of the repository.
