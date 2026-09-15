# Adaptive De-Click (ReaScript)

Finds and repairs **mouth noise** in vocal takes — lip smacks, tongue clicks,
saliva crackle — and derives its own sensitivity threshold from each file
instead of making you dial one in.

The detection and repair are a port of the
[DeClicker JSFX](../../jsfx/DeClicker), which is itself a faithful port of Paul
Licameli's Audacity/Nyquist **De-Clicker**. What is different here is the one
thing worth being different offline: **the threshold is read off the file's own
click distribution**, and the whole file is visible while you tune it.

## Install

Requires **ReaImGui** (ReaPack). It is used for the panel *and* for the DSP
kernel, via `CreateFunctionFromEEL`.

```bash
ln -sfn "$PWD" ~/.config/REAPER/Scripts/DeClick
```

Then add `Magnolius_DeClick.lua` in Actions → Show action list → New action → Load
ReaScript.

## Use

Select one audio item, run the action, press **Analyse**. Then work down the
panel:

1. **Threshold** — the histogram is the distribution of every candidate click's
   *overshoot*: how far it stood above its own local background. Musical
   transients taper smoothly; clicks sit past where the taper ends. The green
   line is where the threshold landed, and the orange and blue ones are the two
   estimators that put it there.
2. **Detections** — the waveform with a mark at every click, thin yellow at the
   threshold and thickening to red at +30 dB over. Click anywhere to move the
   edit cursor there.
3. **Detection band** — which of the analysed bands detection listens to, over
   a per-band tally of where it is firing, each band labelled with its centre
   frequency and the inactive ones dimmed. This is **live**: the band layout is
   fixed when you analyse, but selecting among those bands costs nothing, so it
   is a control you drag rather than a setting you commit to.
4. **Repair** — the crossfade, the cut-depth clamp, and the budget that stops a
   bad threshold eating the take.
5. **Render**, or **Dry run** to mark without writing audio.

**Isolate changes** renders what is being *removed* instead. It is the fastest
way to hear whether the settings are eating signal: anything you can recognise
as speech in the isolate render is something you are losing.

**Dry run + take markers** is the intended tuning workflow. Run it, look at
where it wants to cut, listen at those markers, move **Sensitivity offset**,
repeat. The CSV log is how a bad result gets found afterwards.

### When consonants are being detected as clicks

This is the common complaint, and the useful answer is not the obvious one.

**Frequency is the weaker lever.** Raising the low edge of the detection band
does reject plosives and vowel onsets, which carry real low-mid energy. It does
**not** separate clicks from sibilance, because an /s/ lives in the same 2–9 kHz
region a smack does. Measured over a 104 s vocal take, moving the low edge from
150 Hz to 4 kHz took detections from 423 to 263; on a second take it barely
moved them at all.

**Duration is the strong lever.** A mouth click is over in a few milliseconds;
a fricative runs 100–250 ms. `Min time between clicks` (`sep`) sets how long a
quiet zone the detector demands on *both* sides of a candidate — `sep + sep/3`
steps, so 20 ms at the default and 65 ms at 10. A sustained consonant cannot
produce that. On the same take, raising `sep` from 3 to 10 took detections from
423 to 192 with the derived threshold barely moving, which is what a clean
rejection looks like: the population thins but the distribution keeps its shape.

So **reach for `sep` first, then the band**, and use `Dry run` with the take
markers to check what actually went at each step.

### When an audible click is not being detected

The mirror image, and the answer is the other end of the band. **The top of the
analysed span is where the contrast is.** A mouth click's energy peaks well
above a voice's, and a voice falls away fastest exactly where the click does
not, so the higher you look the better the click stands out.

Measured on a real take, on a click that was plainly audible and came through
as 6.5 dB against a 8.4 dB derived threshold — a miss:

| band | click | local background | contrast |
| --- | --- | --- | --- |
| 300–600 Hz | −35.2 | −28.8 | **−6.3** |
| 2400–4800 Hz | −68.9 | −57.2 | **−11.7** |
| 6800–9600 Hz | −51.7 | −63.2 | +11.6 |
| 9600–13000 Hz | −51.8 | −70.9 | **+19.0** |
| 13000–17000 Hz | −66.2 | −82.7 | +16.5 |

