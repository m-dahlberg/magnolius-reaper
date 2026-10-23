# Channel EQ

A REAPER JSFX channel-strip equaliser: an 18 dB/oct high-pass, a 12 dB/oct
low-pass and four bands (LF shelf, LMF bell, HMF bell, HF shelf), with a custom
interface and a live response curve you can show or hide.

It is modelled from the transfer functions of a console-style circuit rather
than built from cookbook shelves and bells. That gives it the behaviour the
circuit has: shelf corners that move as the gain changes, a small dip just
below the HF corner at full boost, cut that is the exact mirror of boost, and
bell widths that narrow as the gain rises.

Zero latency. No lookahead, no PDC. The EQ is linear, so it cannot alias; the
frequency response is designed so it does not cramp towards Nyquist either (see
below). The two Saturation controls are placeholders: they are saved and
automatable but do nothing yet.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and nothing in REAPER warns you:

```
ln -s "$PWD/Magnolius_ChannelEQ.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelEQ.jsfx"
ln -s "$PWD/Magnolius_ChannelEQ.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelEQ.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Channel EQ** to a track.

The interface loads its artwork at runtime, so `gui_kit/` has to be reachable
from the plugin **as REAPER sees it**. The Magnolius Effects folder is flat and
every plugin there shares one `gui_kit/`, so if a sibling plugin is installed
most of the assets are already in place. This plugin also needs
`knob_cyan_bipolar_grid.png`, `knob_green_grid.png`, `knob_orange_grid.png`,
`button_green.png` and `button_orange.png`, so link those too. If nothing draws
and the header says *images failed to load*, that folder is what is missing.

If a change to the source seems to have no effect, check the link first:

```
readlink -f ~/.config/REAPER/Effects/Magnolius/"Magnolius_ChannelEQ.jsfx"
```

## Controls

Panels, left to right. Every control is a hidden, automatable parameter (the
panel replaces REAPER's generic slider list). Knob parameters store the knob
position, so an automation sweep moves like the knob does.

| Panel | Control | What it does |
|---|---|---|
| Header | Gain law | **Circuit**: the tabulated law of the original, where the shelves keep most of their range for the last fifth of the turn. **dB-linear**: equal dB per turn. |
| Header | Curve | Shows or hides the response curve. |
| Header | Fit / 100 % … 200 % | Interface scale. Shared by every Magnolius plugin. |
| Filters (green) | High-pass | Counter-clockwise stop is OUT, then 15 – 415 Hz (printed 20 – 350). 18 dB/oct, 3rd-order Butterworth. |
| | Low-pass | **Clockwise** stop is OUT, then 3.2 kHz upwards (printed 3 – 12 kHz). 12 dB/oct, Q ≈ 0.72. |
| | Filters In, EQ In | Switch the two filters / the four bands in and out. Off gives bit-identical passthrough. |
| LF | Gain, Freq | Low shelf, corner 31 – 361 Hz at full boost, ±18 dB. |
| LMF | Gain, Freq, Q, `/ 3` | Bell, centre 202 Hz – 2.07 kHz, ±21 dB, Q 0.73 – 2.95 (printed 0.5 – 3). `/ 3` divides the range by 4.13 (see open items). |
| HMF | Gain, Freq, Q, `x 3` | Bell, centre 605 Hz – 6.2 kHz, ±21 dB. `x 3` multiplies the range by 2.92. |
| HF | Gain, Freq | High shelf, corner 2.3 – 23 kHz at full boost, ±20 dB. |
| Saturation (orange) | Amount, Console / Tube | Placeholders. No effect yet. |

The numbers around each knob are spread evenly round its sweep, and the knob's
law is a smooth piecewise-log curve through them, so the pointer on a printed
number gives that value. The printed numbers are nominal: the real centre or
corner follows the circuit and can sit up to about a fifth away from the print
(more for a strongly boosted shelf).

Ctrl-click resets a knob, Shift gives fine control. A JSFX cannot resize its
own window, so hiding the curve makes the panel shorter and Fit scales it to
the window; the window itself stays the size you gave it.

## How it is put together

```
HPF (1-pole + biquad) -> LPF -> HF shelf -> HMF bell -> LF shelf -> LMF bell
```

Seven direct-form-I biquad sections in doubles, in the circuit's stage order.
A section that is neutral and settled is skipped, so a neutral EQ is
bit-identical passthrough.

**Design, per section.** Knob positions go through the gain and frequency laws
to the circuit's analog transfer function, the closed forms listed in
`tools/model.py`. Each one becomes a digital biquad in two steps:

1. *Matched design.* The poles are mapped exactly (`z = exp(sT)`) and the
   numerator is fitted to the analog magnitude at DC, at a mid frequency and at
   Nyquist.
2. *Refinement.* A short Levenberg–Marquardt fit of all five coefficients to
   the analog log-magnitude (weight 1 from 20 Hz to 15 kHz, 0.1 from there to
   20 kHz). Three points cannot describe a pole near or above Nyquist, which is
   exactly what the HF shelf and an HMF `x 3` bell have at 44.1 / 48 kHz; the
   fit removes what is left.

A plain bilinear transform is only the fallback if the matched design is not
realisable. The result is that the digital response follows the analog one
without the usual compression of the top octave: worst case, with every band at
an extreme, **0.07 dB to 15 kHz at 44.1 and 48 kHz and under 0.01 dB at 88.2 kHz
and above**. Between 15 and 20 kHz, in the worst extreme settings, it can be up
to about 1.4 dB off at 44.1 kHz, because a 2nd-order section cannot follow an
analog feature that sits above Nyquist.

**Changes.** The audio thread watches the sliders itself (the panel writes them
through `slider_automate`, which does not re-run `@slider`) and redesigns only
the sections whose inputs moved, at most every 5 ms. The coefficients then glide
per sample with a 10 ms time constant. A blend of two stable biquads is stable,
so a glide cannot blow up.

**Why nothing aliases.** The chain is linear and time-invariant between
changes, so it creates no new frequencies. A loud 15 kHz tone through full boost
at 44.1 kHz comes out as that tone and nothing else (everything else 150 dB
down, which is the float32 floor). Saturation, when it arrives, will bring its
own oversampling around the nonlinearity.

**Gain law.** The tabulated law (boost at the band's plateau or centre for
rotation 0.1 … 1.0) is interpolated, and then fed into the circuit's shape: the
shelves take an effective loop constant `1 − 1/G` so the corner shift and the
dip still come from the topology; the bells take `A = G − 1`. Cut is the
reciprocal of boost, so the two mirror exactly in dB.

## Things that are derived, not given

- **Gain table**: used as given. The closed forms in the source notes
  (boost linear in the pot fraction) do not reproduce it for the bells, so the
  table wins.
- **LF**: the loop constant carries a small correction (1.1 – 1.7 %, a fitted
  quadratic in the gain) so the response *peak* equals the table gain, and the
  pot resistance range is calibrated so the full-boost corner spans 31 – 361 Hz.
  Rollback of the boost towards DC is 1.2 dB at the lowest corner and 1.3 dB at
  the highest; the source notes say 0.5 – 1.2 dB.
- **HF**: with this model the full-boost corner (−3 dB from the plateau) is 2.26
  kHz at the low stop, as stated, but 23 kHz at the high stop, where the notes
  say 18 kHz. The dip below the corner is −1.90 dB, as stated.
- **Bell width**: at Q ≈ 0.73 the −3 dB-below-peak width goes from 3.5 octaves
  at +4 dB to 1.9 octaves at +21 dB (stated: 3.7 to 1.85).
- **LMF `/ 3`** divides by 4.13 on the drawn capacitor values (62 nF against
  15 nF), not 3. It is the single constant `LMF_DIV` in the source and in
  `tools/model.py`; 33 nF would give a division of about 3.2.
- **Relay states.** Which way each of the two range switches is "normal" is
  assumed from the printed ranges (HMF normal 0.6 – 7 kHz, LMF normal
  0.2 – 2.5 kHz).
- **Gain ranges** assume ideal parts and nominal pots; treat them as ±1 dB.
- The analog formulas themselves are checked against the figures above, not
  against a measured unit. There is none to compare with.

## Tests

`tools/` holds a pure-Python reference model (`model.py`) and four test
scripts. The render and panel tests need `reaper` on the PATH and the plugin
symlinked as above; the EEL test needs
[`loose_eel`](https://github.com/justinfrankel/WDL) built.

```
python3 tools/model_test.py      # laws, gain table, mirror, shelves, bells, filters, stability, accuracy
python3 tools/eel_test.py        # the plugin's EEL code gives the model's coefficients (loose_eel, no REAPER)
python3 tools/render_test.py     # offline renders: bit-exact neutral, sample-for-sample model, magnitude, aliasing, glide
python3 tools/gfx_test.py        # floats the panel in a throwaway REAPER and checks it runs and loads its images
python3 tools/mockup.py DIR      # renders the panel from the real artwork, for layout work
python3 ~/.claude/skills/jsfx-gui-kit/scripts/check_jsfx.py Magnolius_ChannelEQ.jsfx
```

`render_test.py` asserts, among other things, that the neutral plugin, the
bypass switches and the dummy saturation controls give a bit-identical copy of
the input, that a full HMF boost reads +21.0 dB at its centre, that the render
equals `model.py` to 6e-8, that the chain matches its analog prototype at
44.1, 48, 96 and 192 kHz, that a loud tone near Nyquist comes out clean, that a
gain step glides with no step or overshoot, and that switching the EQ off ends
in exact passthrough.

`model.py` and the `.jsfx` must be edited together. The response curve in the
panel runs on the UI thread and so has its own copy of the laws and prototypes
(`g_*`); `eel_test.py gproto` checks it against the audio side.

## License

GPL-3.0-or-later, like the rest of the repository.
