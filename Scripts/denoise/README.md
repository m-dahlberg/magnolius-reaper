# Spectral DeNoise (ReaScript)

Offline spectral noise reduction for REAPER. The DSP is a port of the
[SpectralDenoise JSFX](../../jsfx/DeNoise), which is itself a port of
[libspecbleach](https://github.com/lucianodato/libspecbleach) by Luciano Dato.

Every parameter of the plugin is here. The one thing that is different is the
one thing worth being different offline: **there is no learn pass.** The script
reads the whole file first and derives the noise profile from its own level
distribution.

License: LGPL-2.1-or-later, matching libspecbleach.

## Install

Requires **ReaImGui** (ReaPack). It is used for the panel *and* for the DSP
kernel, via `CreateFunctionFromEEL`.

```bash
ln -s "$PWD" ~/.config/REAPER/Scripts/SpectralDenoise
```

Then add `Magnolius_DeNoise.lua` in Actions → Show action list → New action → Load
ReaScript.

## Use

Select one audio item, run the action, press **Analyse**. Then work down the
panel:

1. **Noise band** — the histogram is the level distribution of the whole file.
   Material with pauses is bimodal: a room-tone lobe low down and a programme
   lobe above it. The green band is the set of frames that will be averaged
   into the noise profile, and Auto puts it on the room-tone lobe.
2. **Spectrum** — what came out of that band (orange) against the file's mean
   spectrum (blue) and the gain curve the current settings produce (green).
   Reduction, Strength and Whitening redraw it as you drag.
3. **Denoise** — shape the reduction. Start with Reduction and Strength; reach
   for NLM and Whitening only if it sounds watery (see below).
4. **Render** — writes a new file and hangs it on the item as a take, so A/B is
   a take switch and the original is never touched.

**Residual listen** renders what is being *removed* instead. It is the fastest
way to hear whether the settings are eating signal: anything you can recognise
in the residual is something you are losing.

### How the profile is found

The analysis pass does not keep the frames. It keeps a **level-binned
spectrogram histogram**: for every 1 dB of broadband frame level, the summed
power spectrum of the frames at that level and how many there were.

That single structure is what makes the panel work. Choosing a level band
chooses a set of frames, so the profile is the mean of the rows in the band —
which is *exactly* the quantity the JSFX learn mode accumulates by hand, with
the frames picked by the distribution instead of by you finding a gap in the
take. Moving the band recomputes the profile in under a millisecond without
re-reading a sample, which is why the histogram can be a live control rather
than a report.

Auto placement looks for the lowest **prominent** lobe above the silence floor:

- *Prominent*, not *tall*. A take that is mostly speech with a few seconds of
  room tone puts maybe 3 % of its frames in the noise lobe. That lobe is a
  clean, isolated mode with seconds of room tone under it — everything we want
  — and a fraction-of-the-maximum threshold throws it away. Topographic
  prominence keeps it.
- *Lowest*, not *tallest*. In a sparse vocal the room-tone lobe is the taller
  one; in a dense one it is not. Scanning upward gets both right.
- *Above the silence floor*. Edited-in digital silence forms its own spike far
  below the room tone. Averaging it into the profile would halve the profile
  and the reduction would quietly fall short, so frames below **Ignore below**
  are excluded — it is not room tone, it is nothing.
- *Not on a silence island*. A flat dB threshold is not enough, because edited
  silence does not always land where you can put a threshold. See below.

If no lobe qualifies the script says so and falls back to the quietest tenth of
the file. If the band ends up within 12 dB of the programme material it warns
that the profile will contain signal as well as noise. Both cases mean the same
thing: this file has no quiet passages, and no amount of analysis invents one.

#### Silence islands

A recording's own noise floor is **continuous** with the material above it:
every phrase decays through it, so the histogram bins between the two are
populated. Edited-in silence is not continuous with anything. Strip-silence, a
hard noise gate, or the noise-shaped dither a 16-bit master carries in its
pauses all put a lobe on the histogram with a wide *dead* gap above it — the
recording never passed through those levels at all.

`DeNoise test 02.wav` is the case in point, and the reason this exists: 29 % of
its frames are dithered digital silence at **−84 dB**, then twenty dB of
nothing, then the real room tone at **−59 dB** and the voice above that.
Scanning up from the bottom found the dither, built a profile 45 dB under the
hiss, and the render was a measured **0.1 dB no-op** — with the panel reporting
a healthy 64 dB of separation the whole time, because by every measure it had,
it was.

A fixed dB threshold cannot do this job: the island's level is set by the
master's bit depth, not by the room, so it moves from file to file. The shape
does not. So the scan steps over any lobe with a dead gap above it — **but only
when there is another lobe above the gap that is itself far below the programme
material.** A room-tone lobe can sit behind a gap too, on a take whose pauses
are clean and whose speech is loud, and skipping that one would put the band on
the voice. What waits above the gap is what tells the two apart.

Whatever gets stepped over is named on the histogram and in the panel, and
**Ignore quiet lobes…** turns the whole thing off.

### Controls

| Slider | Meaning |
|---|---|
| FFT Size | 2048 default (~43 ms @ 48 kHz). Larger = finer frequency resolution |
| Below / Above the lobe | How far the auto band extends either side of the detected lobe |
| Ignore below | Frames quieter than this are digital silence, not room tone |
| Ignore quiet lobes… | Step over stripped pauses and dither wherever they landed — see *Silence islands* |
| Profile trim | Nudge the whole profile up or down. Up subtracts more everywhere |
| Noise estimate | *Whole-file profile*, or *Adaptive* (SPP-MMSE, tracks the floor continuously — for noise that drifts through the take) |
| Reduction dB | How far the noise floor is pushed down (residual mix level) |
| Strength | Oversubtraction aggressiveness (Berouti alpha 1..4). Higher = deeper reduction, more risk of artifacts |
| Smoothing | Frame-to-frame spectral smoothing; with NLM on it also sets the NLM similarity bandwidth (h) |
| Residual Whitening % | Reshapes the reduction floor so the residual is spectrally flat instead of keeping the noise's colour. ~30–50 % is usually enough |
| Musical Noise Smoothing NLM | Non-local-means smoothing of the SNR spectrogram (Lukin-Todd). *Eco* is cheap; *Full* searches a wider window and is genuinely slow — which is fine here, nothing is running in real time |

**Reset all settings to default** sits under the FFT size. It puts every
control on the panel back to its shipped value and forgets what was saved, so
a session that has been dragged into a corner can start again without hunting
for which slider did it. It keeps the analysis: only a change of FFT size
invalidates the histogram, and only then does it ask for a re-analyse.

Plus the full output gate / expander from the plugin: threshold, attack, hold,
release, gate-vs-expander, ratio, and Auto Vocal timing (1 ms attack,
program-dependent 60–400 ms release).

### Taming the watery sound

The classic spectral-subtraction artifact has two dedicated tools: enable
**NLM** (Eco) to smooth the gain field across time and frequency, and add
**Residual Whitening** (30–50 %) so what remains of the floor is featureless
hiss rather than a flutter that keeps the noise's shape. Raising **Smoothing**
widens the NLM similarity acceptance and calms the mids further.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_DeNoise.lua` | entry action |
| `dn/config.lua` | every tunable, plus ExtState persistence |
| `dn/dsp/denoise.eel` | the kernel: FFT, STFT, the whole denoise chain, and the histogram |
| `dn/kernel.lua` | compiles it and owns the memory map; nothing above this knows an address |
| `dn/analyze.lua` | accessor loop → the histogram |
| `dn/profile.lua` | band placement (pure Lua) |
| `dn/gains.lua` | the per-bin gain chain (pure Lua) |
| `dn/render.lua` | accessor loop → denoised samples → WAV |
| `dn/wav.lua` | 32-bit float WAV writer |
| `dn/apply.lua` | adds the result as a take (the only file touching the project) |
| `dn/ui.lua` | panel |

| `test/fixture.lua` | the fixture track and the measurement helpers the audio suites share |

`profile`, `gains` and `wav` are pure Lua with no `reaper` dependency, which is
what makes the headless tests possible.

## Notes on the design

**The kernel has its own FFT.** ReaImGui's EEL sandbox provides standard EEL2
plus `memcpy`/`memset`, but not the `fft()` builtin JSFX gets from REAPER, so
`denoise.eel` implements radix-2 Cooley-Tukey with its own twiddle and
bit-reversal tables. That is the one piece of genuinely new DSP in the script
and the one most worth testing, which is why `test/fft_ref.lua` carries the
same algorithm in Lua for `test/headless.lua` to check against a naive DFT.

**The job cannot read its own audio.** REAPER refuses to run
`GetAudioAccessorSamples` from inside a Lua coroutine: the call returns `nil`
and leaves the buffer exactly as it was. It does not error and it does not
return 0, so analysis and render — both coroutines, so the UI survives a long
take — quietly saw a *completely silent file*. Every frame binned as digital
silence, the silence floor excluded all of them, and the panel reported "Only 0
frames in the noise band" on every file. Nothing else on that path has the
problem: `reaper.array`'s own methods and ReaImGui's `Function_SetValue_Array`
all work fine from a coroutine — it is that one call. So `dn/analyze.lua`'s pump
never reads. It yields a filled-in request and whoever drives the coroutine —
the panel's `step_job`, or `Analyze.drive` for the tests — does the read on the
main thread and resumes. An unserviced request is a hard error rather than a
buffer of zeros, because the silent version of this was invisible for as long as
it existed.

**Latency is compensated by hand.** The STFT delays everything by one FFT, two
with NLM — the figure the JSFX reports through `pdc_delay`. Offline there is no
host to compensate it, so the render pushes that many extra samples through and
drops the same number from the head of the output. Getting this wrong slides
the whole take against the original and is invisible until you A/B it, which is
what `test/verify_edit_in_reaper.lua` exists to catch.

**What the accessor actually returns.** The take audio accessor's timeline is
**item** time, and the audio it hands back already has the take's playrate,
pitch shift and channel mode applied. Measured on REAPER 7.75:
`GetAudioAccessorEndTime` returns `item_len` at every playrate, and with
`B_PPITCH` off a 440 Hz source comes back at 550 Hz on a playrate of 1.25. It
does **not** apply take volume, item volume or pan.

That was got wrong here in both directions at once, and neither half could be
seen at playrate 1, where every quantity involved is the same number.
`analyze.lua` read `item_len * playrate` samples, which on a stretched item
runs past the end of the accessor: it captured `item_len` seconds of
already-stretched audio and then silence. `apply.lua` then copied
`D_PLAYRATE`, `D_PITCH`, `B_PPITCH` and `I_CHANMODE` onto the new take, which
applied all four a second time. The result was a denoised take that sat at the
wrong length and drifted against the original by exactly the playrate.

So the span to read is `item_len`, and the only take properties worth copying
are the two the render never saw — `D_VOL` and `D_PAN`. The stretch properties
are set to neutral instead. `test/verify_edit_in_reaper.lua` now asserts that
directly, ahead of the null, because a null failure alone cannot say which of
the two mistakes it is looking at.

The instruction to run that suite on a time-stretched item was in this README
the whole time. It says something that it took a second script hitting the same
API to actually do it.

**The source sample rate cannot be read from the take.**
`GetMediaSourceSampleRate` returns 0 on a take whose media has been offline at
some point -- the drive was unplugged, the file moved -- and it keeps returning
0 once the file is back. `GetMediaSourceLength` returns 0 with it, while the
audio accessor returns perfectly good audio, so nothing looks wrong.

Falling back to the project rate is a guess, and when it is wrong everything
downstream is wrong with it. On a 48 kHz take in a 44.1 kHz project it meant
analysis, the kernel and the written file all ran at 44.1: the take played at
the right *duration*, so the only visible symptom was a null test stuck at
-29 dB -- the two sides were being resampled independently at different seek
offsets, and that sub-sample phase error is invisible to an integer shift
search. The real damage was quieter: the rendered take had been downsampled.

`analyze.lua`'s `source_format` asks the file instead. A fresh
`PCM_Source_CreateFromFile` over the same path reports the rate correctly even
when the take's own source does not, so it is consulted before any guess, and
the guess -- if it ever comes to that -- is reported rather than assumed.

**A rendered file has no waveform until you build its peaks.** REAPER builds
peaks for files that arrive through an import path -- the media explorer,
drag-drop, Insert media. A source created with `PCM_Source_CreateFromFile` and
attached with `SetMediaItemTake_Source` has none, and nothing ever asks for
them, so the new take plays back perfectly and draws an empty lane: audio is
decoded on demand, peaks are not. `apply.lua` therefore runs
`PCM_Source_BuildPeaks` (start / run to completion / finish) on the source
before attaching it, outside the undo block since it is not a project edit.
Measured on 7.75, `PCM_Source_GetPeaks` returns 0 samples before that call and
the full request after it; a 10 s file takes two slices, and the result is
cached under `<dir>/peaks/` so it is paid once per file.

Nothing else in the test suite could see this. The nulls, the geometry
assertions and the take-property checks all read the audio, and the audio was
always correct -- which is exactly why it survived. `verify_edit_in_reaper.lua`
now asserts the peaks directly.

**The profile is not smoothed.** The adaptive estimator's floor is (that is in
libspecbleach), but a mean over thousands of frames is already a low-variance
estimate, and smoothing it would spread a narrow line — mains hum, a whine —
across its neighbours and leave the line itself under-subtracted.

**Analysis stride adapts.** One frame every half an FFT is far more than a mean
power spectrum needs. On a long file the stride stretches so the frame count
stays near `max_frames`, which bounds analysis time without biasing the
statistics: a wider hop is even sampling, not a different measurement.

**Long files.** Analysis is roughly one FFT per half-window; rendering is two
per hop per channel, plus the gain chain. Expect a couple of minutes for a
five minute stereo take with NLM off, and considerably more with NLM Full.
Both run under a progress bar and can be cancelled.

## Tests

**Headless** — the pure-Lua stages and the FFT algorithm. No REAPER, no audio:

```bash
lua test/headless.lua
```

Covers the transform against a naive DFT and its unscaled round trip, the Hann
level normalisation the whole histogram hangs on, band placement across five
distributions (room tone + voice, with digital silence, continuous material,
sparse pauses, manual and sparse bands), silence-island rejection in both
directions (an island is stepped over; a lone room-tone lobe behind a gap is
not), the Berouti/Wiener/floor chain, the whitening weights, and the WAV
writer's header and sample round trip. It also reads `dn/ui.lua` and checks
that every control on the panel names a config key that exists — a key renamed
out from under a slider is a Lua error the moment the user drags it.

**In REAPER** — four scripts, run from the Actions list:

- `test/selftest_in_reaper.lua` — drives the EEL kernel on synthetic signals
  with analytically known answers, with no item or project state involved. Run
  this first if anything looks wrong. The key assertion is that at 0 dB
  reduction the STFT **reconstructs to unity**, and that the delay is *exactly*
  the reported latency — the test also checks that the error at ±1 sample is
  large, so an off-by-one cannot pass. Also covers NLM's doubled delay, channel
  isolation, the -3 dBFS level of a full-scale sine, the profile peaking in a
  sine's own bin, reduction depth, tone preservation, residual listen, and the
  gate and expander.
- `test/verify_edit_in_reaper.lua` — select an item; it runs the full pipeline
  at 0 dB reduction and compares the rendered take against the source through
  two accessors, scanning ±8 samples for a slip. A correct pipeline nulls at
  shift 0. **Run it on a time-stretched item too** — at playrate 1 the playrate
  path is never exercised.
- `test/effectiveness_in_reaper.lua` — needs no selection: it builds its own
  fixture from `DeNoise test 02.wav` and asks the question none of the others
  do, which is **whether the thing works**. It states the job as a contrast —
  hiss removed in six room-tone windows against voice lost in four speech
  windows, both above 3 kHz — and asserts the direction, the size *and the
  ratio* of it, because a broadband attenuator also removes hiss. It takes
  about 12 seconds and currently measures **8.4 dB of hiss removed for 0.0 dB
  of voice** at the shipped defaults. Before silence-island rejection it
  measured **0.1 dB**, while every other suite in the repo was green: each of
  them asks whether a stage is well behaved, and a pipeline that does nothing
  at all is extremely well behaved.
- `test/sweep_in_reaper.lua` — the tuning instrument. Asserts nothing, prints
  two tables, blocks the UI for about a minute and a half. The first compares
  the learned profile against the **true** room tone — measurable, by analysing
  only the room-tone windows in a second kernel — as a per-octave error for
  each band setting, so a band reaching into the programme material shows up
  as a positive error in the low mids. The second maps Reduction and Strength
  onto dB actually removed.

All of these end with `os.exit(0)` only when everything actually passed, so
a script runner, a CI job or an `&&` chain can read the result rather than
having to scrape the text for the word FAIL. In the two in-REAPER suites the
call is guarded (`if os.exit then`), because REAPER's embedded Lua has no
`os.exit` — run from the Actions list they simply print their report as before,
and only a harness that supplies one sees the code. Anything that stops a run
short counts as a failure, "no item selected" and "ReaImGui is missing"
included: a green exit has to mean the thing was verified, not that the script
declined to look.

## Known limits

- Operates on the first selected item. The pipeline is item-scoped, so a batch
  loop is a small addition, but it is not wired up.
- The accessor reads the take **as it plays**, not as it sits on disk: the
  playrate, pitch shift and channel mode are already applied to what comes
  back, and take FX are included too. The render is written at the source rate
  over the item's own span, and goes back on a take with neutral stretch
  settings — see *What the accessor actually returns* below.
- Output is 32-bit float WAV, capped at the 4 GB the format allows; the script
  refuses up front rather than discovering it ten minutes in.
- The analysis cache lives for the session only.
- **Reduction dB is a gain floor, not a promise.** The Berouti rule passes any
  bin whose instantaneous noise power exceeds `alpha` times the profile, and
  noise fluctuates bin to bin, so the measured depth always lands under the
  setting. Strength *is* alpha, and it is what closes the gap. Measured on
  `DeNoise test 02.wav` by `test/sweep_in_reaper.lua`:

  | Reduction | Strength | hiss removed above 3 kHz |
  | --- | --- | --- |
  | 10 | 30 (defaults) | 8.4 dB |
  | 18 | 30 | 11.4 dB |
  | 18 | 60 | 13.0 dB |
  | 24 | 60 | 14.1 dB |
  | 24 | 100 | 15.8 dB |
  | 30 | 100 | 16.4 dB |

  Voice loss above 3 kHz was 0.0 dB in every row. The same effect is why the
  kernel selftest's "pure noise is reduced by about the set depth" assertion
  reads −13.1 dB against a setting of −18 at Strength 30: the figure is the
  algorithm, not a transcription bug. Reach for Strength before Reduction.
- The auto band's default width (**8 dB below / 4 dB above** the lobe) leans
  towards having enough frames rather than towards precision. On
  `DeNoise test 02.wav` it over-estimates the profile by 1.6–3.6 dB below
  2 kHz, where speech lives and hiss does not; *Above the lobe* = 2 brings that
  to 0.4–2.3 dB and costs 0.3 dB of hiss removal. It is left wide because the
  measured voice cost is zero either way, but on material where the voice sits
  closer to the floor, narrow it.
