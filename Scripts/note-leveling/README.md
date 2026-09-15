# Note Leveling (ReaScript)

Two passes over a vocal, both stepped on the sung note rather than on a time
constant, and both written as automation so the audio is untouched.

**Part 1 — note leveling.** Detects pitch every few milliseconds, clusters the
pitch points into musical notes, measures each note's RMS, and moves notes that
fall outside a floor/ceiling window back toward it. Written as track **Volume
(Pre-FX)** automation, so the correction sits ahead of the vocal chain. A port
of the Volume tab of the Vocal Editor app
(`~/repos/audiolink/backend/vocal_editor`).

**Part 2 — the rider.** Rides the same vocal against the rest of the
arrangement: measures one or more reference clips, measures the vocal, and
writes a stepped ride as **Volume (post-FX)** automation on the fader. Where
part 1 asks "was that note louder than the other notes", this asks "is that
note sitting right against the track".

The unit of correction being a note is the whole point of both. A compressor
asks "is it loud right now"; part 1 asks "was that note louder than the
others"; part 2 asks "is this word going to be buried".

## Install

Requires **ReaImGui** (ReaPack). It is used for the panel *and* for the pitch
kernel, via `CreateFunctionFromEEL`.

```bash
ln -s "$PWD" ~/.config/REAPER/Scripts/NoteLeveling
```

Then add `Magnolius_NoteLeveling.lua` in Actions → Show action list → New action → Load
ReaScript. `Magnolius_NoteLevelingRide.lua` is the optional second action: the rider
with no panel, for running over a folder of takes.

## Use

The panel has two tabs, one per pass. **There is one Analyse for both.** It
reads everything selected — every target clip twice, every reference clip once
— whichever tab is in front, and fills in both. Each tab then has its own
write button. The two tabs are two views of one take, not two tools sharing a
window.

**Both tabs read the selection the same way**, and that matters as soon as
there are two of them: the rider needs the backing tracks selected alongside
the vocal, so "everything selected" cannot mean "everything to level". Under
either tab the **target** is the selected audio on the highest-numbered track
(or on **Target track** when that is set), and the clips above it are
reference. Select one clip and both tabs behave exactly as a one-input script
would.

### Notes

Select the vocal — on its own, or together with the reference clips — and
press **Analyse**. The tab says which clips it will write to, and how many
other selected clips are the rider's reference.

With more than one clip on the target track, an arrow pair in the top bar
picks which one the plots describe. It is shared by both tabs: they are
describing the same audio, and letting them drift onto different clips would
make every cross-tab reading wrong.

The window is two columns: controls on the left in the order the algorithm
runs, and the three displays on the right filling everything that is left. Drag
the splitter to resize the controls, or clear the **Controls** checkbox to give
the plots the whole window. **Hovering any plot puts a cursor across all three**
and reports the note and envelope value under it — that is how a dense three
minute take stays readable without a zoom control.

* **Pitch detection** — sampling distance (the 5 ms default), the pitch range to
  search, and how periodic a frame has to be to count as voiced. Changing any
  of these re-reads the audio, and the panel says so.
* **Notes** — how pitch points become notes, and the octave repair below.
  The **pitch plot** underneath shows the f0 track in blue with the detected
  notes drawn over it in green; that is the quick way to tell whether the
  settings suit this take. Frames the octave repair moved are drawn faintly in
  the octave they came from, so a repair is visible rather than silent.
* **Leveling** — floor, ceiling, how much of the correction to apply, and the
  most any one note may move. The **level plot** shows every note's RMS against
  the window, with the corrected level in orange where a note moved and in red
  where the move hit a limit.
* **Envelope** — whether to glide between notes, and ramp in and ramp out when
  not. The **gain plot** shows the envelope that will actually be written.
* **Output** — optional take markers, and the button that writes it all, for
  every selected item.

Everything below "Notes" recomputes as you drag, without re-reading a sample.
Only the detection settings need another Analyse.

### Octave repair

