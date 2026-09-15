# Perceptual EQ Correction (JSFX)

A REAPER JSFX plugin that builds a corrective EQ for headphone monitoring
**without a measurement microphone**. Instead of sine sweeps into a calibrated
mic, it runs a loudness-matching hearing test: you match sine beeps at 15
frequency bands against a 1 kHz reference tone. The plugin then corrects the
deviation of *your* equal-loudness curve from the ISO 226:2003 standard
contour — compensating your hearing anomalies and your headphone's response in
one pass, while preserving normal tonality.

## Why deviation from ISO 226, not "flat"?

Making every frequency *sound equally loud* would invert the natural
equal-loudness contour of human hearing — music is mixed by people whose ears
have that same contour, so flattening it sounds wrong. Instead, the plugin
compares your measured curve to the standard contour and corrects only the
difference. If your ears + headphones behaved exactly like the standard, the
correction would be zero.

Borrowed from hearing-aid fitting practice: **full compensation is never
applied**. Loudness recruitment means a boosted dip does not sound the way you
would expect from the numbers. The *strength* slider (default 50%, the classic
half-gain heuristic) and the *max boost* cap (default +12 dB) keep corrections
safe and natural. Start at 50% and adjust by ear over a few days.

## How the correction curve is built

The 15 measured points are **not** turned into 15 independent bell filters
(bells overlap, so the cascade would miss the points, and the curve would sag
back to 0 dB between them). Instead:

1. A smooth target curve is drawn through the strength-scaled points: a
   monotone cubic (PCHIP) in log-frequency, lightly Gaussian-smoothed
   (σ = 0.12 oct) with interpolation-correction rounds so it stays smooth
   *and* still passes through the points. Hearing deviations are smooth on a
   log axis (auditory filters are ~⅓ octave), so this is the most faithful
   reading of 15 samples of a smooth function.
2. A 43-bell bank (band centers + 2 subdivisions per interval, bandwidth
   1.6× spacing) is least-squares fitted to that curve, with extra weight on
   the measured points and the 1 kHz anchor pinned to 0 dB. The fitted
   cascade lands within ~0.1 dB of every measured point.

The auto-headroom trim uses the true peak of the fitted curve, not the
largest single filter gain. Verified end-to-end by `tools/render_test.py`
(`curve` test) against `tools/fit_reference.py`, a line-by-line Python port
of the fit.

## Install

Copy or symlink `Magnolius_PerceptualEQ.jsfx` into REAPER's effects folder:

```sh
ln -s "$(pwd)/Magnolius_PerceptualEQ.jsfx" ~/.config/REAPER/Effects/Magnolius_PerceptualEQ.jsfx
```

Then in REAPER: FX browser → refresh (F5) → "Perceptual EQ Correction".
Put it **last on the Monitoring FX chain** (View → Monitoring FX) so it
corrects everything you hear but is never rendered into your mixes.

## Running the test

1. Use a quiet room and your normal headphones. Set *Mode* to **Test**.
2. Choose the ear mode: *Binaural* (fast, one curve) or *Per-ear* (twice as
   long, independent L/R curves — recommended, hearing is rarely symmetric).
3. Set *Assumed listening level (phon)* to roughly how loud the reference
   feels once you've set your volume: 60 ≈ moderate, 75 ≈ loud. Do this
   **before** testing and don't change it afterwards.
4. Click the plugin window (keyboard focus), set your system/interface volume
   so the 1 kHz reference tone is clearly audible and comfortable — then
   **do not touch the volume again until the test is done**.
5. For each band, the reference and the test tone alternate. Adjust the test
   tone (mouse wheel or Up/Down, 0.5 dB steps) until both sound **equally
   loud**, then press Enter/Space to confirm and advance. Left/Right revisits
   bands; R resets the current band to its predicted value.
6. When done, switch *Mode* to **Correct**. The plot shows measured deviation
   points and the applied EQ curve per channel.

Tips for good data:
- Take a break halfway; loudness judgment degrades with fatigue.
- Don't overthink a band — your first "sounds about equal" is usually as good
  as a minute of agonizing.
- Redo any band that seems wildly off (its dot will sit far from the curve).
- The 40 Hz and 16 kHz bands are the least reliable (headroom limits and lack
  of ISO data above 12.5 kHz); treat them with suspicion.

## Crossfeed (bs2b)

