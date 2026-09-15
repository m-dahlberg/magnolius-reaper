# Spectral DeNoise (JSFX)

Spectral noise reduction for REAPER as a native JSFX plugin. The DSP is a
port of the algorithms in [libspecbleach](https://github.com/lucianodato/libspecbleach)
by Luciano Dato (the library behind noise-repellent). JSFX cannot link native
code, so this is a reimplementation of the algorithms in EEL2, not a wrapper.

License: LGPL-2.1-or-later (see LICENSE), matching libspecbleach.

## Install

```sh
ln -s "$PWD/Magnolius_DeNoise.jsfx" ~/.config/REAPER/Effects/Magnolius_DeNoise.jsfx
```

Then add "SpectralDenoise" as a track FX. Keep it a symlink: a plain copy
silently goes stale when the repo changes.

## Usage

Two ways to get a noise profile:

- **Manual (best quality):** set Mode to *Learn Noise Profile*, play a
  noise-only section (half a second is plenty), switch Mode back to
  *Denoise*. The profile is saved with the project. Entering learn mode
  again starts a fresh capture; *Reset Noise Profile* clears it.
- **Adaptive:** set Mode to *Adaptive*. The SPP-MMSE estimator tracks the
  noise floor continuously — no learning pass. Allow a couple of seconds
  to converge. Note: anything held perfectly steady for several seconds
  (test tones, hums) is eventually treated as noise; that's inherent to
  adaptive tracking. Use manual learn for material like that. If a manual
  profile exists it seeds the adaptive estimator.

Controls:

| Slider | Meaning |
|---|---|
| Reduction dB | How far the noise floor is pushed down (residual mix level) |
| Strength | Oversubtraction aggressiveness (Berouti alpha 1..4). Higher = deeper reduction, more risk of artifacts |
| Smoothing | Frame-to-frame spectral smoothing; with NLM on it also sets the NLM similarity bandwidth (h). Less musical noise, but can blur transients |
| Residual Listen | Output only what is being removed — invaluable for tuning |
| FFT Size | 2048 default (~43 ms @ 48 kHz). Larger = finer frequency resolution, more latency |
| Residual Whitening % | Reshapes the reduction floor so the residual noise is spectrally flat instead of keeping the noise's color. Hides "watery" flutter in colored noise floors; ~30–50 % is usually enough (50 % ≈ perceptually white, 100 % inverts the tilt and sounds hissy) |
| Musical Noise Smoothing NLM | Non-local-means smoothing of the SNR spectrogram (the 2D denoiser from libspecbleach, Lukin-Todd). Directly removes musical-noise flutter before gains are computed. *Eco* is real-time friendly; *Full* searches a wider window (heavier CPU — intended for offline renders). Adds one extra FFT of latency while enabled |

Latency equals the FFT size (twice that with NLM enabled) and is reported
to REAPER for full PDC.
The display shows input spectrum (blue), noise-floor estimate (orange) and
the applied gain curve (green) on a log-frequency axis.

### Taming the watery sound

The classic spectral-subtraction artifact — watery flutter in quiet
passages — has two dedicated tools: enable **NLM** (Eco) to smooth the
gain field across time and frequency, and add **Residual Whitening**
(30–50 %) so what remains of the floor is featureless hiss. Raising
**Smoothing** widens the NLM similarity acceptance and calms the mids
further; at 0 the NLM only smooths the top octaves (the reference
libspecbleach tuning).

## Output gate / expander

An optional broadband noise gate runs on the denoised output as a final
stage (not part of libspecbleach). Enable it with the *Gate* slider:

| Slider | Meaning |
|---|---|
| Gate Threshold dB | Level the detector must exceed to open (3 dB close hysteresis in gate mode) |
| Gate Attack ms | Opening time |
| Gate Hold ms | Time the gate stays open after the signal falls below threshold |
| Gate Release ms | Closing time |
| Gate Mode | *Gate* mutes below threshold; *Expander* attenuates by the ratio instead |
| Expander Ratio | Downward expansion ratio (1:n) — every dB below threshold becomes n dB |
| Gate Auto Timing | *Auto Vocal* overrides attack/release: 1 ms attack, program-dependent release (60–400 ms — short bursts cut fast, sung/spoken phrases get long tails). Hold stays manual |

When enabled, a scrolling waveform panel (~4 s) appears below the spectrum:
signal level in blue, the threshold as a fixed yellow line, and gain
reduction drawn downward from the top in red, with a live GR readout.

## What is ported from libspecbleach

- STFT: Hann analysis/synthesis, 4x overlap, power spectra (`configurations.h` 1D defaults)
- Manual profile: mean power spectrum over the learn period
- Adaptive: SPP-MMSE estimator (`spp_mmse_noise_estimator.c`) incl. seeding,
  stagnation cap and silence hold, plus 3-tap noise-floor smoothing
  (`smooth_spectrum` @ 0.5)
- Berouti per-bin SNR-adaptive oversubtraction (`suppression_engine.c`)
- Rising-only temporal smoothing (`spectral_smoother.c`, FIXED type)
- Wiener gain with reduction-dB residual mixing (`gain_calculator.c`)
- Residual whitening + noise-floor clamping (`spectral_whitening.c`,
  `noise_floor_manager.c`): median-anchored valley-fill weights on the
  reduction floor, damped toward unity as reduction approaches 0 dB
- NLM 2D spectrogram filtering (`nlm_filter.c` + the `spectral_2d_denoiser.c`
  pipeline): SNR frames ring, patch matching over a time-frequency search
  window with frequency-dependent h, 4-frame lookahead, gains computed on
  the delayed frame. Documented deviations: patch distances are normalized
  per term (the reference's 8x8 patch is otherwise 4x stricter than
  intended and barely smooths below ~15 kHz), the Smoothing slider maps to
  h = 0.5–5.0 (reference default h=1 only smooths the top octaves), and the
  rising-only temporal smoother stays active in the NLM path (the reference
  2D pipeline drops it, which chatters at low frequencies where NLM finds
  few matches)

Not (yet) ported: Johnston masking veto, tonal reducer, Brandt / Martin
estimators, median/max/min profile morphing (aggressiveness steering),
gap interpolation.

## Tests

Headless render tests (work while a normal REAPER instance is running):

```sh
python3 tools/render_test.py            # all tests
python3 tools/render_test.py unity learn
```

Covers: bit-accurate unity reconstruction at all FFT sizes, latency vs
reported PDC (impulse), non-vacuous residual-silence guard, slider parse
probe via ReaScript, learn-mode reduction with tone preservation (Mode
driven by PARMENV automation), adaptive convergence and burst preservation,
profile restore through project state (`<JS_SER`), residual whitening
(HF floor lift + flattened residual on colored noise), NLM delay
bookkeeping (impulse alignment through the delayed-spectrum path), NLM
flutter reduction (temporal std of short-window DFT magnitudes, off vs
Eco vs Full), NLM over the adaptive estimator with burst preservation,
gate mute/unity behavior, expander ratio accuracy, and auto vocal timing
(verified to override the manual attack/release sliders).