YIN decides each frame on its own, and a frame carries **no evidence about its
own octave**. So a held note comes back as the same note name in two octaves —
and since a note boundary here is a change of *semitone label*, an octave is a
different label and the sustained note gets cut into pieces. On the take this
was built against, 3.5% of voiced frames were octave errors and the longest
detected note was 3.27 s where it should have been 5.02 s.

The repair is a Viterbi over the pitch track with three states per voiced frame
— shift down an octave, leave it, shift up — and two costs. The transition cost
is how far the pitch moves between adjacent voiced frames, in semitones, so
cancelling a spurious octave jump is free and introducing one costs 12. The
emission cost is a small per-frame charge for being shifted at all, and it is
derived from **Believe an octave after** rather than being a free number: an
excursion pays 12 semitones at each edge, so correcting it saves 24, and
setting the charge to `24 × hop / hold` puts the break-even at exactly that
many milliseconds.

Which makes the control say what it means: **an octave change shorter than this
is a detection error; longer than it is the melody.** **Link across gaps up to**
cuts the chain over a rest, so a phrase that genuinely starts an octave away is
not dragged back to the previous phrase's octave.

#### The register, which is what continuity cannot supply

Continuity alone believes anything held long enough — by the hold rule a five
second note *is* the melody, however implausible. On the reference take that
left two long notes reading **C5 in a take centred on A3**, which no male voice
sings; they were misread C4s, and the note before each of them was a C4.

So the second half of the repair is the singer's own range. **Trust pitches
within** sets a dead zone around the median of the take; outside it, the octave
is doubted with a cost that grows as the square of how far out it sits.

Three things about that shape, each load-bearing:

* It is measured from the take, never assumed. A soprano's C5 is at her median
  and costs nothing; the same C5 in a tenor take is fifteen semitones out.
* The dead zone is a **dead zone**, not a pull toward the median. A linear pull
  would collapse every phrase into the median's octave, because for any note at
  all the nearer octave is the one closer to the middle — a genuine fourth
  above the median would be dragged a fifth below it.
* Its width **adapts to the take's own spread** (three times the median
  absolute deviation, floored by the control). A voice that spans ten semitones
  end to end should doubt a note twelve above its median; a melody that
  genuinely covers two octaves should doubt nothing. A fixed width has to be
  set for the widest singer it might meet and is then useless for the rest.

Both halves are medians for the same reason: the wrong octaves have to
outnumber the right ones before either the centre or the width moves, so the
measurement survives the errors it is being used to find. The rounds iterate —
continuity first, then the register measured from that answer, then again —
until they agree.

On the reference take this turned the 3.27 s longest note into 5.77 s, and the
detected range from D#3–C5 into D#3–C4.

This is the one place the script leans on being for voices, and the checkbox is
there for anything that really does move in octaves.

#### Why this cannot be done in the kernel

The obvious idea is to have YIN report how periodic the frame looked at the
octave-related lags and let the lower cost win. It does not work, and the two
reasons are worth knowing before spending a day on it:

* `cmnd(2·tau)` is low for a **correct** reading too. Anything periodic at *T*
  is also periodic at *2T*, so the difference function dips at every multiple of
  the true period — which is exactly why YIN takes the first dip below the
  threshold rather than the deepest one.
* `cmnd(tau/2)` is high for **every** reading, by construction. The first-dip
  rule already looked there and rejected it; had it been below the threshold,
  that is the answer YIN would have returned.

So the information is not in the frame and never was. It is in the frames on
either side, which is why pYIN runs an HMM over candidates rather than deciding
frame by frame.

Note which way the errors go: on the reference take **every one of the 19
excursions was a shift down** — that is, YIN had read those frames an octave
*high*. That is the first-dip rule's own bias showing, and it is the expected
direction rather than a coincidence.

### The leveling rule

A note inside the window is left alone. A note outside it moves `amount`
percent of the way back to the edge it crossed:

