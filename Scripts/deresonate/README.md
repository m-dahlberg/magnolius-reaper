# DeResonate

Finds fixed-frequency resonances and broad colouration in a close-mic vocal by
using the singer's own pitch to tell a room problem apart from the voice, and
estimates how long the room rings.

A close vocal recorded in an untreated room carries two defects a general
de-noiser cannot separate from the singer: **narrow resonances** that sit at
fixed absolute frequencies -- room modes, mains hum, a resonant object -- and
**reverb**, exposed between phrases and masked under them. Neither is easy to
see in a long-term spectrum, because a voice's own harmonics and formants
produce persistent peaks that look exactly the same.

The idea the script is built on is that the two are distinguishable by whether
they *move with the singer*. A harmonic tracks f0; a room mode does not. The
NoteLeveling script already carries a production YIN tracker, so that pitch
information is free.

## Install

```bash
ln -sfn "$PWD" ~/.config/REAPER/Scripts/DeResonate
```

Then Actions -> Show action list -> New action -> Load ReaScript, and pick
`Magnolius_DeResonate.lua` inside the symlink. Requires **ReaImGui** (ReaPack), which
provides both the panel and, through `CreateFunctionFromEEL`, the analysis
kernels.

## Use

Select an item with an audio take and press **Analyse**. A 54 s mono take
analyses in under three seconds.

### The spectrum plot

Blue is the level percentile, orange the 1/3-octave energy envelope the
prominence of a peak is measured against, violet the **occupancy** -- how often
the singer was putting a harmonic at that frequency -- and red marks accepted
candidates. The violet is the part worth reading: on real takes the answer to
"why was that rejected" is nearly always "because the singer sings there".

#### Edited-in silence

Every percentile here is taken over every frame of the file, and that is only
the right statistic if every frame is a frame of the recording. Strip-silence,
a hard noise gate, or the noise-shaped dither a 16-bit master carries in its
pauses all put a population at the very bottom of every bin's histogram that
the microphone never produced. **If it is larger than the percentile being
asked for, the percentile lands inside it — at every frequency at once.**

Measured on a 74 s voice take whose pauses had been stripped, 27 % of its
frames: the p20 curve came back as a *perfectly flat line* at the bottom of the
level axis, 0.0 dB of spread across the whole spectrum. Every detector here
measures a curve against a smoothed copy of itself, and a constant minus its
own envelope is zero — so nothing could be detected, and nothing said so. The
ring floor is p10 per band, which takes even less silence to pin: every band
reported −140 dB, so the `floor_db + ring_head_db` gate admitted everything and
ring times were taken over dither decay.

What separates edited silence from a real noise floor is not its level — that
is set by the master's bit depth and moves from file to file — but that nothing
lies between it and the material. A recording's own floor is continuous with
what sits above it, because every note decays through it. So `spectrum.floor_bin`
steps over a population with a wide *dead* run above it, and every percentile
starts there.

It will not step into the signal. A bin whose own content is bimodal — loud
whenever a harmonic sweeps through it, at the floor otherwise — looks like an
island from below, and stepping over its lower mode would *raise* the
percentile into the signal and manufacture a peak where there is none. So the
step is refused if it would cross more than half the frames or leave fewer than
30 behind. Refusing is the safe failure: the curve stays pinned, which the
panel now says out loud, rather than moving somewhere plausible and wrong.

The panel reports the spread of the curve, names what was stepped over, and
turns red when there is no statistic left to detect against. **Ignore edited-in
silence** turns the whole thing off, for diagnosis.

### Narrow resonances

A candidate must clear three tests:

- **prominence** above the 1/3-octave envelope, which removes broad tilt and
  proximity-effect shelf, because those move the envelope with the peak;
- **Q**, which is the primary false-positive guard. A room mode at T60 0.4 s is
  2.2/T60 = 5.5 Hz wide, so Q is about 18 at 100 Hz; a vowel formant is
  50-150 Hz wide, Q 5-10. Without this a singer who favours one vowel reads as
  a roomful of modes;
- **occupancy**, which rejects the singer's own harmonics.

Expect an empty list on a good take. On both reference recordings the correct
answer is *nothing worth cutting*, and the panel says so.

### Broad colouration

Measured at **1/1 octave against a 2-octave baseline**, which is a different
measurement from the one above and finds a different defect. A 1/3-octave curve
divided by its own 1/3-octave envelope cancels any feature that wide, so the
narrow detector is blind to broad humps *by construction*.

Each hump is attributed by running the same measurement on the direct-dominated
percentile and the tail-dominated one: stronger in the tail means the room,
stronger in the direct means the source, the microphone, or a boundary. You
should know which one you are fixing.