Below 4.8 kHz the click is *quieter* than the voice it is sitting on. All of its
contrast is between 6.8 and 17 kHz, and the old `fhi` of 9600 put the two
strongest bands outside the analysis entirely. The one band that could see it
spans 6.8–9.6 kHz, and the detection bandpass is **double width**, so its skirt
reached down into the region where the voice masks the click completely —
which is how +11.6 dB of real contrast arrived at the threshold as 6.5 dB, in a
single band, with no other band agreeing.

Widening to 16 bands over 150 Hz–20 kHz took that click to **12.0 dB** against
an 8.9 dB threshold, while the file's total detections went 35 → 49. The
alternative — dropping the threshold 2 dB to reach it — went to 67, and on a
second take 217 → 302 against 268 for the wider band. So the width buys the
same click at roughly half the collateral, and buys it with margin rather than
by a hair.

Two things this does not fix. It needs the material to actually have content up
there: a take that has been through a codec, or off a lavalier with an HF
rolloff, will show empty top bands in the per-band tally and nothing will change.
And `fhi` of 20 kHz is under `0.47 * srate` only from 44.1 kHz up — below that
the kernel clamps the top band centres and they stop being distinct bands.

**So: `sep` for consonants coming in, the top of the band for clicks staying
out.** They are independent levers and neither substitutes for the other.

### Max event length, and what it could not be shown to do

`Max event length` caps how long an event may last and still count as a click,
measured in the band that carried it. It exists because a click and a fricative
have the *same onset* and differ in whether the sound is still going 150 ms
later — an axis neither `max_steps` (which caps the width of the click) nor
`sep` (which asks for quiet within ±(sep + sep/3) steps, ±20 ms at the default)
can see. Raising `sep` does not substitute: on a real take, 3 → 6 did not thin
the long population at all, and at 8 the candidate set collapsed to a single
detection.

Two things went wrong on the way to it, and both are worth keeping written down.

**Measuring against the candidate's own peak does not work.** The first version
walked outward while the band stayed within 12 dB of the peak. For an event
whose overshoot is *under* 12 dB there is no 12 dB drop to find, so the walk
never terminates and every marginal event measures as sustained — exactly
backwards, since the events near the threshold are the ones a length test most
needs to judge fairly. A 3 ms 200 Hz burst standing 6.95 dB over its background
measured as **605 ms**. The test now takes the higher of the peak-relative
floor and one referenced to the band's mean level over ±200 ms; the same burst
measures 10 ms.

**And then it stopped doing anything.** With the floor fixed, a 25 ms cap
removes 0–2 detections out of 49 and 268 on the two test takes: with a fair
floor, almost nothing on real vocal material measures as sustained. Replacing
the contiguous run with an occupancy count over ±200 ms *did* fire, but removed
events over 18 dB at the same rate as everything else — selectivity 1.0–1.1×,
which is a filter that is not distinguishing anything, only thinning.

The frequency axis is the one that works, but only when it is measured on the
right thing — see below. Measured the obvious way it looks just as dead: cutting
on the *trigger band* (≥ 4 kHz) removed 36% of detections and 33% of the ones
over 18 dB, 1.1×. That is because absolute band level is dominated by the voice
underneath, which is the same for a click and a consonant.

So `max_event_ms` ships **off**, and the honest statement is that the mechanism
is proven (`selftest_in_reaper` builds a signal that needs it: the same 3 ms
burst is kept in isolation and rejected inside a 150 ms plateau of the same
tone) while its usefulness on any given take is not. Dry run with take markers
is how to find out.

### Reach: the spectrum of the residual, not of the signal

