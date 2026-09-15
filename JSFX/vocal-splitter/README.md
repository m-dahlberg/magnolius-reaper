# VocalSplitter

REAPER JSFX plugin that separates a vocal track into four elements —
**breaths**, **sibilance**, **hard consonants** (/t/, /k/, /ch/, /ts/), and
**residual** (everything else) — with independent gain per element, optional
8-channel stem output, and a scrolling color-coded waveform display.

Detection is time-domain (no FFT): a 4th-order bandpass tracks the sibilance
band, hard consonants are found by **shape plus absence of pitch** — a peak in
the consonant-band envelope with a low point on each side of it, over material
whose amplitude envelope is not pulsing at a pitch — and zero-crossing rate
and level-below-phrase catch breaths. Per-sample confidences for the four
classes always **sum to 1**, so with all gains at unity the output nulls
against the
input (verified to −307 dBFS, the floor REAPER's denormal-prevention DC
allows). All thresholds are normalized to a running phrase-level average, so
the detector tracks the singer, not the gain staging.

**Latency: `Cons max duration` + 20 ms** (100 ms at the defaults), reported via
PDC — REAPER compensates it everywhere, including renders. The consonant
detector cannot judge a peak until the window that has to contain it has gone
by, so the budget follows that slider, and **moving `Cons max duration` forces
a REAPER audio reset** (a click, or an FX reload). Every other slider is
reset-free; the lookahead slider in particular only pre-opens the gain
envelope. The head start is what lets a claim be back-filled to its exact
onset, giving clean stem fronts instead of confidence fade-ins.

This is a vocal-track plugin, not a bus plugin: anything transient and bright
(snare bleed, pick attack) will read as a hard consonant.

## Install

Symlink — do **not** copy, a copy silently goes stale when you edit the repo
(this actually happened: a stale v0.2 copy in `Effects/Magnolius/` shadowed
the plugin and made a whole debugging session chase ghosts):

```sh
ln -sfn ~/repos/jsfx/VocalSplitter/Magnolius_VocalSplitter.jsfx \
        ~/.config/REAPER/Effects/Magnolius/Magnolius_VocalSplitter.jsfx
```

Keep exactly one `Magnolius_VocalSplitter.jsfx` under `Effects/` — REAPER resolves the
FX by name, and a second copy anywhere in the tree can shadow the real one.