The search starts above the singer's own fundamental range. Below that the
strongest "hump" on any take is simply where the voice lives -- 152 Hz on a
male take whose f0 median is 169 Hz -- which is a mix decision, not a defect.

### Correction

Each finding becomes an RBJ peaking section, and its gain is **solved, not set
to the measured height**. The solver bisects the real `|H|^2` of the whole
cascade until it delivers the required attenuation at the target frequency, so
two overlapping cuts do not double up.

The two kinds of finding ask for different things, and this matters:

- a **narrow** candidate is brought down to the 1/3-octave envelope it stands
  proud of;
- a **broad** hump is asked to undo its own measured deviation from the
  2-octave baseline.

Solving a broad hump against the 1/3-octave envelope instead is wrong, and
wrong quietly: that envelope *follows* a hump an octave wide, so the gap it
measures is nearly zero. On the reference take it produced a -0.50 dB cut where
-4.4 dB was called for.

A measured Q runs to three figures on a near-sinusoidal line, and a biquad that
narrow rings audibly, so `max_q` caps what actually gets built.

**Suppress resonances** switches the whole cascade out. Off means no filters at
all rather than filters at zero gain, so the stage is a bit-exact pass-through
and the two halves of the script can be judged one at a time.

### Reverb

A ring figure per band, pooled and reported. **It is not a T60.** It is the
fastest decay each band achieves: on the reference takes it reads 0.14-0.18 s
where the true T60 is nearer 0.44 s.

What relates the two was never measured until `test/t60_calib_in_reaper.lua`
drove a dry signal plus combs of *exactly known* T60 through the same ring
pass and swept the decay:

| true T60 | 0.15 | 0.20 | 0.30 | 0.40 | 0.55 | 0.70 | 0.90 | 1.10 | 1.60 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ring p50 | .108 | .133 | .164 | .176 | .202 | .202 | .216 | .232 | .248 |
| ratio | 1.4 | 1.5 | 1.8 | 2.3 | 2.7 | 3.5 | 4.2 | 4.8 | 6.4 |

**It is not a constant factor.** The statistic compresses badly -- a 10.7x
range of real decay arrives as a 2.3x range of ring figure -- so any single
multiplier is wrong nearly everywhere, and the one read off two takes at 0.44 s
only ever fitted rooms near 0.44 s. A power law fits the whole span to within
27 %:

```
T60 = 67.2 * ring^2.86
```

Two things that measurement established, neither of which was known before:
the relationship **does not move with the wet/dry mix** (swept at 0.15, 0.35
and 0.70 the readings differ by at most one histogram bucket, so no
direct-to-reverberant term is needed), and it **does not move with the source**
(noise bursts and a 12-harmonic stack return the same figure). With no
reverberation at all every band reports 0.041 s -- the burst's own release seen
through the 64 ms ring window -- and that floor does not move, so a dry take is
recognisable as dry.

### Measuring T60 instead of calibrating a proxy

The law above calibrates a *proxy*, and the proxy saturates. The **decay cube**
measures T60 directly: in every pause, each band's level is followed down from
where the voice stopped, a line is fitted between -3 and -18 dB, and `-60/slope`
goes into a per-band histogram. Conditioning on *the voice having stopped* is
the whole point -- it is the one condition that takes the singer out of a
statistic the singer would otherwise dominate.

Against the same combs of known decay:

| known T60 | 0.15 | 0.30 | 0.55 | 0.90 | 1.10 | 1.60 |
| --- | --- | --- | --- | --- | --- | --- |
| ring law | 0.12 | 0.38 | 0.69 | 0.84 | 1.02 | 1.25 |
| decay cube | 0.15 | 0.29 | 0.50 | 0.80 | 0.92 | 1.30 |

Worst error 27 % against 19 %, and the decay cube is never more than 10 % high
-- biased the safe way, and asserted to stay there. On the reference takes it
returns **0.46 s and 0.40 s** against the ~0.44 s an independent estimator
gives; the ring law puts the second at 0.21 s.

It keeps the cube discipline: a histogram per band, not envelopes, so the cost
is independent of file length, and the **population** is kept rather than an
average -- one pause that held a breath or a chair produces one wrong fit, and
a median absorbs it where a mean carries it.

What it cannot do is work without pauses. Each fit needs a pause of at least
120 ms in which the band falls 8 dB; below `edc_min_gaps` fits the band
refuses, and if too few bands report, **the ring law is the fallback**. That is
the only reason both estimators are kept. On dry material it refuses outright,
where the ring law reports its floor.