This is the one that separates them, and the reason it took a wrong turn first
is worth stating: **the discriminating spectrum is the residual's, not the
signal's.** Look at an isolate render of the two side by side and the
difference is not subtle — a plosive is a single low-frequency spike whose
energy dies out well before the top of the spectrogram, while a mouth click is
a step discontinuity: flat, and still plainly there at 17 kHz. But in the
*signal*, both sit on the same voice, and the voice dominates every absolute
band level. Measure levels and the two read the same. Measure each band against
its own local background and the voice divides out.

`Residual must reach (Hz)` (`min_reach_hz`) requires at least one band at or
above that frequency to stand 6 dB over its own background — deliberately above
the per-band detection bar, because the question is not "did this band take
part" but "is what we would remove still present up here".

Measured over both takes, the highest frequency at which the residual still
clears 6 dB is sharply bimodal:

| residual reaches | share of detections |
| --- | --- |
| below 1.5 kHz | 31% |
| 1.5–6 kHz | 6% |
| above 10 kHz | 49% |

The default of 3000 Hz sits in that empty valley. On the take it was tuned
against it drops 16 of 49 detections and loses none of the strong ones.

The split is confirmed by a measurement that shares nothing with it: the width
of the high-passed transient, taken from the raw audio rather than the band
envelopes. Events whose residual stops below 1.5 kHz have a median width of
**3.5 ms** (p90 21); the ones that reach past 6 kHz, **1.5 ms** (p90 8). Two
independent measurements finding the same two populations, and matching what
the isolate render shows — the low ones are also the long ones.

Note what this does *not* say. `min_reach_hz` is not `det_hi_hz`: the reach
scan reads every band, including ones detection is not listening to, because a
band can testify that a residual exists up there without being a band you want
to cut. And a reach above the analysed span clamps to the top band rather than
qualifying nothing — which would reject every event and be indistinguishable
in the panel from a clean file.

**A filter over the population is not part of the population.** The reach and
event-length tests are applied at commit and deliberately *not* during the
survey, and getting this wrong is subtle enough to be worth the warning. The
threshold is read off the shape of the candidate distribution: the taper is the
transient population, and the gap is where that population ends. The reach test
exists to remove exactly that population by a different axis — so surveying
with it on empties the histogram of the very thing the estimators fit. Measured
on a real take at 3 kHz, the survey fell from **9308 candidates to 86**, both
estimators reported no gap, and the 98th-percentile fallback landed at
**18.9 dB** and committed nothing. The panel said "no gap found in the overshoot
distribution", which was true and completely misleading: there was no gap left
because the filter had already done the separating.

So both are excluded from `DETECT_KEYS` for the same reason `sens_db` is — they
are filters *over* the surveyed population rather than part of what defines it,
and moving them must not rebuild the histogram. That also makes them free to
drag. `survey_cfg` in `detect.lua` is where this is enforced, and both
`headless` and `selftest_in_reaper` pin it: the surveyed count must come out
identical with the reach test on and off.

One combination to avoid: `Max click length` of 1 step together with a large
`sep` squeezes the candidate set until the taper has almost nothing left in it,
and the derived threshold can then land on a handful of stray bins — on the
same take it jumped from 7.1 dB to 22.9 and kept four events out of four
hundred. That number is not obviously wrong, which is exactly the danger, so
the panel now says when a threshold is resting on very little.

### How the threshold is found

A click is defined by contrast with its surroundings, not by absolute size, so
a fixed threshold does not transfer between files. But the *shape* of the
disagreement does: analysis runs detection once at a deliberately low floor,
emitting nearly every candidate, and histograms their overshoots. Two
independent estimators then look for the gap:

- **Tail departure** fits the bulk of the distribution (50th–95th percentile)
  in log-count space, extrapolates it outward, and walks up until the empirical
  count stands clear of the fit. That crossover is where clicks take over from
  transients.
- **Knee** takes the count-versus-threshold curve — which is just the reverse
  cumulative histogram, so it is free — and finds where it stops falling and
  shelves.

**The higher of the two wins.** Over-conservative is the correct failure
direction: a missed click is recoverable by ear, a chewed consonant is not.