Reload the FX (or press Ctrl+S in REAPER's JS editor) after editing the
source; REAPER caches compiled JSFX per instance. The version label in the
top-right of the display tells you what is actually running.

## Sliders

### Hard consonant
Detection is by **shape**, qualified by **absence of pitch**. A sliding window
the length of *Cons max duration* runs over the consonant-band envelope, and
in it the detector looks for three points: a peak with a low point on each
side. If the peak stands *Cons peak prominence* dB above the **higher** of the
two low points, the span from the first low point to the last is claimed —
provided the material there is not pulsing at a pitch.

That last condition is what actually separates a consonant from a vowel. A
voiced sound is a glottal pulse train, so its amplitude envelope pulses at F0
(70–400 Hz). An unvoiced obstruent is noise, and noise has no periodic
envelope. The detector autocorrelates the **envelope** — not the waveform — at
F0 lags, which is both cheaper (the envelope is already decimated to ~4 kHz)
and better: it still works on a burst sitting on top of a sustained vowel,
where a waveform autocorrelation is swamped by the vowel.

**Read this before turning the knobs.** Measured on the reference clip against
independent harmonicity ground truth (worst case per region, so these are the
extremes, not medians):

| feature | consonant | vowel | gap |
|---|---|---|---|
| envelope periodicity | max 0.60 | min 0.66 | **+0.06** |
| waveform autocorrelation, 30 ms | max 0.66 | min 0.61 | −0.05 |
| band ZCR 3–9 kHz | p25 3364 Hz | p75 4909 Hz | *inverted* |
| band ZCR 1.5–6 kHz | p25 1682 Hz | p75 2182 Hz | *inverted* |
| HF/full ratio | p25 −32 dB | p75 −30 dB | none |
| **band envelope prominence** | **median 5.2 dB** | **max 6.5 dB** | **none** |

Two things follow. First, envelope periodicity is the only feature measured on
real vocal material with a positive gap, which is why it is the gate. Second —
and this is the one that will surprise you — **on that clip, prominence does
not discriminate at all**: its consonants are not level peaks, they sit at the
same level as the singing around them. The default of 2 dB is therefore
deliberately low, and on such material prominence is doing *segmentation*
(deciding where the event starts and ends) rather than detection. On material
where consonants really are transient peaks — plosive bursts, most spoken word
— prominence does the work it looks like it should, and the same detector
scores 50 dB of prominence on a /t/ release.

Note also that both ZCR rows come out **backwards**. On a dark voice the vowel
carries more high-frequency breath than the consonants do, so a
brightness-flavoured measure does not merely fail, it votes the wrong way.
Do not reach for one.

| Slider | Meaning |
|---|---|
| Cons periodicity | The envelope must be **less** periodic than this. **The dominant control on real vocals.** 0.58 is the measured knee; below ~0.50 short bursts start dropping out, above ~0.66 vowels start leaking. Move it in 0.02 steps and watch the *periodicity* readout. |
| Cons peak prominence (dB) | How far the peak must rise above the higher of the two low points. Low by default because on level-flat material it cannot discriminate — see above. Raise it to 6–9 dB for a strict "only real transients" mode on percussive material; that also cuts over-claiming sharply. |
| Cons min duration (ms) | The claimed span (low point to low point) must be at least this long. Rejects single-frame envelope wiggles. |
| Cons max duration (ms) | The sliding window itself, and therefore the longest claimable event. **This is how /s/ is told from /t/**: a fricative longer than the window has no low point on its trailing side inside it, so the shape never resolves and the consonant class never claims it. **Changing this changes latency and forces an audio reset.** |
| Cons level floor (dB below phrase) | Keeps room tone and reverb tails out — they are aperiodic too, but quiet. Real consonants sit 3–14 dB below the phrase average, room tone 40+. |
| Cons env attack / release (ms) | Shape the very envelope the peak/valley search reads, so these are **detection-critical, not cosmetic**. Too long a release erases the trailing low point; too short lets band ripple through as false turning points. |
| Cons band low / high edge (Hz) | The detection band (default 1.5–6 kHz). The peak/valley search runs on this band's envelope, so these matter as much as the thresholds. |

**If consonants are being missed**, in this order: (1) watch the
**periodicity** readout while the take plays — it is the number *Cons
periodicity* is compared against, and a missed consonant that never drops
below ~0.7 means the analyser is not seeing the pitch stop. Raise the slider
toward 0.66. (2) Lower *Cons peak prominence* toward 1 dB. (3) Raise *Cons
level floor* toward 30 dB if they are unusually quiet.

**If too much is being claimed**, raise *Cons peak prominence* first — it is
the blunt instrument, and at the low default the detector will claim a large
share of a busy vocal. Then lower *Cons periodicity* toward 0.52. A confirmed
sibilant owns its slots outright and a breath in progress blocks the trigger,
so leakage will be from vowels.

### Sibilance
| Slider | Meaning |
|---|---|
| Sib sensitivity (dB) | Offsets the band-dominance threshold. |
| Sib band low / high edge (Hz) | **Matters more than sensitivity.** Bright soprano /s/ sits at 7–9 kHz, dark male voices lower. A wrong band cannot be rescued by any threshold. |
| Sib min duration (ms) | Sustain required to confirm (distinguishes /s/ from a /t/ burst). Candidates are promoted provisionally at 40 % of this and back-filled to their onset; a candidate that dies early is revoked. Most fricatives never reach the consonant class at all now — they are longer than the consonant window — but a short one still can, and HF dominance sustained past 30 ms takes it back and reclaims the onset. From then on a confirmed sibilant **owns** its slots: the consonant detector's back-fill will not overwrite them. |

### Breath
| Slider | Meaning |
|---|---|
| Breath sensitivity (dB) | The dominant control for this class. |
| Breath below phrase (dB) | How far under the phrase average a breath sits. |
| Breath noisiness ZCR | Zero-crossing-rate floor (0–0.5, fraction of samples). Note: ZCR of band-limited noise falls with rising sample rate — retune at 96 k+. |
| Breath min duration (ms) | Typical breaths are 100–500 ms. A confirmed breath also gets a 350 ms hangover: one breath is one gesture, so mid-breath evidence dips (louder swells, noisiness wobble, even the near-silent turn-around between inhale and exhale) cannot split it into two with a stutter in between — the hangover bridges straight through silent gaps, so the second phase is classified breath from its first sample. Only real voice (level within 8 dB of the phrase average) ends it early, within a millisecond, so it never bleeds into singing. |
| Phrase average (ms) | Time constant of the level reference. Frozen below −70 dBFS so pauses don't drag it down. |

### Global
| Slider | Meaning |
|---|---|
| Confidence hardness (pct) | 0 % = soft crossfaded shares (gain riding in place); 100 % = winner-takes-all (stem export). Sum-to-1 holds at every setting. |
| Transition (ms) | Crossfade smoothing of the class envelopes. |
| Pre-open lookahead (ms) | Opens gain envelopes early relative to the audio, so the transition crossfade completes by the time an onset plays (default 10 ms ≈ one transition ahead). Never changes latency. |
| Output mode | *Sum to stereo* (normal insert) / *Split 8ch* (stems). |
| Listen | Solo one class — **the tuning control**. |
| Residual/Breath/Sibilance/Consonant gain (dB) | Per-class gain; −60 = mute. |

## Split output routing

Set the **track to 8 channels** (Route → Track channels: 8) — JSFX only sees
channels that exist on the track. In *Split 8ch* mode:

| Channels | Element |
|---|---|
| 1/2 | residual |
| 3/4 | breath |
| 5/6 | sibilance |
| 7/8 | consonant |

Pull stems onto other tracks with sends using explicit channel mapping
(e.g. send channels 3/4 → 1/2 of a "Breaths" track). Because confidences are
fractional below 100 % hardness, a moment appears in several stems at
different levels: re-summing untouched stems is lossless, but phase-shifting
EQ on one stem will comb against its correlated ghosts in the others. Use
100 % hardness for stem export.

## Display

Scrolling waveform (~22 s at 48 k), one column per 256 samples, tinted by the
dominant class: **gray** residual, **blue** breath, **amber** sibilance,
**red** consonant. Color fades toward gray at low confidence, so threshold
problems are visible at a glance. Below: live confidence meters and the raw
feature readout — **prom** (the current window's peak prominence in dB,
updated every frame whether or not anything fires) and **periodicity** (1.0 =
envelope pulsing at a pitch, low = noise). Those two are the consonant tuning
aids: compare them against *Cons peak prominence* and *Cons periodicity*.
Then band level, full-band level and the phrase average.

## Presets (slider values)

JSFX has no preset section; set these by hand or save REAPER FX presets.
Values not listed = defaults.

**Close-mic pop vocal** — defaults are tuned for this case.

**Breathy singer** (keep breaths natural, tame the rest)
: Breath sensitivity −6, Breath below phrase 30, Breath min duration 120,
  Transition 12.

**Spoken word** (podcast/VO cleanup)
: Cons periodicity 0.64, Cons peak prominence 3, Sib band 4000–10000,
  Breath sensitivity +3, Breath min duration 60, Phrase average 800.

## Quick sanity checks (by ear)

1. All gains 0 dB, any hardness: toggle bypass — no audible difference at all.
2. Listen: Sibilance on a vocal — you should hear only /s/, /sh/, /z/ hiss.
   If vowels leak in, raise the Sib band low edge; if /s/ is missing, it is
   probably outside the band — move the band, not the threshold.
3. Listen: Breath — breaths only, no word tails. Word tails leaking = raise
   the ZCR floor or Breath below phrase.
4. Listen: Consonant — short ticks at /t/ /k/ /s/-onset moments, including
   consonants landing mid-word and on sustained notes (no closure or pause is
   required). Sung vowels must stay silent here however loud or bright they
   get; if they tick, raise Cons peak prominence, then lower Cons periodicity.
5. Breath gain −60: breaths gone, words untouched, transitions click-free.

## Tests

```sh
python3 tools/render_test.py            # all
python3 tools/render_test.py unity stems
```

Headless REAPER renders (`reaper -newinst`, safe while your main REAPER is
open). Work dir `~/.cache/vocalsplitter-rendertest` (override: `VSPLIT_WORK`).
`features` generates a temporary debug build of the real source
(`VSPLIT_KEEP_DBG=1` to keep it for inspection). The `@gfx` display cannot be
exercised by offline renders — after display changes, check it live in REAPER.

`realclip` and `cons_prom` run against `Consonant test file.wav` in the repo
root (they skip with a notice if it is missing). **`realclip` is the anchor of
the whole suite**: it scores the plugin against ground truth derived
independently of it (autocorrelation harmonicity over the whole file), and
asserts every unvoiced region reaches the consonant stem and every voiced
stretch stays out. An earlier version asserted consonants wherever the
detector's *own* feature peaked — circular, and it validated a metric that
turned out not to separate consonants from vowels at all.

**`realclip` currently fails at 13/14 caught and 3/6 clean** (misses the
region at 4.25 s, leaks at 0.35, 2.20 and 3.90 s). That is a real regression
against the voicing-based detector this replaced, which scored 14/14 and 6/6,
and it is not a tuning oversight — the sweeps are in the git history of this
file's measurement tables. Neither threshold moves those three: the periodicity
feature genuinely reads those vowel stretches as aperiodic, and the shape
detector has nothing to add because the clip's consonants are not level peaks.
Do not "fix" it by loosening the assertion; either improve the feature or
decide the trade is acceptable for the material you actually work on.

Three things about the synthetic material are load-bearing, each having
previously produced a suite that passed while the plugin failed on real audio:

- `_voiced()` must keep presence-band energy (harmonics to ~8 kHz). The
  original 3-harmonic vowel had **nothing above 660 Hz**, so every consonant
  test passed vacuously against a band reference stuck at the floor.
- `_stop()` must model a real stop: a closure (voicing actually stops),
  a burst with energy from a few hundred Hz up, and a **decaying** aspiration.
  Bright noise added on top of continuing voicing is not a consonant, and a
  flat-amplitude noise block is fricative-shaped — the sibilance class
  correctly claims that one.
- `cons_voi` asserts the threshold moves the detector monotonically. This
  caught two separate latch bugs where *more* sensitivity produced *fewer*
  detections.

## Known limitations

- **The detector claims a large share of a busy vocal at the default
  prominence** (~45 % of the timeline on the reference clip). That is the
  direct consequence of prominence not discriminating on level-flat material:
  with the bar low enough to catch that clip's consonants, it is also low
  enough to catch a lot else that is unvoiced. Raise *Cons peak prominence*
  if your material has real transients.
- Time-domain gain assigns a whole moment to one bucket: a /s/ tailing a held
  vowel cannot be extracted without taking the vowel's top end with it. The
  escalation path is per-bin STFT masks at ~30 ms latency (not implemented).
- Voiced consonants are out of scope by construction: /b/ /d/ /g/ /m/ /n/ are
  voiced, so a pitch-based gate cannot see them, and no setting changes
  that. The class is unvoiced obstruents — /t/ /k/ /p/ /ch/ /ts/ and friends.
- A breath or a confirmed sibilant owns its gesture, so a consonant genuinely
  buried inside one is not extracted separately.
- The periodicity analyser costs ~0.9 M multiply-adds per second
  (autocorrelation on a ~4 kHz decimated envelope, recomputed every 5 ms) and
  the window scan another ~0.2 M. Cheaper than the waveform autocorrelation it
  replaced.
- Voiced consonants (/b/ /d/ /g/ /m/ /n/) are out of scope, as are /p/ /b/
  LF pops (they are pops, not HF harshness — use a different tool).
- Breath minimum durations longer than 40 ms confirm after the lookahead
  budget, so breath onsets ramp in over the excess (usually inaudible —
  breaths have soft onsets anyway).
- Consonant slider values saved in older projects are meaningless: sliders 1-6
  were repurposed in place, so an old *Cons aperiodicity* of 0.65 now lands on
  *Cons peak prominence* and is clamped to its range. Reset the consonant
  section on any project saved before v1.2.