**Set T60 and reduction from the analysis** prefers the decay cube and falls
back to the law. It is on by default. The ring law goes through a deliberate 0.85 safety factor, because the error is
asymmetric: too low only means the dereverb does less, too high means it
subtracts the singer's own sustain. The decay cube gets no such factor -- the
0.85 exists to absorb the law's +27 % residual, and a direct measurement that is
never more than 10 % high has no bias left to absorb. Cross-check -- the law puts
`Room resonance example.wav` at 0.46 s, against the 0.44 s an independently
calibrated estimator gives, and 0.39 s once biased, which is where the hand-set
default of 0.40 s had already landed by ear. **The auto mode reproduces the
by-ear answer on the take it was tuned on and moves off it on other material,
which is the whole point.**

Because the law is monotone, applying it band by band gives exactly the same
median it gives the median -- so under auto the per-band T60 comes from each
band's own ring figure, which gets the spread right instead of understating it
by the 2.86th power the way a linear tilt on a hand-set level does.

Reduction has no ground truth the way T60 does -- it is a limit on how far any
bin may be pulled down, which is a taste boundary -- so it is a gentle function
of the estimated decay, clamped to 6-18 dB. Its job is only to stop a dry take
being offered 18 dB it can spend on nothing but artifacts.

Unticking the box hands back whatever was last set by hand: the estimate is
never written into those keys. **T60 scale stays live either way** -- the
analysis sets the level and the ear trims it, which is also what stops the two
controls being the same knob twice.

The panel refuses to estimate at all when the level statistic is pinned on
edited-in silence (the ring gate is derived from the same floors) or when
fewer than four bands produced a ring figure, and says which.

Late reverberation is modelled as a decayed copy of what each bin held a few
frames ago -- `lambda(n,k) = strength * |X(n-D,k)|^2 * 10^(-6*tau/T60)` -- and
subtracted with the same Berouti/Wiener chain DeNoise uses. The point of this
model over an expander keyed to note ends is that it works **under the singing
too**, not only in the exposed gaps: reverb is present during notes, just
masked, and a tool that only touches tails makes the timbre inconsistent.

T60 varies with frequency. Under auto that comes straight out of the law,
applied to each band's own ring figure. With the box unticked it is the older
arrangement, which is all that is available when the level is a guess: the
*shape* from the ratio of each band's ring time to the median, the *level* from
the T60 control.

### What it cannot do: continuous singing

The chain has a blind spot, and it is provable from the model rather than
merely observed. The gain is driven by `snr = 10*log10(P(n) / lam)`, and for
STATIONARY material `P(n) ~= P(n-D)`, so

```
snr = -10*log10(decay) = 60 * tau / T60      (the reverb level is not in it)
```

At T60 0.5 s and tau 128 ms that is 15.4 dB, alpha 1.56, and a gain of
**-0.40 dB however reverberant the room is.** The stage can only respond to
*changes* in level -- note ends, gaps, consonants -- so under a held note it
does essentially nothing.

`test/sustained_in_reaper.lua` pins both ends of that down on one fixture: with
gaps in the material it takes 9.2 dB of tail off, and on a sung phrase with no
gaps it moves the level by 0.40 dB -- the figure the algebra predicts, to two
decimal places, with no audio involved.

So if a take sounds untouched, check whether it ever stops. **This is the
limitation to know about before reaching for the controls**, because no setting
of T60, reduction or strength changes it.

**Lookback is the parameter that decides whether any of this works.** The late
estimate is the same bin `delay_frames` ago, so that lookback must be
comfortably LONGER than the analysis window -- otherwise the two frames overlap
and the signal is being subtracted from a near-copy of itself, which attenuates
everything and removes no reverb at all. Measured on a fixture with known T60:

| lookback | tail removed | voice lost |
| --- | --- | --- |
| 21 ms (window is 43 ms) | 0.1 dB | -7.6 dB |
| 128 ms | 5.0 dB | -0.3 dB |

The default is 12 frames (128 ms) and the panel turns red if it is set below
the window. This shipped wrong once: the symptom is "it thins the signal out
and leaves the reverb alone", and no test caught it because the suite only
checked that the stage was transparent at 0 dB reduction and that its latency
was exact -- neither of which asks whether it removes reverb.

### Gating the tail

The limitation above is the reason this exists. The spectral stage works under
the singing and is weakest in the exposed pause; a gate can only act where the
level *falls*, so it does nothing under a held note and is at its best exactly
where the other one gives up. Neither replaces the other, and the measurement
below says so out loud: on the reverberant fixture the dereverb alone takes the
exposed tail from -36.2 to -43.0 dB, the gate alone to -46.5 dB, and the two
together to **-54.4 dB**, for 0.5 dB off the voice.