The knee reliably lands *below* the tail departure, and that is not a bug in
either. The knee fires at the elbow of the drop, where the transient
population's contribution falls to the click cluster's level; the tail
departure fires where the transients actually run out. On a file with a strong
click cluster those are 5–15 dB apart. Disagreement wider than 8 dB is reported
in the panel, because a file with no clean gap is worth knowing about before
you apply anything — it is more informative than any amount of tuning.

If neither estimator finds anything the panel says so and falls back to the
98th percentile. That means the same thing every time: this take has no
separation between its clicks and its consonants, and no analysis invents one.

There is one way to get that message without it being true, and it is worth
recognising: if something has already thinned the candidate population before
the histogram is built, there is no taper left to depart from and no knee to
find. That is why the reach and event-length tests are applied at commit and
not at survey — see "Reach" above.

### Passages that hold no audio

Overshoot is a **ratio** against a candidate's own local background, and that
is the detector's great strength: a click in a loud passage and one in a quiet
passage land in the same place, so the estimators see one population instead of
a smear of level.

It is also a blind spot. A passage holding no audio at all still has a
foreground and a background, and the ratio between them is an ordinary small
number. Strip-silence, a hard noise gate, or the noise-shaped dither a 16-bit
master carries in its pauses therefore fill the survey with candidates that are
not events — they are the dither fluctuating against itself.

They never survive a threshold. Measured on a take with 27 % stripped pauses,
the two overshoot histograms were identical **event for event** above 4 dB, so
nothing is repaired that should not be. But 1908 of 9308 candidates came from
silence, and `tail_departure` anchors its fit on p50..p95 of the distribution,
so they drag those anchors down and the threshold with them:

| silence in the take | derived | same audio, trimmed | drift |
| --- | --- | --- | --- |
| 27 % | 8.88 dB | 9.12 dB | −0.24 dB |
| 67 % | 6.12 dB | 9.12 dB | **−3.00 dB** |
| 80 % | 6.12 dB | 8.12 dB | −2.00 dB |

The drift is towards a *lower* threshold, which is the wrong direction for a
de-clicker: the whole bias of this script is that a missed click is recoverable
by ear and a chewed consonant is not.

So the kernel builds a histogram of the file's own **broadband step-peak
level** during analysis, `dc/silence.lua` reads off it the level below which
there is no recording, and the survey runs a second time with candidates below
it rejected. Both passes are kernel calls over the cached envelopes, not
re-reads of the take, so the second one costs nothing worth mentioning — which
is the envelope cache paying for itself again. With it, all three rows above
land on the trimmed-take answer exactly.

Two details worth recording, because both took a wrong turn first:

- **Not the candidates' own levels.** A candidate's foreground is a *band*
  peak, and the kernel adds a −100 dB guard to those, which compresses every
  silent step into the same few buckets. Measured, the candidate levels from
  dither and from the quietest real material were three buckets apart — too
  close to build a rule on. The broadband step level separates them by twenty.
- **The empty-bucket threshold is absolute, not a share of the file.** A share
  scales with the *silence*, so on a mostly-silent take it grows until the
  material's own sparse mid-range reads as empty and the search walks straight
  through it. At 0.2 % on a 67 %-silent file the floor came out 20 dB too high,
  in the middle of the speech.

The panel says what it ignored and how much of the file that was, and says so
in red when there is too much of it to ignore safely. **Ignore passages that
hold no audio** turns it off, under Advanced.

## Notes on the design

**The envelope cache is the whole architecture.** The expensive part of the
algorithm — sixteen IIR bandpass filters running per sample — produces the
per-band step-peak envelopes, and those are *threshold-independent*. Detection
is a pure function over them. So analysis stores the envelopes and detection
becomes a ~50 ms kernel call that re-runs on every slider move without touching
the audio again. That is what makes the sensitivity control, the histogram and
the marker display live, and it is what makes the budget-retry loop affordable.

It is the same trick `DeNoise script` plays with its level-binned histogram,
for the same reason, and it costs memory: sixteen bands, two grid phases, stereo
and 5 ms steps want about 12 MB per minute of take. The kernel sizes itself from
the item up front and refuses with a specific message rather than discovering
it mid-render.