```
-6 dB RMS, ceiling -7 dB, amount 100%  ->  -1.0 dB
-6 dB RMS, ceiling -7 dB, amount  50%  ->  -0.5 dB
```

The move is then clamped to **max boost** and **max cut**. The clamp is applied
*after* the amount, so the two controls read the way they look: `amount` is how
much of the correction you want, and the limits are the most any single note
may move whatever that works out to. They are separate per direction because
the directions are not symmetric — pulling a loud note down is nearly always
safe, pushing a quiet one up lifts its noise floor with it. Notes held at a
limit are drawn in red and counted under the leveling sliders.

This is the one place the port deliberately departs from the Vocal Editor,
which clamps a note exactly onto the floor or ceiling instead.

### The envelope shape

Two shapes, chosen by **Glide between notes**.

**Ramped** (the default). Between two notes, if the gap is long enough for both
ramps, the envelope falls to unity gain over `ramp out`, rests there, and rises
into the next note over `ramp in` — so a consonant or a breath between two
notes keeps its own level instead of inheriting a neighbour's correction.

If the gap is shorter than `ramp in + ramp out`, the envelope goes **straight
from one note's gain to the other's** without dipping to unity. Dipping and
recovering inside a few tens of milliseconds would be an audible flutter
between every pair of notes.

**Glide.** The envelope never returns to unity. The first note's gain reaches
back to the start of the clip, every gap is one linear transition from the gain
on its left to the gain on its right however long it is, and the last note's
gain holds to the end. `ramp in` and `ramp out` have nothing to say and are
disabled; point spacing still applies.

The default is the honest shape when only some notes are corrected: it moves
notes and leaves everything else exactly where it was. It fails when
**neighbouring notes are both cut**. The consonant, breath or room tone between
them is then the one thing still at unity, so it ends up the loudest event in
the phrase and a pre-FX cut meant to even out the melody has promoted the noise
between it instead. Glide carries the correction across the gap, at the price
of applying a gain to material that was never measured — which is why it is a
switch and not the default.

Ramps and transitions are subdivided into points rather than left as two. A
REAPER envelope interpolates linearly in its own stored domain, which is not
dB, so a two-point ramp would be the wrong curve. A **flat** span is the
exception and is left as two points: it is flat at any density, and glide's
gaps are as long as the arrangement makes them.

### Take markers

**Write take markers per note** brackets every detected note with a pair of
take markers — the note name at the start, `<name> end` at the finish — so the
detection can be read and hand-edited in the arrange view rather than only in
the panel. Off by default: they are a second opinion on the same detection the
envelope already encodes, useful when you want to see it, noise when you only
want the gain.

Take markers are stored in **source** position, which is the one coordinate in
this script that is neither take time nor project time:
`D_STARTOFFS + take_time × playrate`. Any take markers already on the take are
cleared first, for the same reason the envelope is.

### Rider

Select the reference clips **and** the target, then press **Analyse** — on
either tab; there is only one, and it reads both halves. The reference clips
are measured and mixed together; the target is ridden against them.

**Which clip is the target.** REAPER does not expose item *selection order* —
`GetSelectedMediaItem` walks items in track-then-position order however they
were clicked, and there is no "last selected item" to ask for. So the rule is
positional: **the target is the selected audio on the highest-numbered track,
and everything above it is reference.** References on tracks 1 and 2 with the
vocal on 3 resolves as intended, it survives being reselected in any order, and
it is decidable from project state alone, which is what a headless run needs.
**Target track** overrides it with an explicit track number. All the selected
audio on the target track is ridden, since a comped lead vocal is usually a row
of clips.

No reference at all is a legitimate way to use this: the target term still
levels the take against its own median.

* **Balance** — where the vocal should sit against the reference, in dB. It is
  an *absolute* offset, so it fixes a wrong static balance as well as riding.
  Nothing says a vocal should sit at 0 dB against the sum of everything else,
  so **Match the balance the mix already has** sets the offset to whatever the
  mix currently is and lets the rider only redistribute it.