#### Two domains, one law

The same thresholds, ranges and releases drive either of two machines, and
**filter** switches between them. They do the same job and fail differently.

| | **spectral** (default) | **filterbank** |
| --- | --- | --- |
| how | band gains inside the dereverb's STFT, `g_total = g_dereverb * g_gate` | Linkwitz-Riley 4th-order tree in the time domain, after it |
| latency | one window | none |
| decision grain | ~43 ms | one sample |
| phase | untouched | allpass, whether or not it is gating |
| residual render | stays a clean diagnostic | **no longer a clean null** |
| crossover regions | none to have | move when neighbouring bands gate differently |
| onsets | cannot clip one; leaks a little room in just before each | exact, no pre-echo |

Spectral is the default because of the third and fourth rows. Listening for
voice in the residual is the main way to tell whether a correction is taking
the right thing, and an allpass tree leaves signal-minus-a-phase-rotated-copy
in it even while the gate does nothing; and adjacent bands moving differently
is the *normal* operating condition for a multiband gate, which is exactly when
a crossover network's summation stops being flat. Neither costs anything in
latency here, because the render is offline and compensated exactly.

Pick filterbank when the material has hard exposed entries -- the spectral
path's one-window pre-echo is the artifact to listen for there -- or when you
want the familiar, predictable behaviour of the classic build.

The tree is serial: split, keep the low half, split the high half again. Every
band already extracted is then passed through the **allpass** of each later
split, without which the bank sums with ripple at every crossover rather than
flat. With it the whole bank sums to `AP1*AP2*...*AP7`, which is unity
magnitude everywhere -- asserted directly, both on the designed coefficients
and on the rendered audio.

Its detector carries a **4.77 dB offset**, and that is not a fudge: the
analysis reports a band as a power sum normalised by `N^2/8`, the single-bin
coherent-gain constant, and a time-domain mean square is not the same number.
Parseval puts broadband content `10*log10(0.375/0.125)` above it -- the same
constant the README warns about in the other direction above. Without the
offset every suggested threshold would sit 4.8 dB too high for the filterbank.
Even with it the two read the same level only *on average*: measured band by
band on the same noise, the mean difference is 0.07 dB but individual bands run
to 2.5 dB apart, because LR4's -6 dB crossovers and the spectral bank's
raised-cosine edges divide broadband energy differently. A given threshold
therefore means slightly different things in the two modes, well inside what
the offset control covers. The two also differ by `10*log10(1.5)` = 1.76 dB on a pure tone,
because a Hann main lobe sums to one and a half times its peak bin; a reverb
tail is broadband, which is the case worth matching, and the selftest drives
both with the same noise and asserts they agree.

Eight bands, crossing at 90 / 180 / 360 / 720 / 1400 / 2800 Hz and 5600 Hz. The
detector keys off the **input** band power, before the dereverb's gain, so the
thresholds are in the units the analysis measured and do not move when the
dereverb controls do. Band levels are pooled across channels in both domains,
which is why `dere_frame` is split into an analyse pass and a synth pass and
why the filterbank runs between two channel loops rather than inside one:
gating the two channels from their own levels lets the image wander in the
pauses.

The filterbank also needs an **attack**, where the spectral path opens
instantly. There is no window to smooth a gain step at sample rate, so a step
is a click. Its attack and its detector are both floored at a few cycles of the
band -- a one-pole shorter than the period it is watching tracks the waveform
rather than its envelope, and the band buzzes.

**Amount scales depth only**, and the threshold offset is a separate control.
Turning amount up gates harder and never sooner, so it cannot start taking the
voice; the offset is the one knob that moves all eight thresholds at once. No
band is pulled below its own measured noise floor -- a pause gated to silence
sounds like the recording stopping, where stopping at the floor sounds like the
room.

#### What the thresholds are set from

A new cube, filled in the pass that was already running: each band's level
distribution **restricted to frames where the voice had stopped**, using the
decay cube's own `quiet` flag. It costs one histogram per band and no second
read of the audio.

What it is *not* is the threshold. That was the first thing tried and it
produced a gate that measured a **0.0 dB change**, for a reason worth keeping
written down: `quiet` fires only once the take's running level has fallen
`edc_gate_db` below its own average, and on the fixture that is 200 ms into
every gap. The loudest frame the cube could hold was -33.6 dB while the tail
entering the gap was -22 dB, so a threshold at the very top of that
distribution still sat 11 dB under the tail it was meant to catch.