**Passes became parallel grid phases.** The plugin runs `passes` serially, each
one re-detecting on the previous one's repaired output. Its real benefit is the
**step-grid stagger**, which catches clicks straddling a step boundary — the
serial arrangement is simply how a real-time plugin can get that. Offline the
phases run in parallel from the input and merge into one gain envelope: the
same grid coverage, one pass over the audio instead of N, no compounding cuts
on a single click, and — decisively — analysis stays threshold-independent, so
the panel can stay live. At `nphases = 1` the two arrangements are identical by
construction, which is where the null test runs.

**There is no latency.** The gain envelope for every step is known before
rendering starts, so there is no lookahead and nothing to compensate — unlike
DeNoise, which hand-unwinds a whole FFT. The peaking filters have phase
response but no bulk delay. So the alignment test asserts a null at shift 0
rather than searching for the right offset, and the kernel's own null (no file,
no resampler) is bit-exact.

**What the accessor actually returns.** The take audio accessor's timeline is
**item** time, and the audio it hands back already has the take's playrate,
pitch shift and channel mode applied. Measured on REAPER 7.75:
`GetAudioAccessorEndTime` returns `item_len` at every playrate, and with
`B_PPITCH` off a 440 Hz source comes back at 550 Hz on a playrate of 1.25. It
does **not** apply take volume, item volume or pan.

So the span to read is `item_len`, not `item_len * playrate`, and the rendered
file goes back on a take with **neutral** stretch settings — copying the
original's playrate across would stretch already-stretched audio. Only `D_VOL`
and `D_PAN`, which the render never saw, are carried over. (The same bug was
found and fixed in `DeNoise script` on the way here.)

**The job cannot read its own audio.** REAPER refuses to run
`GetAudioAccessorSamples` from inside a Lua coroutine: the call returns `nil`
and leaves the buffer exactly as it was. It does not error and it does not
return 0, so analysis and render — both coroutines, so the UI survives a long
take — would quietly see a completely silent file. So the job never reads: it
yields a filled-in request and whoever drives the coroutine does the read on
the main thread and resumes. An unserviced request is a hard error rather than
a buffer of zeros.

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

**A changed default reaches nobody.** Settings persist to ExtState with
`persist=true`, and `Config.load` reads every stored key back over the top of
the defaults, so editing a default in `dc/config.lua` changes nothing for any
install that has run once. The only escape was **Reset all settings**, which
also throws away whatever the user had tuned deliberately.

`M.VERSION` had been sitting there unused since the first commit, so it now
carries a migration: `M.MIGRATIONS[v]` lists the keys whose default moved in
version `v`, `M.migrate()` deletes exactly those from ExtState on the first
load that sees an older stamp, and everything else is left alone. The panel
says which keys moved rather than letting the sliders quietly read differently
than they did yesterday. Widening the analysed span to 20 kHz is what forced
the issue and is what `MIGRATIONS[2]` is.

The version stamp lives under its own key outside `cfg`, so `save` cannot
round-trip it as an ordinary setting and `reset` cannot mistake it for a key
the panel added.

### Guards, and the three that were dropped

The repair budget is the one that earns its place: if a pass would cut more
than `repair_budget_pct` of the file's steps, the threshold goes up by a step
and detection re-runs, up to `max_retries`. It is affordable precisely because
re-detection no longer touches audio.

Its default is **10%**, not the 0.3% the original spec named, and the
difference is a unit change rather than a loosening. The spec's figure counts
*samples replaced by interpolation*; this counts *steps carrying any cut*, and
since a cut step is 5 ms of ducked band energy and the crossfade widens every
repair, one click occupies about two steps. The same amount of intervention
measures 20–40× larger here. Measured on real vocal takes, the plugin's own
6 dB default lands at 1.8–8.1% and a derived threshold at 3.9% and 0.8%, so
0.3% tripped the guard on every file and every threshold — a guard that always
fires is not a guard. A threshold collapse still saturates this metric near
100%, which is what it is there to catch.

