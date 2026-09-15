# PinkMatch EQ

A real-time spectral matcher for Reaper, written in JSFX. It continuously
measures the incoming audio's spectrum and applies an EQ curve that pulls it
toward a fixed **pink noise** profile (power ∝ 1/f, i.e. −3 dB/octave).

An optional **side-chain input** (channels 3/4) lets a second signal drive the
EQ profile — trigger the match from another track, blend it with the main
input, or match the main input to the side chain's own spectrum instead of pink.

## Install

Copy (or symlink) `Magnolius_MatchEQ.jsfx` into your Reaper Effects folder:

```sh
ln -s "$(pwd)/Magnolius_MatchEQ.jsfx" ~/.config/REAPER/Effects/Magnolius_MatchEQ.jsfx
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

## Display

- **Blue** — input spectrum relative to the target (pink noise, or the side-chain reference in *Reference* mode; a matching input shows as a flat line at 0 dB).
- **Gray line** — the target: flat at 0 dB for pure pink, tilted when Target Tilt is set (crossing 0 dB at the Tilt Center).
- **Orange** — the correction curve currently being applied.
- **Red vertical lines** — the Min/Max Frequency processing range.

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