* **Ride** — the two depth controls, and the caps.
* **Measurement** — the two analysis windows, the longest a single level may be
  held, and the gate below which nothing is ridden at all.
* **Motion** — smoothing, speed, look ahead, transition length.
* **Output** — trim, and whether to write part 1's Pre-FX envelope at the same
  time (see *Why the two writes are coupled*).

The three plots answer the three questions the controls cannot. The top one is
the target through the vocal band with the segmentation over it — amber bars
are stretches the note detector had nothing to say about, and a take that is
all amber is a take whose pitch settings are wrong. The middle one is the
comparison the gain law is made of: the arrangement against the voice, with
both medians drawn, and the distance between them *is* the static term. The
bottom one is the curve as it will be written, with a tick at every onset it
was aimed at — seeing the curve already flat when the tick arrives is the whole
claim this feature makes.

### The gain law

Per segment, in dB, with `R` the reference level and `T` the target level:

```
static  =  R_med + offset - T_med           the overall balance
follow  =  ref_follow * (R - R_med)         louder backing → louder vocal
level   = -tgt_level  * (T - T_med)         softer word    → more boost

gain    =  static + follow + level          then smoothed, capped, trimmed
```

At `ref_follow = tgt_level = 100%` this is exactly `R + offset - T`: a
constant-differential ride that pins the vocal a fixed distance above the
arrangement and cancels all of its own dynamics. At 0/0 it is a static gain
change.

The `level` term is the one the brief turns on. It is what makes a soft phrase
rise **further** than a loud one under the *same* backing, which no
differential-only rider can do.

The medians are taken over the segments, not over the timeline: the balance of
a record is set by where the voice sits when it is singing, and an instrumental
break should not get a vote.

### Why the ride is stepped on notes

The standard failure of a vocal rider is that the settings which sound natural
are too slow to be right. Give a follower a time constant short enough to catch
the start of a word and it chatters inside the word; give it one long enough to
sound smooth and every phrase fades in, because the correction arrives after
the syllable it was for. Both symptoms are the same bug: a follower can only
respond to what has already happened.

Offline, that constraint is optional. The note segmentation already says where
every word begins, so the level for a word is decided from the whole word and
is then **in place before the word starts**. That is what **look ahead** does —
the transition is *finished* that long before the onset, in the consonant or
the breath preceding it — and it is the difference between a rider that fades
into phrases and one that nails them.

Between segments the curve simply **holds**. There is nothing to follow in a
gap, and following it is precisely what makes a rider pump on breaths and room
tone. This is the one place the ride differs structurally from part 1's
envelope: for a corrective envelope, returning to unity between notes is the
neutral thing to do; for a ride it is a dip back to the wrong level, once per
word. Part 1's **Glide between notes** is the same argument reaching back into
the corrective envelope, for takes where the neutral thing is the wrong thing.

One caveat where the two meet: with **Ride after note leveling** on, the rider
adds each segment's Pre-FX note gain to the level it plans against, and it
takes that gain from the segment's note — so a segment with no note is assumed
to sit at unity. Under glide it does not; it sits somewhere between its
neighbours. The error is bounded by the gap between two adjacent note gains and
only affects gap segments loud enough to be ridden at all, but it is an
approximation on top of the one already documented above.

Below **Ride only above** nothing is ridden at all and the curve holds through.
That is the rest of the answer to quiet passages being dragged up: a breath or
a reverb tail asks for the biggest boost of anything on the take, and granting
it is exactly the pumping a rider gets accused of.

**Smoothing** is a zero-phase Gaussian over the per-segment gains, weighted by
the time between segment centres — a bar of sixteenths and a bar of whole notes
smooth over the same musical distance, which a segment count cannot express.
Zero-phase because this is offline; a one-pole would lag by its own time
constant and reintroduce the exact fault the note stepping removes. At the
1 second default the ride is a macro move — expect neighbouring notes to come
out within a fraction of a dB of each other, and turn it down to let the ride
work phrase by phrase.