So the threshold is set from the band's own **working level** -- 12 dB under
it, the same figure `edc_gate_db` uses to mean "the voice has stopped" -- and
clamped to stay clear of both the noise floor and the voice. Like
`reduction_from_t60` that 12 dB is a taste boundary; what is measured is where
the working level is per band, whether the take pauses at all, and how far down
each band may be taken. The pause cube earns its place on the other three:
it is what **refuses** a band whose pauses do not separate from its voice by at
least 8 dB, what refuses a take with too few pause frames to make a
distribution, and what bounds the depth.

Release comes from each band's own measured T60, at T60/4 -- slower than that
and the gate merely follows the room down and removes nothing. Opening is
instant, and the 43 ms window means the stage **cannot clip a syllable onset**:
it opens slightly early, which is the safe direction.

#### What is not measured, and is refused rather than guessed

The ring pass reads at `pitch_rate` over `search_lo_hz..search_hi_hz`, so
**nothing above about 1.9 kHz has a pause level at all**, and nothing above
4 kHz can at that rate. The top two bands are handed back to the ear instead of
carrying a number extrapolated from below. That is deliberate: sibilance and
breath live up there, and gating those is the loudest way to spoil a vocal.
Air absorption also shortens a room's own decay in that region, so it is the
part of the range that needs a gate least.

### Output

**Render and apply** writes a 32-bit float WAV beside the project media and
hangs it on a new take, so A/B is a take switch and the original is
recoverable. At zero filters with dereverb off the render is a bit-exact null,
which is what makes the pipeline test an assertion rather than a tolerance.

**Render the residual** writes what was *removed* instead of what was kept: the
dry signal, delayed to match the chain, minus the output. It is the fastest way
to find out whether a correction is taking the right thing -- listen for voice
in it, because that is what you are losing. `kept + residual` reconstructs the
input exactly, and with both stages off the residual is digital silence, which
is how the dry path proves it is aligned. Get that delay wrong and the residual
is the input combed with itself, which is *louder* than the input rather than
quieter -- so the failure is loud rather than subtle.

## Notes on the design

**The cubes are the architecture.** One pass over the audio reduces the whole
file to two compact summaries that live in the EEL heap, and every control
re-derives its answer from those in well under a millisecond. That is why the
detection sliders are live while the analysis ones sit behind a header, and it
is expressed once, as parameter classes in `dr/config.lua`, rather than as
scattered dirty flags.

**Reading low is better than reading fast.** The modal pass reads at 4 kHz and
uses a 2048-point FFT: 1.95 Hz spacing over a 512 ms window. That is *finer*
than a 16384-point FFT at 48 kHz and eight times cheaper, and REAPER's accessor
does the anti-aliased decimation for free.

**A single bin normalises by `N^2/8`, not by the Parseval constant.** Coherent
gain squared over two. Using the broadband `0.375` on one bin reads 4.77 dB low
-- exactly `10*log10(3)` -- and is silently wrong everywhere. Both constants are
asserted separately.

**Ring times are stored as a histogram, not as envelopes.** Keeping every
band's envelope costs O(bands x frames) and runs to tens of megabytes on a long
take; a histogram of `-60/slope` costs the same whatever the file length. The
slopes are additionally binned by the level they start from, so the noise-floor
gate can be applied afterwards without a second pass over the audio.