Correct mode has an optional headphone crossfeed stage based on Boris
Mikhaylov's open-source [bs2b](http://bs2b.sourceforge.net/) (Bauer
stereophonic-to-binaural) DSP: hard-panned content reaches both ears the way
speakers would — the opposite channel is lowpassed and fed across, the direct
path gets a complementary high boost, and an overall gain compensates the
level. Two parameters:

- *Crossfeed cut freq* (300–2000 Hz): where the cross path rolls off.
- *Crossfeed feed* (1–15 dB): how much of the opposite channel crosses over.

The classic bs2b presets are just slider positions: default **700 Hz /
4.5 dB**, C.Moy 700 Hz / 6 dB, J.Meier 650 Hz / 9.5 dB. The filters are
one-pole IIR — no added latency.

The Correct-mode signal chain is **crossfeed → reverb → EQ → trim**: the
crossfeed and reverb build the virtual listening room, and the personal EQ
correction applies to everything you hear, exactly like your ears do.

## Convolution reverb (true stereo)

Correct mode has an optional convolution reverb stage between the crossfeed
and the EQ, meant for adding a sampled room/hall to headphone monitoring:

1. Create `~/.config/REAPER/Data/ReverbIRs/` and drop impulse-response WAVs in
   it (any bit depth REAPER can read; any sample rate — IRs are resampled to
   the project rate on load).
2. Pick the IR with the *Reverb IR* slider, switch *Reverb* to **On**, and
   balance *wet*/*dry* (−60 dB = fully off).

Channel formats:
- **4-channel WAV = true stereo.** Channel order `LL, LR, RL, RR` (input
  letter first): ch1 = left input → left output, ch2 = left → right,
  ch3 = right → left, ch4 = right → right.
- 2-channel WAV = parallel stereo (ch1 = L→L, ch2 = R→R, no cross-feed).
- Mono WAV = the same IR on both channels.

Details worth knowing:
- Engine: uniform partitioned FFT convolution, 2048-sample partitions. The
  one-partition latency is reported to REAPER (PDC), which compensates it
  automatically; the dry path is internally delayed to stay sample-aligned
  with the wet path. While the reverb is enabled, Test and Bypass modes carry
  the same reported latency (test tones are unaffected — and never reverbed).
- IRs are capped at 262144 samples (~5.5 s at 48 kHz) and energy-normalized on
  load, so switching IRs keeps a comparable wet level.
- Long IRs cost real CPU (up to 512 spectra multiplied per partition at the
  cap). Offline renders are fine regardless; for live use with very long IRs,
  REAPER's anticipative FX processing absorbs the per-partition spikes.

## Notes and limits

- The reference tone plays at −40 dBFS. That sounds low, but equal loudness at
  40 Hz genuinely needs ~35 dB more level than 1 kHz, and that headroom must
  exist above the anchor. If a band hits the "level cap reached" warning, your
  setup (or hearing) can't reach equal loudness there — confirm anyway; the
  stored value becomes a lower bound and the boost cap limits the damage.
- The correction is only valid at roughly the loudness you tested at
  (equal-loudness contours are level-dependent).
- This is a monitoring aid, not a medical device. If the test shows a large
  asymmetric loss, see an audiologist.
- Speaker/room use is possible but pure sine tones interact badly with room
  modes; a warble-tone test signal is a planned extension for that case.

## Development

`tools/validate_iso226.py` re-implements the ISO 226:2003 math in Python,
checks it against published reference values, and prints the band offsets the
plugin should compute — run it after touching any of the contour code.

`tools/make_test_irs.py` writes synthetic test IRs (unit impulse, channel
swap, delayed impulse, L-only, 2-ch fallback, 96 kHz variant, dense 5.4 s
hall) into `~/.config/REAPER/Data/ReverbIRs/`.

`tools/fit_reference.py` is a Python port of the v0.7 correction fit (spline
target + least-squares bell-gain fit). It must be kept in sync with the EEL2
code; the `curve` render test asserts the two agree to 0.05 dB.

`tools/render_test.py` is a headless end-to-end test suite: it renders small
REAPER projects through the installed plugin (`reaper -newinst -nosplash
-renderproject`, safe to run while REAPER is open) and asserts on the audio —
identity/regression, unity gain through the convolver, true-stereo routing,
partition indexing, IR resampling, dry/wet alignment, the bs2b crossfeed
(sample-exact against a Python reference, including its position before the
reverb in the chain), and the correction curve (serialized hearing-test state
rendered through an impulse and probed at band centers and midpoints). Run it
after any DSP change:

```sh
python3 tools/make_test_irs.py   # once
python3 tools/render_test.py     # all tests; or: render_test.py unity swap
```
