# PinkMatch EQ

A real-time spectral matcher for Reaper, written in JSFX. It continuously
measures the incoming audio's spectrum and applies an EQ curve that pulls it
toward a fixed **pink noise** profile (power ∝ 1/f, i.e. −3 dB/octave).

An optional **side-chain input** (channels 3/4) lets a second signal drive the
EQ profile — trigger the match from another track, blend it with the main
input, or match the main input to the side chain's own spectrum instead of pink.

## Install

Copy (or symlink) `Magnolius_MatchEQ.jsfx` into your Reaper Effects folder,
**together with `gui_kit/` and `Magnolius_MatchEQ.help.txt`** — the plugin reads
all three at runtime, relative to the `.jsfx` as Reaper sees it. If you symlink
the plugin, symlink the other two into the same folder as well, or the GUI will
fall back to plain vector drawing and report `images failed to load: n` across
the header.

```sh
DEST=~/.config/REAPER/Effects
ln -s "$(pwd)/Magnolius_MatchEQ.jsfx"      "$DEST/Magnolius_MatchEQ.jsfx"
ln -s "$(pwd)/Magnolius_MatchEQ.help.txt"  "$DEST/Magnolius_MatchEQ.help.txt"
ln -s "$(pwd)/gui_kit"                     "$DEST/gui_kit"
```

Then in Reaper: FX browser → refresh (F5) → search for "PinkMatch EQ"
(it appears under JS plugins).

## Controls

| Slider | Range | What it does |
|---|---|---|
| Amount | 0–100 % | How much of the computed correction is applied. 0 % = analysis only (transparent). |
| EQ Bands | 8–64 | Resolution of the correction curve — log-spaced bands from 30 Hz to 20 kHz. Fewer bands = broad tonal tilt, more bands = detailed matching. |
| Speed | 0.1–10 s | Averaging time of the spectrum analysis. Short = follows the material quickly, long = corrects the long-term average tone. |
| Compensation Gain | −24…+24 dB | Plain output trim. The correction curve itself is normalized to zero mean dB, so it only changes spectral shape, never overall level. |
| Target Tilt | −6…+6 dB/oct | Tilts the pink noise target profile (positive = brighter target). |
| Tilt Center | 100–8000 Hz | Pivot frequency of the tilt: the target equals pure pink there; boost/cut grows per octave away from it. |
| Min Frequency | 20–1000 Hz | Lower edge of analysis and processing. Below it the correction fades to 0 dB over half an octave. |
| Max Frequency | 1–22 kHz | Upper edge of analysis and processing, same half-octave fade above. The EQ bands are laid out between Min and Max. |
| Auto Gain Compensation | Off / On | When On, continuously matches output loudness to the (latency-aligned) input, independent of the correction and tilt. Manual Compensation Gain still applies on top as an offset. Makeup is clamped to ±24 dB and held during silence. |
| Side Chain | 4-way | How the side-chain input (channels 3/4) is used — see the table below. The correction is always applied to the main input. |
| Side Chain Gain | −60…+24 dB | Gain applied to the side-chain signal before it is used for analysis. |
| Side Chain Amount | 0–100 % | How much side chain is fed into the analysis in *Only side chain* and *Combined* modes. Ignored in *Reference* mode. |
| EQ Direction | Counteract / Mimic | **Counteract** (default) pulls the input *toward* the target — the current, corrective behavior. **Mimic** inverts the whole curve, pushing the input *away* from the target and exaggerating its deviations. |
| Side Chain Speed | 0.1–10 s | Averaging time of the side-chain spectrum analysis, independent of the main Speed. Used in *Only side chain* mode and for the reference spectrum in *Reference* mode; *Combined* mode uses the main Speed. |

### Side-chain modes

| Mode | What drives the profile | Target |
|---|---|---|
| No side chain | Main input | Pink noise (+ tilt) |
| Only side chain | Side chain × Amount | Pink noise (+ tilt) |
| Combined | Main input + Side chain × Amount | Pink noise (+ tilt) |
| Reference | Main input | **Side-chain spectrum** (+ tilt) — the main input is pulled toward the side chain's own tonal balance instead of pink. Falls back to pink until a side-chain signal is present. |

## Interface

The analyser fills the top of the window; the controls sit below it in Match /
Target / Side Chain panels with an Output column beside the graph.

Every knob has a number box under it: click it to type a value, or drag it to
scrub. On a knob, drag vertically, hold Shift for fine adjustment, use the
wheel, or Ctrl-click to reset to the default. Speed, Tilt Center, Min/Max
Frequency and Side Chain Speed scrub logarithmically on their knobs and
linearly in their number boxes.

A side-chain label is dimmed when the current mode ignores that control. The
**?** button opens the built-in guide.

The scale selector at the top right sizes the whole interface and is shared by
every open instance — it lives in `gmem`, so keep `UI_SCALE_DEFAULT` in step
across the Magnolius plugins or whichever one opens first in a session wins.
It defaults to 100%, which is pixel-exact against the `@gfx 790 548` window.
*Fit* is still there for the case where Reaper restores a smaller FX window,
but it scales by a fractional factor and softens the artwork.

### Display

Everything is plotted against pink noise, so a source that already matches pink
reads as a flat line at 0 dB.

- **Cyan** — the measured input spectrum, relative to pink.
- **Yellow** — in *Reference* mode only, the side-chain spectrum, also relative
  to pink. This is what you are matching *to*, and the vertical gap between the
  cyan and yellow traces is the correction being computed, before Target Tilt
  and Amount are applied.
- **Orange** — the correction curve currently being applied.
- **Gray line** — the target: flat at 0 dB for pure pink, tilted when Target
  Tilt is set (crossing 0 dB at the Tilt Center).
- **Red vertical lines** — the Min/Max Frequency processing range.

In previous versions the blue trace showed the input's deviation *from* the
side-chain reference in *Reference* mode. Both spectra are now drawn in the
same pink-relative space instead, so you can see the reference itself rather
than only the error against it.

## Notes

- Engine: STFT overlap-add (FFT 4096, 75 % overlap, sqrt-Hann windows).
  **Latency is 4096 samples**, reported to Reaper via PDC, so playback stays
  time-aligned; for live input monitoring you will hear the delay.
- Per-band correction is clamped to ±18 dB (`MAX_CORR_DB` constant in the
  file if you want a different limit).
- Analysis freezes when the input drops below −70 dBFS RMS, so the curve
  doesn't drift toward maximum boost during silence.
- Stereo is analyzed as the sum of both channels and the same correction is
  applied to both, so the stereo image is preserved.
- **Side-chain routing:** the plugin exposes 4 input channels. Send the
  trigger/reference signal to the track's channels 3/4 (e.g. a track send with
  *Audio → channels 1/2 → 3/4*, and set the FX's pin connector if needed). The
  side-chain channels are consumed for analysis and are not passed to the
  output. Any side-chain mode other than *No side chain* needs this routing.

## Quick sanity checks

1. Feed it **pink noise** → blue curve flat at 0, correction ≈ 0 dB.
2. Feed it **white noise** → correction settles to a −3 dB/octave tilt.
3. Amount = 0 % → output nulls against the dry signal (offset by the 4096-sample latency).
4. Stop playback → curves freeze rather than drift.