**The ring test does not gate, and that was a discovery, not a choice.** See
Known limits.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_DeResonate.lua` | entry: resolve own directory, check ReaImGui, hand off |
| `dr/config.lua` | defaults, ExtState, parameter classes, derived geometry |
| `dr/select.lua` | resolve the selection into clips |
| `dr/analyze.lua` | the accessor edge; four passes, yield-a-read-request |
| `dr/kernel.lua` | the only file that knows an address |
| `dr/dsp/deresonate.eel` | FFT, the modal cube, the ring cube, the decay cube |
| `dr/pitch_kernel.lua`, `dr/dsp/pitch.eel` | YIN, copied from NoteLeveling |
| `dr/spectrum.lua` | cube -> percentiles and the two smoothing scales |
| `dr/mask.lua` | harmonic occupancy over frequency |
| `dr/ring.lua` | ring time and the ring index |
| `dr/broad.lua` | broad humps, attributed direct vs room |
| `dr/detect.lua` | narrow candidates and the tests they must pass |
| `dr/solve.lua` | filter design and the gain bisection |
| `dr/auto.lua` | the calibrated ring -> T60 law, and what auto mode sets |
| `dr/edc.lua` | T60 read out of the decay cube |
| `dr/gains.lua` | the dereverb gain chain, in Lua |
| `dr/gate.lua` | the gate's law, its band fold, and what the analysis suggests |
| `dr/render.lua` | second pass -> WAV, latency compensated |
| `dr/wav.lua` | 32-bit float WAV sink, copied from AutoTilt |
| `dr/apply.lua` | the only file that touches the project |
| `dr/ui.lua` | the panel |
| `test/fixture.lua` | runs a suite against a throwaway track, and restores the project |

Everything from `spectrum.lua` down imports no `reaper` and is unit-testable.

## Tests

```bash
python3 tools/run_tests.py        # REAPER must already be running
python3 tools/run_panel_test.py   # the panel, against real ReaImGui
```

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `test/headless.lua` | every pure stage; the parameter-class split; panel frames against a stub -- quiet and with every control moved, across the gate's engaged, gate-mode and refused branches; a scan asserting each control names a real config key, computed ones included. The stub VALIDATES the arguments it is handed where ReaImGui is strict about them: a Combo item list that is not NUL-terminated raises here rather than only in the GUI, where it unbalances the disabled stack and the panel dies with no usable message | anything in the EEL, the accessor, or how the panel actually looks |
| `test/selftest_in_reaper.lua` | the compiled kernel on synthetic signals: heap probe, the -3.0103 dBFS single-bin figure, the band map, ring times recovered from known decays; the render chain -- a bit-exact null with nothing engaged, a -12 dB Q=20 cut measured at its own frequency and an octave away, latency exactly one FFT with +-1 rejected; suppression off as a bit-exact pass-through; and the residual, which must be digital silence with nothing engaged and must satisfy `kept + residual == input` | whether the rules are the right rules -- it drives the kernel the way the kernel expects |
| `test/gate_in_reaper.lua` | **whether the gate cuts the tail, in both domains.** The dereverb suite's fixture, driven through the whole auto path -- the analysis passes run, `Gate.suggest` sets the thresholds, the render uses them. For spectral AND filterbank, asserts at the SHIPPED DEFAULT that the exposed tail falls at least 4 dB while the bursts move less than 0.5 dB, that gate and dereverb together beat the gate alone, that amount 0 is transparent, and that on dry material the suggestion is refused and the stage stays inert | one room, one T60, synthetic bursts; it cannot say it sounds good |
| `test/t60_calib_in_reaper.lua` | **the calibration the auto mode rests on.** Combs of known T60 swept 0.15-1.6 s through the real ring and decay passes, at two wet mixes and two source spectra. Fits the ring power law and asserts it is monotone and within 35 %; asserts the decay cube lands within 25 % of the known T60, is never more than 10 % high, spans the range instead of compressing it, refuses the dry cases, and agrees with the independent ~0.44 s on both reference takes | one reverberator, spectrally flat, and a synthetic source; it says nothing about how the per-band *shape* behaves when a real room is not flat |
| `test/sustained_in_reaper.lua` | **the limit the burst fixture cannot show.** The same reverberator driving bursts with gaps and a sung phrase with none: asserts the stage takes tail off the first and moves the second by less than 0.5 dB, and that the gain rule lands there from the model alone | it characterises a limit; it does not fix one |
| `test/dereverb_in_reaper.lua` | **whether the dereverb removes reverb.** A dry signal with silent gaps plus reverb of known T60; measures gap energy against burst energy, and asserts at the SHIPPED DEFAULT that more tail comes off than voice | one room, one T60, one signal; it cannot say it sounds good |
| `test/verify_edit_in_reaper.lua` | the whole pipeline: renders, applies, and nulls the new take against the source at <= -80 dB at shift 0 with +-1 clearly worse, on fixtures at playrate 1.00 **and** 1.25. Runs entirely inside a throwaway project tab and asserts the user's project is untouched afterwards | whether the correction sounds right; it verifies transport, not taste |
| `test/inject_in_reaper.lua` | **the positive control.** Real vocal audio through a resonator of known frequency, Q and ring time; asserts the detector recovers it | only one resonance, in one take, at one Q |
| `test/silence_in_reaper.lua` | **that the level statistic survives edited-in silence.** The same take analysed at two item lengths — the longer one running out into digital silence for 40 % of its span — must give the same p20 curve across the search range, the same candidates and no newly-pinned ring band; and with the guard off it must collapse, so the assertion is known to be testing something | one kind of silence (digital), appended rather than interleaved |
| `test/analyse_real_in_reaper.lua` | both reference takes end to end, printing what every detector says | it asserts nothing; it is for reading |
| `test/panel_in_reaper.lua` | the panel against the real ReaImGui, stacks balanced over eight frames | whether it looks right |

Synthetic fixtures prove the stages behave as written. They cannot prove the
rules are the right rules, which is what `inject_in_reaper.lua` and
`dereverb_in_reaper.lua` exist for. Each of them found a real failure after
every other suite was green: the first that the ring test could not see a
resonance it was handed, the second that the dereverb removed no reverb at all.
Both failures were of the same shape -- a stage that looked healthy on every
measurement except the one that says whether it does its job.

**The suites never touch your project.** `test/fixture.lua` runs the
writing ones inside a throwaway tab that is closed afterwards, and the verify
suite asserts your track and item counts are unchanged when it finishes. This
departs from the sibling scripts, which edit the selected item; that pattern
destroyed an unsaved session during development, and a test that can eat your
work is not worth having.

## Known limits

- **A file that is mostly silence still cannot be analysed.** The guard above
  refuses to step over more than half a bin's frames, so a take that is 60 %
  stripped pauses keeps a pinned curve. That is deliberate — the alternative is
  a percentile resting on a handful of frames — but it means the answer is
  "cannot measure this", and the panel says so rather than reporting no
  resonances. Trim the silence, or analyse a busier section.
- The reference takes ship with 0.4–4.3 % of their frames at the bottom of the
  level axis, five times under where this bites, so **no test in the repo could
  reach it** until `test/silence_in_reaper.lua` built the case deliberately.
- Independently of any of that, 8 of 10 ring bands report a floor of −140 dB on
  both reference takes — bands the signal does not reach. Worth a look; it is
  not caused by silence in the file.

- **The ring index is reported but does not gate a candidate.** It was a gate
  until the injection test showed it could not detect a resonance added to a
  real take at 420 Hz with T60 0.30 s: index 1.07 against a 1.25 threshold, and
  no percentile of the distribution separated the injected band from its
  neighbours. The cause is the time-frequency trade-off rather than the tuning
  -- T60 0.30 s *means* a 7.3 Hz bandwidth, resolving 7.3 Hz needs about 137 ms
  of window or filter memory, and that is already half the decay being measured;
  a 7 Hz bandpass rings for 0.31 s in its own right. A gate that cannot pass a
  known true positive is worse than no gate. The evidence that remains
  unexploited is the *late* tail, where the dry signal is gone and only the
  resonance is still sounding.
- **Without that test, narrow detection rests on prominence, Q and occupancy.**
  A loud narrow peak with low occupancy will be accepted whether or not it
  rings. Look at the spectrum plot before cutting.
- **Discrete room modes only exist below the Schroeder frequency**,
  about `2000*sqrt(T60/V)` -- roughly 240 Hz for a 30 m^3 room at T60 0.44 s.
  Above it modes overlap into a diffuse field, so a narrow peak found higher up
  is labelled a reflection, never a mode.
- **On a low male voice the fundamental sits inside the modal region**, and a
  resonance excited only when a harmonic sweeps through it is removed from the
  conditional statistic by the very mask that protects the singer. Occupancy
  can say "not proven"; it cannot say "not there".
- **The band ring figure is not a T60** and must not be read as one -- see
  Reverb above for the law that relates them. That law is calibrated against
  **one reverberator**: parallel feedback combs, spectrally flat, driven by a
  synthetic source. It is good to 27 % over 0.15-1.6 s against that fixture and
  lands within 5 % of an independent estimate on one real take, which is two
  kinds of evidence and not the same as a survey of real rooms. Blind T60
  estimation from running close-mic vocal is good to roughly +-25% below 0.6 s
  and increasingly understates above it, because a close mic keeps the
  measurable part of every decay direct-sound dominated.
- **Auto mode calibrates the LEVEL of T60, not its shape across frequency.**
  Every sweep gave all bands the same true decay, so nothing measured says
  whether a band that reads long really *is* long. The decay cube does produce
  a figure per band, but each rests on a handful of pauses, so the **level**
  comes from its median and the **shape** is still the ring times' own tilt.
- **The gate cannot shorten the first ~150 ms of a tail**, and that is where
  most of a tail's energy is. Measured on the fixture: of the gap energy from
  80 ms after a note ends, the two frames either side of that mark carry about
  two thirds of it, and a gate that acted there would be eating note releases
  instead. So the whole-gap figure barely moves (-17.6 to -18.1 dB) while the
  *exposed* tail from 250 ms on falls 10.3 dB. Read the second number: the
  first one is not what a gate is for. If the first 150 ms is the problem, that
  is the dereverb's half of the job.
- **In filterbank mode the residual render stops being a clean null.** A
  Linkwitz-Riley tree rotates phase whether or not the gate is doing anything,
  so the residual contains signal-minus-a-phase-rotated-copy and listening for
  voice in it no longer tells you much. Switch to spectral to use that
  diagnostic, then switch back if you prefer what the filterbank does.
- **The filterbank disperses energy in time even at unity gain.** It is
  magnitude-flat -- asserted at seventeen frequencies on rendered audio -- but
  an allpass network is not time-flat, and a decaying tail comes out slightly
  flattened. Measured on the fixture: with the gate engaged but its depth at
  zero, every gap window reads about 0.4 dB hotter while the bursts do not move
  at all. It is inaudible as a level, but it means the honest reference for
  what the gate did in this mode is the same chain at amount 0, not the
  untouched file -- which is how `test/gate_in_reaper.lua` measures both
  domains.
- **A filterbank's crossover regions move when adjacent bands gate
  differently**, which is the normal operating condition for this. The bank is
  asserted flat at unity gain, and that assertion says nothing about what the
  response looks like with band 3 down 18 dB and band 4 open. It is the
  familiar hollowness of multiband dynamics, and it is the reason spectral is
  the default.
- **Gating in the frequency domain has a pre-echo**, because a frequency-
  dependent gain is a circular convolution and the frame straddling an onset
  spreads across its whole length. Measured on a fixture whose gaps are exact
  digital silence, the gate puts energy at -74 dB relative to the programme
  into the one window before each onset, and *exactly zero* elsewhere. It is
  the same property that makes the stage unable to clip an onset, so it is a
  trade rather than a defect -- but on material with hard, exposed entries it
  is the artifact to listen for.
- **Nothing above about 1.9 kHz is measured**, so the top two gate bands come
  back refused rather than extrapolated, and stay at whatever is set by hand.
  See *Gating the tail* for why extrapolating there would be the wrong kind of
  helpful.
- **The gate shares the dereverb's STFT**, so switching it on costs one window
  of latency even with the dereverb off. That is compensated exactly in the
  render and is invisible in the output; it is worth knowing only because
  `Config.latency` is now a function of two settings rather than one.
- **The dereverb does essentially nothing on continuous singing.** Measured
  0.40 dB on a sung phrase with no gaps, which is exactly what the gain rule
  predicts for stationary input -- see *What it cannot do* above. It is a
  property of the model, not a tuning problem: the material it works on is
  material that stops.
- **A coherent-cancellation stage was built for this and removed again.** A
  per-bin prediction filter fitted from the take and subtracted complex (WPE)
  is the textbook answer to the blind spot above, and on reverb that is exactly
  time-invariant by construction it works -- 3.8 dB of tail at 40 taps. On a
  real very live take it made the tail-to-speech ratio **worse**: -0.4 dB at
  the geometry the panel shipped and -2.5 dB at the tuned one, against +1.6 dB
  for the spectral chain. It was attenuating voice slightly more than room. The
  measurement that had made it look good was spectral distance from a reference
  de-reverb during speech, which tracks tilt rather than reverberation and
  should never have been promoted to a quality claim. Removed rather than kept
  behind a flag, because a mode that makes the thing worse does not earn a
  place in the panel.
- **On a very live room the dereverb is limited by its model, not its T60.**
  Measured against a take with roughly 0.5 s of decay and a commercial
  machine-learning de-reverb as the reference, on tail level 100-250 ms after a
  speech offset: the reference removes 6.0 dB, this removes 1.0 dB, up from
  0.4 dB before the decay cube. Pushing the settings harder does not close the
  gap -- past about 2.5 dB it stops removing room and starts removing the
  voice's own low end. The late estimate is a decayed copy of *everything* a
  moment ago, and during continuous speech that is mostly direct voice, so the
  statistic has little power to tell tail from speech. A better T60 makes the
  model do its job properly; it does not make it a different model.
- **Auto reduction is not a measurement.** T60 has ground truth and this does
  not: it is a monotone function of the estimated decay, clamped at both ends,
  and its only real job is to keep a dry take away from the top of the range.
  If a take wants more or less, untick the box.
- **A narrow cut reduces a resonance's steady level, not its ringing.** The
  room still decays at the same rate; only its amplitude drops. The dereverb is
  what addresses the ringing.
- **The dereverb is the uncertain half.** Everything above it is a measurement
  with a stated error bar; this is a statistical estimate and will produce
  artifacts at aggressive settings, as any dereverb does. Start at low
  reduction and raise it until you hear it working, then back off.
- An end-to-end null through a rendered file lands at **-80 dB or better and
  cannot do better in principle**: the output is 32-bit float, so every sample
  is rounded to 2^-24, and on a stretched take the resampler's output depends
  on where you seek into it.
- Operates on the first selected item with an audio take. MIDI takes are
  skipped.