Two more are kept — the hard cap on click length, which the plugin already had,
and a **clamp on cut depth**, which it did not. The plugin computes
`depth = -20·log10(overshoot)` with no ceiling, so a large overshoot can dig a
hole deep enough to hear.

Three guards from the original spec were deliberately **not** ported:

- an *isolation test* is redundant — `tcboundary` already requires a return to
  background on **both** sides of a candidate, which is a stronger version of
  the same question, and it is exactly what separates a mouth click from a
  consonant onset;
- *dual-detector agreement* is redundant — sixteen bands must already agree
  through the late steepness test;
- *post-repair verification* is aimed at interpolation, which can silently
  fabricate. An EQ cut is bounded by the measured overshoot by construction, so
  "the repair changed nothing" is not a failure mode here.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_DeClick.lua` | entry action |
| `dc/config.lua` | every tunable, plus ExtState persistence |
| `dc/dsp/declick.eel` | the kernel: bands, step peaks, the Nyquist click test, the repair |
| `dc/kernel.lua` | compiles it and owns the memory map; nothing above this knows an address |
| `dc/analyze.lua` | accessor loop → the envelope cache |
| `dc/autothresh.lua` | overshoot histogram → threshold (pure Lua) |
| `dc/detect.lua` | survey, derive, commit, and the budget retry loop |
| `dc/render.lua` | accessor loop → repaired samples → WAV |
| `dc/wav.lua` | 32-bit float WAV writer |
| `dc/apply.lua` | adds the result as a take, places markers (the only file touching the project) |
| `dc/log.lua` | the CSV row |
| `dc/silence.lua` | where the recording stops and the edit begins (pure Lua) |
| `dc/ui.lua` | panel |

`autothresh`, `silence`, `log` and `wav` are pure Lua with no `reaper`
dependency, which is what makes the headless tests possible.

## Tests

**Headless** — the pure-Lua stages. No REAPER, no audio:

```bash
python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/headless.lua
```

Covers threshold derivation against four distributions (a clean gap, no gap at
all, too few events, and one where the estimators disagree), the offset and its
clamps, the silence floor in both directions (an island is found; continuous
material draws none; a thin mid-range is not mistaken for a second gap; an
almost-entirely-silent file is refused), the config split that decides what
invalidates what, the settings migration against a stubbed ExtState, the CSV
row, and the WAV writer's header and sample round trip.

It also renders **one panel frame** against a stub ImGui (`test/ui_frame.lua`),
empty and populated, and checks the style and disabled stacks balance. The
panel needs a context and a defer loop so no suite can run it for real, but
every way it breaks is a Lua error inside `frame()`, and those raise against a
stub just as well.

Each state is rendered twice: once quiet, and once with **every control
reporting that it was moved**, so the callback behind each one actually runs.
That second pass is the whole point. A stub whose sliders always return false
never reaches the code behind them, and that is exactly where this panel's
worst bug lived: `cfg[key] = v (on_change or mark_dirty)()` reads as two
statements but is not — Lua treats a `(` after an expression as a call, so it
called `v`, a number. Every slider and checkbox killed the panel, and a frame
rendered with nothing moved was perfectly happy. The disabled stack is now
counted and unwound before the error is reported, too, because an unbalanced
stack makes `ImGui.End` raise over the top of the real error and take the defer
loop down with it — reporting the symptom while hiding the cause.

**In REAPER** — three scripts, run from the Actions list or the harness:

- `test/selftest_in_reaper.lua` — drives the kernel on synthetic signals with
  known answers, with no item or project state involved. Run this first if
  anything looks wrong. Covers detection on a steady tone (none) and on injected
  clicks (all of them, at the right positions), monotonicity in the threshold,
  the cut-depth clamp, channel independence, `apply == input + isolate`, and
  the bit-exact passthrough of an empty gain envelope.
- `test/verify_edit_in_reaper.lua` — the whole pipeline through a real
  accessor, a real WAV and a real take. Its two load-bearing assertions are
  that **analysis saw audio and not silence** (the coroutine-accessor canary)
  and that an empty envelope **nulls at shift 0**, with ±1 sample clearly
  worse so an off-by-one cannot pass.

  It runs **two cases every time**: the selected item, if there is one, which
  is the only thing that can say whether the rules match a voice — and note
  that its peaks assertion reads the first eight seconds of the result, so a
  selected item that *starts* with silence fails it while its waveform is
  perfectly fine; and a
  **time-stretched** fixture, always, because at playrate 1 the `D_PLAYRATE`
  path is never exercised and every geometry bug passes. The fixture is built
  on a temporary track in the current project and deleted afterwards, and the
  item selection is restored.

  The end-to-end null lands at −80 dB or better rather than bit-exact, and
  cannot do otherwise: the output is a 32-bit float file, so every sample is
  rounded to 2⁻²⁴, and where the source is resampled — any stretched take —
  the resampler's output depends on where you seek into it, so one read cannot
  reproduce a strided traversal to the last bit. Measured directly: the
  rendered file agrees with the accessor to 1.5e-08, and the new take's
  accessor agrees with that file exactly.

**The null against the plugin** — the test the whole approach rests on:

```bash
python3 tools/null_vs_jsfx.py
```

The script does not re-derive the algorithm, it ports one that already works,
so the question that matters is not "does this sound right" but "is this the
same DSP" — and that has an exact answer. It renders the same clicky signal
through `Magnolius_DeClick.jsfx` (in a throwaway instance, which is safe because
`-renderproject` exits on its own) and through the script's pipeline, at
`nphases = 1` with a fixed sensitivity and the cut clamp lifted, and subtracts.

**Both sides pin the band layout from the same table.** The script side used to
inherit `flo`, `fhi` and `nbands` from `Config.defaults`, which quietly made
this a test of two things: that the DSP matches, and that the defaults have not
moved. Widening the analysed span therefore failed the null at −8.7 dB with a
port bug that did not exist. A test that pins one side and infers the other is
not pinning anything.

**It currently nulls at −316 dB**, which is denormal noise: the transcription
is bit-faithful. Anything above −80 dB is a port bug.

It needs `Magnolius_DeClick.jsfx` symlinked into `~/.config/REAPER/Effects/`, and
REAPER running for the script half.

All suites end with a guarded `os.exit(fails == 0 and 0 or 1)`, and count
anything that stops a run — "no item selected", "ReaImGui is missing" — as a
failure rather than an early return. A green exit has to mean the thing was
verified, not that the script declined to look.

- `test/silence_in_reaper.lua` — **that the derived threshold survives edited-in
  silence.** A 16-bit take whose first twenty seconds are noise-shaped dither,
  measured against the same take with that head trimmed off: the threshold must
  match, the silence must be found and sized, and with the guard off it must
  read *lower* — so the assertion is known to be testing something. A
  continuous 24-bit take is the control, where no floor may be found at all.
  It has to be dither and not digital zeros: an item run out past its source
  appends pure silence, which has nothing to fluctuate and produces almost no
  candidates, and an earlier version of this suite passed for exactly that
  wrong reason.

## Known limits

- **A take that is almost entirely silence still drifts.** The floor is refused
  when applying it would cross more than 95 % of the file, because below that
  there is no distribution left to read a threshold off. The panel says so in
  red rather than reporting a number it cannot stand behind.
- **Operates on the first selected item.** The pipeline is item-scoped, so a
  batch loop is a small addition, but it is not wired up — and neither is a
  headless entry point, though `dc/config.lua` and the pipeline take no panel
  dependency so that a later one can reuse them unchanged.
- Repair is a **band cut**, not interpolation. That is the right and gentler
  tool for mouth noise, which sits on top of content you want to keep. It is
  the wrong one for a genuine sample-level discontinuity — an edit pop, a
  dropout — and no amount of band cutting fixes one. AR interpolation as a
  second repair mode is the obvious extension; the place it would go is a
  branch in the render task.
- No serial multi-pass, no waveform zoom, no crackle/decrackle or broadband
  denoise.
- The envelope cache lives for the session only.
- Output is 32-bit float WAV, capped at the 4 GB the format allows.