**Speed** is a slew limit in dB/s: a big step takes longer rather than being
truncated into a jump. **Transition** is the nominal length, which speed
stretches. Transitions are raised cosines, not straight lines — a linear ramp
has a corner at both ends, and at these depths a corner is audible as the
moment the ride started moving.

### Where there are no notes

Rapped or spoken lines, whispers, anything the pitch detector could not label:
the level track is all there is to go on, so those stretches are segmented into
runs above the gate, cut at level onsets. They are drawn in amber and behave
exactly like note segments from there on. Without this a spoken bridge would
inherit the gain of the last sung note before it and hold it for eight bars.

Stretches *below* the gate produce no segment at all, which is not a fallback
but the correct answer: the curve holds.

### The vocal band

Both sides are measured through a fixed 300 Hz – 4 kHz band (two Butterworth
biquads, 12 dB/octave each) and reduced with a **90th percentile** rather than
a mean.

The band is the load-bearing choice. Broadband RMS of a backing track is
dominated by kick and bass, which a vocal does not compete with, so a guitar
entering a chorus can bury the voice while barely moving the broadband number.
The kernel selftest asserts this directly: two beds of equal amplitude at 50 Hz
and 1.5 kHz read within a couple of dB of each other broadband and more than
25 dB apart through the band.

The percentile rather than a mean because a sung note that opens on a breath,
or a bar of backing with a rest in it, has a mean well below what it actually
masks with. It is not the maximum, which would be a single frame of a
transient.

Both are constants rather than sliders, because they are analysis parameters:
a slider for either would silently invalidate the pitch pass and demand another
Analyse, which is a bad trade for numbers that have one sensible value.

### Both analysis windows start at the onset

What a syllable competes with is what happens from the moment it starts, not
the average over a note that may run on for four seconds after the decision was
made. The reference window is widened to at least 200 ms even for a short
consonant, since a 70 ms consonant still competes with a whole beat.

**Longest held level** splits anything longer into equal parts, each measured
on its own, so a sustained note can follow a build underneath it. Equal parts
rather than "one cap-length then the rest": the stub would get its own level
from a window barely longer than itself and stand out.

### Why the two writes are coupled

The rider measures the raw take and **adds part 1's per-note gains to it**, so
it plans against the signal the fader will actually see. That is exact for the
note leveling and blind to everything else in the chain — a compressor between
the two will have moved the signal again — and it is the one approximation in
the design. It is there to avoid analysing the vocal twice.

It is only *true*, though, if the Pre-FX envelope is actually written, so
**Also write the Pre-FX note leveling** is on by default and the rider writes
both envelopes in one undo block. Turn it off and the rider plans against the
raw take instead; both are consistent, and the checkbox is which one you mean.

The two envelopes stack cleanly because they are different envelopes on the
same track: part 1 owns `<VOLENV` (Pre-FX), the rider owns `<VOLENV2` (the
fader). Pre-FX for a corrective pass so the compressor sees an already-balanced
signal; the fader for a mix move, because putting a macro ride in front of the
compressor is exactly the fight this split avoids.

The two also clear differently, and deliberately. Part 1 wipes its whole
envelope, because a note-leveling pass owns it outright. The rider clears
**only the span of the clips it rides**, because the fader is where the rest of
a mix lives.

### Headless

`Magnolius_NoteLevelingRide.lua` is the rider as a plain action: resolve the selection,
read, ride, write, report to the console. No window, no defer loop. Every
parameter comes from ExtState, which is where the panel leaves them, so the
workflow is "tune it once in the panel, then run this on the other forty".
Set **Target track** first if the auto rule does not suit the layout.

ReaImGui is still required even though nothing is drawn: the kernels are EEL
compiled through `CreateFunctionFromEEL`, which lives in ReaImGui. The context
is created and never shown.

## Layout

| Path | Role |
| --- | --- |
| `Magnolius_NoteLeveling.lua` | entry action — the panel |
| `Magnolius_NoteLevelingRide.lua` | entry action — the rider, headless |
| `nl/config.lua` | defaults, ExtState, parameter-class signatures |
| `nl/kernel.lua` | owns the EEL memory map; nothing above it knows an address |
| `nl/dsp/pitch.eel` | task 1 per-frame RMS, broadband and banded; task 2 YIN |
| `nl/analyze.lua` | the accessor edge — take in, frame table out |
| `nl/octave.lua` | pure: repairs octave errors in the pitch track |
| `nl/cluster.lua` | pure: pitch frames → notes |
| `nl/level.lua` | pure: notes → gains → envelope points |
| `nl/select.lua` | which selected clips are reference and which is the target |
| `nl/reference.lua` | pure: several reference clips → one level track |
| `nl/rider.lua` | pure: notes + reference → segments → gains → curve |
| `nl/ride.lua` | the rider's read job, shared by the panel and the action |
| `nl/apply.lua` | the only file that touches the project |
| `nl/ui.lua` | the ReaImGui panel, both tabs |
| `test/wav.lua` | float WAV writer, used only to build a test fixture |
| `test/ui_frame.lua` | one panel frame against a stub ImGui |
| `test/panel_in_reaper.lua` | the panel against the real ReaImGui |
| `test/run_panel_test.sh` | runs the above and waits for its result |

## Notes on the design

**Two passes at two sample rates.** YIN costs `window × tau_max` per frame and
both grow with the rate, so at 48 kHz it runs near realtime — minutes on a
vocal take. The pitch pass therefore asks the audio accessor for 8 kHz and lets
REAPER do the anti-aliased decimation; that is ~40× cheaper and still resolves a
600 Hz f0 to about ±10 cents, against the 50 cents semitone bucketing needs.
The level pass is *not* decimated — a leveling tool that ignored everything
above 4 kHz would misjudge bright and breathy voices — so it reads separately at
the source rate. Two reads cost far less than one slow analysis.

**The frame grid is defined in time, not samples.** 5 ms at 44100 is 220.5
samples. An integer hop drifts half a sample per frame, which is nearly half a
second over a three minute take — every note sliding against the audio it was
measured from. The fractional hop goes to the kernel and each frame rounds its
own start from its absolute frame number.

**The take accessor's timeline is take time.** It spans `0 .. item length` with
the playrate and preserve-pitch setting **already applied**, verified here at
playrates 1.0, 1.5 and 0.5. So the span to analyse is the item length, not
`item length × playrate`, and take seconds become project seconds by adding the
item position with no playrate factor anywhere. Ramp lengths are consequently
real time: 60 ms is 60 ms however the item is stretched.

**A job never reads its own audio.** `GetAudioAccessorSamples` returns nil and
reads nothing from inside a Lua coroutine — silently, so a job that read its own
audio would analyse a completely silent file. The job yields a read request and
the panel, which is on the main thread, fills it and resumes. An unserviced
request is a hard error, never an empty buffer.

**Optional ImGui symbols need pcall, not `or`.** The ReaImGui shim raises on an
unknown field rather than returning nil, so `ImGui.A or ImGui.B` never gets to
the fallback. It matters here because `ChildFlags_Border` was renamed
`ChildFlags_Borders` in ReaImGui 0.10 and this script pins 0.9, where the
plural name does not exist. The published API docs list every symbol
regardless of version, so grepping them proves nothing about what the pinned
version exposes — only asking the library does.

**One bad frame must not wedge REAPER.** Wrapping the frame in a `pcall` is
enough only while the frame opens nothing. This one opens child windows and
disabled scopes, and a frame that throws between `BeginChild` and `EndChild`
leaves ImGui's stack unbalanced — which ReaImGui raises on at the next `End`,
*outside* the `pcall`. In REAPER that is a modal error dialog and a main thread
that stops answering, including to every other script. So the panel counts the
pairs it opens and unwinds them after a failed frame.

**The reference is mixed in power, and coverage is tracked apart from level.**
Two guitars at −18 dB each are −15 dB together, not −18 and not −36, and only
summing the mean squares gets that right — which is also the correct model for
sources that are not correlated with each other, i.e. separate tracks of an
arrangement. Alignment is done in project time and the fractional frame offset
is **rounded**, not truncated: truncating would bias every reference late by
half a frame on average, and the rider's whole premise is that its decisions
land on the right side of an onset. And "no reference clip reaches here" is
kept separate from "the arrangement is silent here", because they want opposite
behaviour — silence should pull a vocal down, an uncovered stretch must not be
allowed to say anything at all.

**A 5 ms frame cannot measure a 50 Hz tone.** 50 Hz at 48 kHz is a 960 sample
period and a frame is 240 samples, so each frame's RMS is really a sample of
the waveform's phase and the median across frames sits about 2 dB under the
true RMS. Nothing is wrong when that happens — the frame is shorter than the
thing being measured — but an assertion about a low frequency has to pool the
frames or it is asserting the phase. This cost two apparent kernel failures
that were both the test's arithmetic.

**An edit made outside an undo block is folded into the next block that
closes.** REAPER snapshots project state at block end, so a point inserted with
no block of its own becomes part of the next `Undo_EndBlock` — and undoing that
block takes the point with it, even though it was there first. Anything that is
supposed to survive an undo has to be a committed state of its own.

**One analysis, two derivations.** The reads are the expensive half and are
cached whole in `ST.data`; `ST.nd` (notes and the Pre-FX envelope) and `ST.rd`
(segments and the ride) are derived over it, each invalidated by its own
parameter classes. That is the same bargain the note leveling always made,
extended to cover the reference clips — and it is why a button whose meaning
depended on which tab was in front could be removed rather than fixed. Either
write button will read first if what is in hand is not for this selection, so
pressing one without analysing is a longer wait rather than an error.

**ImGui owns which tab is active; the panel only reads it.** Exactly one
`BeginTabItem` returns true, so `ST.tab` is written *from* the tab bar every
frame and never to it. Assigning `ST.tab` from outside appears to work and is
undone before the columns below are drawn — which is how a test harness came to
report that it had rendered the Rider tab eight times without ever drawing it
once. Selecting a tab has to be a *request* the bar honours
(`TabItemFlags_SetSelected`), and the request has to be held until it is
granted, because ImGui applies it when it next lays the bar out rather than on
the spot.

**ImGui also persists a window's collapsed state by title, across sessions.**
A panel someone once collapsed makes `Begin` return false forever after, so a
suite that asserts on the return value is really asserting on a saved setting
from another day. `panel_in_reaper` forces the window open with `Cond_Always`.

**An empty envelope cannot be activated.** `GetTrackEnvelopeByChunkName(track,
"<VOLENV")` hands back the built-in envelope whether the track has used one or
not, so nothing needs creating — but setting `ACT 1` on a point-less envelope
silently does nothing. The order has to be wipe, write, then activate.

## Tests

There is no system `lua` on this machine; the suites run inside the
already-running REAPER.

```bash
python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py \
  test/headless.lua test/selftest_in_reaper.lua \
  test/verify_edit_in_reaper.lua test/verify_ride_in_reaper.lua --timeout 300
```

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `headless.lua` | clustering, octave repair, gains, envelope geometry, the vocal band's coefficients, reference mixing, and the rider's segmentation, gain law, smoothing and curve. Pure Lua, no REAPER. | anything in EEL, anything touching the project |
| `selftest_in_reaper.lua` | the EEL kernel on synthetic signals with known answers — both level reductions and the vocal band — and panel frames against a stub: both tabs, quiet and with every control moved | that the panel *looks* right |
| `verify_edit_in_reaper.lua` | part 1's whole pipeline: accessor → kernel → notes → gains → envelope → read back, at playrate 1.0 **and** 1.5 | playback, i.e. that REAPER honours the automation |
| `verify_ride_in_reaper.lua` | part 2's whole pipeline: selection → accessor → band → mixing two reference clips onto the target's grid → segments → gains → curve → the fader envelope → read back, at both playrates | the same |
| `panel_in_reaper.lua` | the panel through the real ReaImGui, in all eight layout states | that the panel *looks* right |

The panel test cannot go through `reascript_test.py` and has its own runner:

```bash
./test/run_panel_test.sh
```

`verify_edit_in_reaper` builds its own fixture — a three note take at three
known levels, inserted twice — and deletes it afterwards. It needs no selection
and leaves no trace. The stretched copy is the point: at playrate 1 the
take-time to project-time conversion is the identity, and every error in it
passes.

`verify_ride_in_reaper` builds three tracks laid out the way the rider is meant
to be used, and three things in that fixture each catch a class of bug nothing
else would:

* the reference clips sit **half a second earlier** than the target, so target
  frame *i* and reference frame *i* are not the same instant and the mixing has
  to shift one onto the other. At the same position every shift bug — dropped,
  negated, doubled — passes.
* they therefore also **run out** before the target does at playrate 1, which is
  the only way to check that an uncovered stretch is reported as uncovered
  rather than as silence. Those are opposite mistakes: silence should pull a
  vocal down, no-reference must not.
* both reference clips are the **same file**, so the mix must read exactly
  3.01 dB above one of them. Power summing is the only rule that gives that
  number: adding dB gives +40, taking the louder gives +0.

It has to change the item selection — which clips are selected *is* the rider's
input — and puts the caller's selection back afterwards.

Two things it learned the hard way, both recorded in the file. Which notes
straddle the reference step **depends on the playrate**, so the assertions
compare notes that fall on the same side in both cases and derive the rest from
the geometry. And a project edit made outside an undo block is folded into the
next block that *closes*, so the guard point that proves span-only clearing has
to be committed in a block of its own or the undo assertion takes it away.

Every suite ends `if os.exit then os.exit(fail == 0 and 0 or 1) end`, and
anything that stops a run early — no ReaImGui, a kernel that would not build —
counts as a failure rather than a quiet pass.

**Why the panel needs its own runner.** `reascript_test.py` emits its completion
sentinel as soon as the file finishes loading, so a `reaper.defer` loop reports
success before rendering anything — a green run that checked nothing. Rendering
synchronously to avoid that does not work either: `ImGui.Begin` outside the
defer cycle blocks REAPER's main thread on its script-timeout dialog, and every
later test times out until someone clicks it. So `panel_in_reaper.lua` defers
like a real panel, writes its own result file, and `run_panel_test.sh` polls for
it. Nothing in that loop may throw, for the same reason: REAPER's error dialog
is modal.

## Known limits

* Monophonic vocal only. The pitch range defaults to 75–600 Hz.
* The octave repair assumes a voice: it treats a short octave change as an
  error. Anything that really arpeggiates across octaves wants it off.
* An envelope belongs to a track, so items overlapping on the same track share
  one curve and the later item wins where they overlap.
* Applying part 1 **clears the entire Volume (Pre-FX) envelope** on every track
  it touches, including automation this script did not write. The rider clears
  only the span of the clips it rides.
* The rider reads reference clips as **raw take audio**: the track fader, pan
  and FX are not applied, because the audio accessor does not apply them. If the
  reference has to reflect a processed mix, bounce it and use the bounce as the
  reference clip.
* The rider knows the Pre-FX note gains exactly and knows nothing about the rest
  of the vocal chain, so a compressor between the two envelopes will have moved
  the signal in a way the ride did not plan for.
* Item **selection order** is not available from ReaScript, so the target is
  chosen positionally — the highest-numbered selected track — or named
  explicitly with **Target track**.
* Boosts beyond REAPER's volume envelope range are clamped by REAPER, on top of
  the max boost limit.
* Take markers belong to the take, so writing them replaces any that were
  already there.
* Part 1 levels every selected clip **on the target track**, not every selected
  clip. Clips on other tracks are the rider's reference and are left alone.
* The plots have no time zoom. The hover cursor is what stands in for one.
