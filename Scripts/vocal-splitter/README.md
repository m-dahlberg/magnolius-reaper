# Vocal Splitter

A REAPER script that segments a vocal take top-down, levels each part against
the part above it, and rejoins everything with crossfades.

```
take
 └── sections      longest pauses      normalised toward an absolute target
      └── phrases  shorter pauses      normalised toward their section
           └── breaths / hard consonants / sibilance
                                       found by feature scan, cut out and
                                       turned down by an offset
```

## Install

Requires **ReaImGui** (ReaPack). It is used for the panel *and* for the analysis
kernel, via `CreateFunctionFromEEL`.

Put the folder where REAPER can see it, then add `Magnolius_VocalSplitter.lua` in
Actions → Show action list → New action → Load ReaScript. To keep editing in
place:

```bash
ln -s "$PWD" ~/.config/REAPER/Scripts/VocalSplitter
```

## Use

Select one audio item, run the action, press **Analyze**. **Reset settings**
next to it puts every tunable back to its default; it asks once, because
settings are written straight to ExtState and there is no undo for them.

The panel reads top to bottom in the order the algorithm runs. Work down it:

1. **Gate** — the histogram shows the level distribution with the gate drawn
   on it. Vocal material is bimodal; the gate belongs in the valley between the
   room-tone lobe and the signal lobe. Auto puts it there.
2. **Detection** — check the section and phrase counts look like the
   arrangement. Turn auto gap thresholds off to set the two pause lengths by
   hand.
3. **Processes** — all five levels have a checkbox, so any one can be run and
   judged on its own (see below). Each detected element is cut into its own
   clip and that clip is turned down by its offset, on top of whatever its
   phrase got; nothing else moves. A phrase that ended up at −23 dB with the
   sibilance offset at −6 dB puts its /s/ clip at −29 dB. Elements are **not**
   normalised: a quiet breath stays proportionally quiet, because it was a
   quiet breath.
4. **Refine detection** — three collapsing panels for when the counts look
   wrong. *Breaths* shows the funnel (runs → candidates → taken) with one
   **Sensitivity** control and, when candidates were rejected, which feature
   held them back and where Sensitivity would have to sit to take the best one;
   its absolute per-frame tests are grouped separately from the graded ones,
   because they fail in different ways and are fixed by different controls.
   *Hard consonants* shows how many onsets cleared the rise threshold and why
   the rest were dropped — too short, no closure, voiced, fricative.
   *Sibilance* holds the threshold, the length limits and the two controls that
   decide how far each clip reaches past the detected core — widen those if you
   hear a level jump part way through an /s/.
5. **Mark detection only** writes markers and regions and touches no audio.
   Sections and phrases go down as markers, and every detected element as a
   *region* — a breath or an /s/ is a span, and both of its ends are under
   judgement, since the two complaints that send you here are "it did not find
   that one" and "the clip is shorter than the sound". Use it to check
   detection against your ears before touching a level.
6. **Apply**.

Items are coloured and tagged by class, so a wrong detection is visible at a
glance before you judge the levels.

### Running one process at a time

Every level has a checkbox. Switching one off **collapses it into a single node
spanning its parent** rather than removing it, so whatever is left
automatically references the next enabled level up:

| Sections | Phrases | A phrase's reference is |
| --- | --- | --- |
| on | on | its section |
| on | off | its section (one phrase per section) |
| off | on | the whole file |
| off | off | the whole file |

The reference decides how much a *level* is turned up or down. It does not
decide what counts as an element — an offset is the same number of dB whatever
is enabled above it. So to judge sibilance reduction on its own, press **None**,
tick Sibilance, and every /s/ clip is turned down by the offset with the rest of
the take left at unity. The panel shows which reference is in force and what the
whole-file value is. `All` / `None` set every checkbox at once.

**Element detection does not depend on these switches at all.** All three
element scanners work on the frame features, and the one quantity a breath is
judged against — how far below the singing it sits — is measured locally, over
a couple of seconds either side, rather than read off the phrase node. So
pressing **None** and ticking Breaths finds exactly the breaths that ticking
everything finds, which is what makes "judge one process on its own" mean
anything.

### The gain model

```
g_section = section_pct × (target − L_section)
g_phrase  = phrase_pct  × (L_section − L_phrase)
g_element = offset
```

A disabled level contributes zero gain, and `L_phrase` degrades to `L_section`
and then to the whole-file level as levels are switched off.

An item's gain is the sum of its ancestors'. The section gain cancels out of
the phrase formula, so **moving the section target shifts everything equally
and never disturbs the internal balance** — which is what makes the sliders
predictable. `test/headless.lua` asserts this.

Sections and phrases *normalise*: they measure a reference and drive it toward
a target. Elements do not — an offset is a plain relative attenuation of the
clip that was cut out for it.

That distinction was got wrong once, and the failure is worth recording.
Elements used to be driven to `phrase + offset`, as a target or (with an
attenuate-only cap) a ceiling. But a breath sits some 20 dB below its phrase,
so "bring it to phrase − 6" is a *boost* of about 14 dB — and the cap turned
that into exactly 0 dB. Every detected breath was faithfully found, cut into
its own clip, coloured, tagged, and then left completely untouched. Levelling
an element against its phrase also fights the performance: a breath is quiet
because the singer breathed quietly, and a soft /s/ needs no de-essing.

Because the offset no longer depends on the element's measured level, there is
nothing left for a clamp to protect against, so `max_change_db` and
`attenuate_only` are gone. The number in the panel is the number of dB applied.

**Only detected elements are ever moved.** The residual between them carries
its phrase's gain unchanged. Spans are attributed by the audio they contain
rather than by whatever sits at their midpoint: cuts are placed inside pauses,
so a span reaches well past its element on both sides and a midpoint lands
wherever the surrounding silence happens to put it — for a breath at the head
of a take that was a coin toss between ducking it and missing it entirely. A
span holding only silence is a pause: it takes its phrase's gain, never a
neighbouring element's, since a pause carrying a breath's −6 dB puts a step in
the room tone either side of every breath. Two headless tests hold this down:
audible audio always keeps its own element's gain, and an element clip contains
only that element.

### Elements are detected first, and the levels are measured over what is left

The pipeline runs bottom-up: the gate finds the segments, the gap durations
group them into sections and phrases, then **every element is detected**, and
only then are the section and phrase reference levels measured — with the
element frames excluded outright.

The arithmetic is not why. Applying the offsets first and re-measuring, which
is the same thing as gluing the edit and analysing it again, moves a section
level by 0.014 dB and a phrase by 0.034. That is nothing, and it is nothing for
a good reason: element offsets only touch unvoiced audio, and the references
were already measured over voiced frames.

It matters because a node can be made **entirely** of elements, and then
measuring it before they exist is measuring a breath and calling it a phrase.

That is not hypothetical. When the gate does resolve a breath — a 93 ms one at
4.87 s on the test take — the breath becomes a segment, the segment becomes a
phrase, and the phrase measures its own reference at −56.5 dB against a section
at −27.5. Phrase normalisation then hands it **+20.3 dB**, and the breath comes
out at +23.8 dB while every phrase around it moves 9 to 11. The loudest thing
in the take is a breath.

Two things had to change for that, and both are the same mistake:

- **Reference levels exclude element frames.** The voiced filter alone was not
  enough, because it only excludes them while the voiced path is in use and the
  fallback puts every gated frame back in.
- **`reliable` means the estimate that was actually used, not that some count
  cleared the threshold.** A node with one voiced frame and thirty gated ones
  came back reliable on the strength of the gated count, and was then
  normalised as though its gated mean were a voiced reference. In voiced mode
  the voiced count is the only one that can say so — which is what the doc
  comment above it had claimed all along.

Reference levels are measured over *voiced frames only*. Including silence
would make a section with long pauses measure quieter and get boosted for it;
including breaths would let a breathy phrase drag its own reference down.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_VocalSplitter.lua` | entry action |
| `vs/config.lua` | every tunable, plus ExtState persistence |
| `vs/dsp/features.eel` | per-sample kernel (the hot loop) |
| `vs/analyze.lua` | accessor block loop → per-frame features |
| `vs/autothresh.lua` | gate, sibilance and pause thresholds from the material |
| `vs/hierarchy.lua` | gate → sections → phrases → elements, and cut placement |
| `vs/levels.lua` | reference levels and the cascade |
| `vs/apply.lua` | split, gain, crossfade, colour (the only file touching the project) |
| `vs/ui.lua` | panel |
| `test/frames.lua` | load/save a frame table as text |
| `test/dump_frames.lua` | regenerate the frame fixture from the test item |
| `test/ui_frame.lua` | stub ImGui, so a suite can render one panel frame |
| `test/vocalsplit_frames.tsv` | frame features of the test take, committed |

`autothresh`, `hierarchy` and `levels` are pure Lua with no `reaper`
dependency — which is what makes the headless tests possible.

## Tests

**Headless** — covers stages 2–4 from synthetic frames with known ground truth.
No REAPER, no audio. Three fixtures:

- `build()` — the clean case, for structure and the gain cascade.
- `build_hard()` — sibilants whose edges fade well below half their own peak
  ratio; a close-mic'd breath only 8 dB under the phrase; and a breath with a
  transient in it, so Sensitivity has something to be sensitive about.
- `build_gateless()` — the case this stage exists for. Two breaths below a gate
  that has to sit where it does: one running straight into the phrase after it
  so the gate never gives it a segment, one alone in the middle of a long pause
  entirely under the gate. The suite asserts first that *neither is a gate
  segment* — otherwise it could pass for the wrong reason — then that both are
  found, that the clips cover them, and that the offset actually lands on the
  resulting spans.

That last assertion is its own trap: a span holding no frame above the gate
used to read as a pause and take its phrase's gain, so a sub-gate breath was
faithfully found, cut into its own clip, coloured, tagged — and left at unity.

It also renders one **panel frame** against a stub ImGui, empty and populated,
and checks the style and disabled stacks balance. The panel needs a context and
a defer loop so no suite can run it for real, but every way it has broken has
been a Lua error inside `frame()` — a config key renamed out from under a
slider, a diagnostic field that moved — and those raise against a stub just as
well. A source scan additionally checks every `slider`/`checkbox` names a key
that exists, and lists the settings that have no control at all.

**Detection, against real audio** — the one suite that can tell whether the
specification matches a voice.

```bash
lua test/detection.lua
```

The synthetic fixtures prove the stages behave as written. They cannot prove
the rules are the right rules, and that is where every detection bug here has
actually lived: a "breath" at `sib_ratio` 0.78, a burst peak read off the
following vowel, six ANDed windows that each looked reasonable. This suite runs
the stages over the frame features of `VocalSplit test.wav` — committed as
`test/vocalsplit_frames.tsv` — and checks all 19 elements counted by ear are
found, in the right class, that nothing else is, and that no clip is truncated
to its core.

The fixture stores only what the kernel measures; `ms` and `slope_db` are
derived on load exactly as `analyze.lua` derives them, so it cannot disagree
with itself. **It begins after stage 1**, so a change to the kernel or the
accessor reads clean here and still breaks the real pipeline —
`fixture_fresh_in_reaper.lua` is what closes that.

Take the fixture from the WAV the repo ships, not from a region of whatever it
was exported from. Those null against each other at −113 dB RMS and still move
room-tone frames by up to 7 dB, because −64 dB of truncation noise is loud next
to a −85 dB floor. Detection survived the swap unchanged, which is worth
knowing, but the fixture should describe the file the test names.

```bash
lua test/headless.lua
```

**In REAPER** — four scripts, run from the Actions list:

- `test/selftest_in_reaper.lua` — drives the EEL kernel on sine waves whose band
  energies and crossing rates are known analytically. Isolates the kernel from
  the accessor and from project state. Run this first if anything looks wrong.
  Note what it cannot see: it computes the band ratios the way the *kernel*
  does, so it stayed green through the DC bug above, which lived in
  `analyze.lua`'s reduction of the same accumulators.
- `test/verify_edit_in_reaper.lua` — runs the full pipeline and checks the read
  geometry and that the edit did not move any audio. Two cases every run: the
  selected item if there is one, on the panel's own settings; and **always** a
  time-stretched fixture at playrate 1.25, built from the repo's own WAV on a
  temporary track that is deleted at the end. The second case is not optional —
  at playrate 1 every quantity in the geometry is the same number, so every
  scaling mistake in it passes. See *Take geometry* below.

  The key assertion on the edit is

  ```
  startoffs − position × playrate   is identical for every resulting item
  ```

  since both sides say where in the source file timeline-zero falls. That is an
  exact, instant check for the mistake the render-null test exists to catch
  (dropping the `D_PLAYRATE` factor).

**Render and null** — the final proof, by hand. Set both strengths to 0 % and
all offsets to 0 dB, apply, render the track, and null against the source. A
correct linear-crossfade reconstruction cancels below −100 dB. This is the only
test that also proves the *fade shapes* reconstruct to unity, which geometry
alone cannot show.

## Notes on the design

Sections and phrases are found by pauses. **Elements are not** — not breaths,
not sibilance, not hard consonants.

### Take geometry: the accessor's timeline is item time

Measured directly on REAPER 7.75, because it was assumed wrongly for as long as
this script existed:

- `GetAudioAccessorEndTime` returns `item_len` at every playrate. On a 4.0 s
  source: playrate 1.0 → 4.0 s, 1.25 → 3.2 s, 0.8 → 5.0 s.
- The audio it returns **already has the playrate, pitch shift and channel mode
  applied**. With `B_PPITCH` off, a 440 Hz source read at playrate 1.25 comes
  back at 550 Hz; with it on, 440 Hz but time-compressed. Mono-L on a stereo
  source returns L in both channels.
- Take `D_VOL`, item `D_VOL` and `D_PAN` are *not* applied.
- Reads are deterministic: the same span read as one block and as strided
  blocks is bit-identical.

Two things follow, and both were wrong, in opposite directions:

**The span to read is `item_len`, not `item_len × playrate`.** The longer span
asks for more audio than the accessor has and gets the item followed by
silence — which reads as a *pause*, so it moves the section and phrase
structure, not merely the tail.

**Frame index → time is `hop / rate`, with no playrate in it,** since frames are
`hop` samples apart in accessor time and accessor time is item time. So the
frame table carries two durations, named for their time base:

| Field | Meaning |
| --- | --- |
| `acc_frame_dur` | `hop / rate` — project (= item = accessor) seconds |
| `src_frame_dur` | `hop / rate × playrate` — source file seconds |

Every duration downstream is a claim about a *sound* — how long a pause has to
be to separate two phrases, how long an `/s/` runs, how far a guard rail reaches
into a gap — and the frames hold audio that is already stretched, so all of them
are project time and all of them use `acc_frame_dur`. Nothing currently wants
`src_frame_dur`; it exists so the next thing that does can reach for the right
one.

The single exception is `D_STARTOFFS` in `apply.lua`, which is measured in the
source file and so *does* scale by the playrate. That one was always right, and
it is right for a different reason than the frame times are — see the comment on
`crossfade`.

At playrate 1 every one of these quantities is the same number, which is why
this survived a full test suite. `test/verify_edit_in_reaper.lua` now always
runs a stretched fixture.

### Sibilance and hard consonants are one scan, split by duration

Two kinds of sound get called a hard consonant, and only one of them has a
burst. Of the nine in the test take, four — at 7.31, 14.98, 17.81 and 21.46 s —
are unvoiced fricative *releases* with no burst at all. The one at 21.46 s
rises 10 dB over 40 ms, so an onset detector wanting 12 dB over 10 ms cannot
see it and no threshold on that detector ever will.

They are found the way an /s/ is found — a high-band core, grown to its
extent — and then separated from one by **length**. On the test take every hard
consonant runs 8–91 ms and every sibilant runs 117–248 ms. That gap is real and
not tuned; `sib_min_ms` sits in it.

The burst scanner stays, for the plosives the fricative scan cannot see: at
2.66, 8.31, 14.25 and 25.54 s the high-band fraction is 0.11–0.35, well under
any sibilance threshold, and a closure 27–42 dB deep is what identifies them
instead. The /s/ in "sister" is contiguous with the
vowels either side and has no gap at all; a plosive closure runs 40–80 ms, well
under `min_silence_ms`, so the gate fills it deliberately, which is what stops
every closure becoming a phrase boundary; and a breath is quieter than the gate
has to be. All three are found by a feature scan over the frames the gate
already produced, and a breath's scan deliberately runs below the gate as well
as above it.

A consonant burst's extent is bounded by *voicing*, not by level: a plosive is
followed immediately by its vowel at much the same level, so a level-based
extent runs into the vowel.

Which makes *where the burst's peak is measured* load-bearing, and it was
measured in the wrong place. The peak was taken over the whole `cons_max_ms`
window ahead of the onset, which reaches into that following vowel: a −47 dB
burst with a −27 dB vowel 20 ms behind it came back with a peak of −27, so
every frame of the burst was already more than `cons_decay_db` below "its own"
peak, the extent never left the first frame, and every candidate then failed
`cons_min_ms`. The same borrowed peak was what the closure test compared
against, which made every closure look 5–15 dB deeper than it was — so
`cons_closure_drop_db` had been calibrated to 15 dB against an inflated number
and is now 10. Three consonants were found in a take with nine.

Two smaller things fell out of the same code. A burst holds the slope up for
several frames, and the scanner tested *each* of them, re-judging one consonant
from steadily worse ground — the second test's closure window is the first
test's burst, so it measures the rise itself. It now takes the whole run of
above-threshold slope as one onset. And the closure window was clamped to the
start of the range being scanned, which is the start of a gate segment: a
phrase-initial plosive bursts out of the pause *before* the phrase, on the
other side of that boundary, leaving a frame or two of the gate's own edge as
the entire closure window.

**A closure is how quiet it got, not whether everything was quiet.** The test
took the *maximum* level over the preceding 40 ms, which asks whether the whole
window was silent — so it failed the moment the window caught the tail of the
previous word, or the burst's own first frame, which sits one frame before the
frame the slope fires on. It now takes the minimum, which is the question a
closure actually answers, and the consonant at 14.25 s went from a measured
5.6 dB closure to its real 42.

**A burst is half-voiced.** `cons_voice_max` was 0.30 and the voiced plosive at
14.25 s means 0.31 across its 43 ms — missed by a hundredth. A vowel onset
reads 0.8–1.2, so 0.45 leaves a wide margin either side. Within the burst the
same estimate flickers frame to frame (0.07, 0.06, 0.09, 0.50, 0.54, 0.50,
0.50, 0.47, 0.20, …), so voiced stretches shorter than `cons_join_ms` are
bridged; walking frame by frame stopped after 11 ms of that 43.

**A fluctuation inside a fricative is not a consonant.** Decaying fricative
noise swings 14 dB frame to frame — the tail of the /s/ at 1.46 s reads −73.8,
−59.4, −73.3, −62.7 — so it clears any onset threshold repeatedly, out of a
"closure" that is only the next dip down. A burst beginning strictly inside a
fricative's extent is dropped: that audio is already accounted for as one
sound. A burst starting *at or before* one is kept, because that is an
affricate and the burst describes where it begins.

### Detection and extent are different questions

Finding a sibilant and knowing where it begins and ends are not the same job,
and conflating them is what made clips shorter than the sound they were cut
for. A frame is unambiguously fricative when the high band dominates it *and*
it sits well clear of the gate — that finds the **core**, reliably, but only
the core. Cut there and the gain step lands inside the /s/, which is heard as a
stutter.

The extent grows outward from the core in both directions. What it must not do
is what it used to: expand while `sib_ratio` stayed above **half its own peak**.
That test is inverted — the purer the fricative, the higher its peak ratio and
so the stricter the bar its own edges have to clear. A textbook /s/ peaking at
0.95 demanded 0.475 at the edges and lost both of them; a duller one peaking at
0.6 only demanded 0.3 and kept more. Being penalised for being cleaner is
backwards, and it truncated the start, the end, or both depending on how the
sound happened to be shaped.

A frame continues the fricative if *either* holds:

- it is still high-band dominated in absolute terms — a fixed fraction of the
  detection threshold (`sib_edge_frac`), never of this sound's own peak. This
  is what follows an /s/ down into a pause, where the level falls away but the
  spectrum stays fricative.
- its high-band energy is still within `sib_extend_db` of the core's peak. This
  is what follows it into a neighbouring vowel, where the ratio collapses while
  real fricative energy is still present.

Voicing stops the growth (a vowel is where the fricative ends by definition,
and the envelope arm would otherwise run straight into it), so does the gate,
and so does `sib_max_ms` — as a clamp, not a rejection: an /s/ that grows past
the limit is still an /s/, so it is trimmed rather than thrown away. A clash
with a detected consonant trims the extent too, and only kills it if the core
itself is taken.

`test/headless.lua` checks this against a fixture whose sibilants have soft
onsets and decaying tails, asserting the clip covers the whole sound, that it
grew past the core in both directions, and that the core alone would have been
short.

### One signal, one DC decision

`voice_ratio` and `sib_ratio` are *fractions* of a frame's energy, and on real
material 60 % of frames came back with `voice_ratio` above 1.

DC was being removed in two places at once and only on one side of the ratio.
The kernel accumulated the band energies from the raw signal, while
`analyze.lua` subtracted a per-frame mean from the total. At a 2.7 ms frame,
subtracting the mean is a high-pass that reaches up past 150 Hz — so it took a
male fundamental out of the denominator while the voicing band kept it. Every
voicing test downstream was reading a number that could not mean what it said:
the gate's voiced-frame reference, `voice_thresh`, `breath_voice_max`,
`cons_voice_max`, and the voicing stop on the sibilance extent.

DC is now blocked once, by a 20 Hz one-pole in the kernel, ahead of every
accumulator. The kernel self-test passed throughout — it computes the ratio
from the raw sums, exactly as the kernel does, so the disagreement lived
entirely in the seam between two stages that each had passing tests.

### Breaths are scanned, not classified out of gate segments

Breath detection used to ask "is this gate segment a breath?". For that to work
the gate has to resolve a breath as a segment of its own, and it cannot. A
breath stands 5–12 dB above room tone; the gate has to sit 12–15 dB above room
tone to keep the room out of the phrases. The breath is on the wrong side of it.

On a 32 s test take containing four breaths, the gate cut one down to 93 ms of
its 275 (so it failed `breath_min_ms`), let two be swallowed by the tail of the
phrase they followed (so they were never segments at all), and left the
quietest entirely below the gate inside a 900 ms pause (so it did not exist).
The panel honestly reported "0 candidates" and no slider could change it,
because nothing downstream of the gate could recover any of that.

Requiring a gate-produced segment here fails in exactly the way requiring a
gate-produced gap would fail for plosives — which is already the stated reason
consonants are scanned. Breaths now get the same treatment: frame features,
across the whole take, above and below the gate alike.

The per-frame tests are absolute, because a frame failing one is not part of a
breath under any tuning:

- it is unvoiced;
- its high band sits **inside** the breath band, bounded both ways;
- it stands `breath_floor_db` clear of the **local** room tone, while staying
  below the singing around it.

Runs of such frames are joined across short dropouts (a breath is noise, and
noise crosses any per-frame test back and forth — without joining, one breath
arrives as five fragments, each too short to be one), filtered by duration, and
then *scored* on the two features that really are matters of degree — how far
below the singing it sits, and whether anything bursts inside it. Their average
must clear one **Sensitivity** control.

Bounding the high band on both sides, and hard, is the one place this departs
from "score it, don't AND it", and it earns the exception. A breath is unvoiced
but not fricative, and those are two edges of one category rather than two
opinions about it: room tone carries almost no high band, a breath runs
0.15–0.25, an /s/ runs 0.5–0.85. Graded, it could not do that job — a textbook
/s/ scored 0 for HF content and still came through at 0.67, because averaging a
zero with two ones cannot express "this is categorically something else". Six of
the eight breaths found that way on the test take were sibilants.

The panel shows the funnel — runs → candidates → taken — and names the feature
holding rejections back and how far Sensitivity would have to move to take the
best one. When no run forms at all, it says so, and points at the HF band and
the room-tone margin rather than at Sensitivity, which cannot reach that case.

#### The clip has to hold the whole breath

The same core-and-extent split the fricatives use, for the same reason and
after the same bug. The per-frame tests that say "this is definitely a breath"
are not the tests that say "the breath is still going": a breath fades up out
of the room and back down into it, and at both ends its high-band fraction
drops below `breath_sib_lo` while the sound is plainly still there. The breath
at 21.94 s in the test take runs 21.65–22.25 and only 21.94–22.24 of it passes
the core test — so the clip covered half the sound and stepped the gain inside
it.

The extent reads **smoothed** features, and that is the whole trick. Down that
breath's tail `sib_ratio` reads 0.112, 0.068, 0.046, 0.056, 0.082, 0.034,
0.204, 0.050, 0.038, 0.104 frame by frame; any per-frame threshold is crossed
back and forth every few frames, so a walk that stops at the first failing
frame stops within 10 ms of the core. Over 16 ms the same stretch is a steady
0.06–0.09.

Smoothing rather than bridging over gaps, because the two ends have to fail
differently — HF fading into the room is a soft edge to follow, the singing
coming back is a wall — and a miss-counting bridge cannot tell them apart. It
walks straight back into the phrase tail.

Then both ends snap to the **bottom of the valley** beside them. A breath is a
smooth ramp up out of one pause and back down into the next, so that is where
it really begins and ends — and it is also the quietest place to cut, which is
where `place_cut` would have put a cut anyway. Growing by feature test alone
still left every clip 4–12 dB up the slope: 40–80 ms short at the head, 24–136
at the tail. A gain step placed on a slope is exactly where it can be heard.

The walk out to the floor is a running minimum, and two details decide whether
it gets there. It gives up only on a climb that is **sustained** past the
smoothing window — even at 16 ms the level spikes more than 3 dB frame to frame
down at −65 dB, and stopping at the first rise stopped 45 ms short of a floor it
was heading straight for. And voicing is deliberately *not* one of its stops,
though it bounds the growth above: this walk goes downhill by construction, and
the bottom of a valley after a sung note is the tail of that note — low
frequency decay, so `voice_ratio` reads 0.7–1.2 at −70 dB. Stopping on it fires
on the decay of the singing rather than on the singing, and the level test is
what actually says the singing is back.

Whether something *is* a breath is still settled on the core, and only then is
the clip grown. Deciding on the extent instead let an 8 ms core — three
shoulder frames of the fricative consonant at 21.46 s, whose body is far too
high-band to be a breath — grow across the whole consonant and clear
`breath_min_ms` at 99 ms.

A fricative's extent stops at the **room**, not at the gate, for the same
reason: an /s/ decaying out of a word runs well below a gate that has to sit
high enough to keep room tone out of the phrases, and it is still unmistakably
the /s/. At 1.61–1.66 s the level is −70 dB while `sib_ratio` is still
0.5–0.86. Stopping at the gate cut that clip at 1.603 and left the rest of the
fricative to be re-detected as a separate 19 ms element.

#### What a breath is quiet *against*

The reference is measured locally: voiced-frame RMS over roughly two seconds
either side, widened automatically when that window holds no singing. It is
deliberately **not** the level of the phrase node the breath sits in.

When the gate does happen to isolate a breath, that breath becomes a segment,
the segment becomes a phrase, and the phrase's reference level is then the
level of the breath itself. Asking whether it sits 6 dB below that is asking
whether it is 6 dB below itself, and the answer is always no. That silently
cost the one breath the gate had managed to isolate.

The sibilance threshold sits at half the strongest fricative in the file rather
than at a percentile. `sib_ratio` is bimodal, so a percentile lands wherever the
sibilance *fraction* happens to fall — at a realistic ~9 % the 92nd percentile
sits on top of the sibilant lobe and nothing clears it.

### Structural cuts are placed last, around the elements

Cut placement guarantees "one cut per silence, never inside usable audio" by
construction: cuts are derived from the gap list once, so a gap that separates
two sections also separates two phrases but still gets exactly one cut; and the
crossfade is clamped to twice the distance from the cut to the nearer edge of
the guarded safe zone, which is the correct clamp precisely because the fade is
centred on the cut.

What that guarantee needs is for the elements to exist first. Section and
phrase cuts used to be placed from the gap list before anything was detected,
and any that landed inside an element were then *dropped* — which deletes the
boundary rather than moving it. On the test take that lost three of seven,
including the section boundary in the 899 ms pause at 21.5 s.

It got worse once breath clips reached their valley floors, and necessarily so:
a valley floor is the quietest point in a pause, which is exactly the point
`place_cut` was choosing. The two rules were competing for the same frame.

So the quietest frame is now chosen from what is left of the safe zone once the
elements are taken out of it. And when an element covers the whole zone the
boundary is not lost either — the element's own edges are already cuts and
already at valley floors, so the pause adopts the nearer one rather than a
second cut being added a few frames away.

Two assertions in `test/detection.lua` hold this down: every pause long enough
to separate two phrases ends up with a boundary, and no structural cut lands
inside a detected element.

### A span must outlast its own crossfades

Placing the structural cuts around the elements introduced a new way to fail,
and it is worth stating as its own rule because the symptom was spectacular and
the cause is one line of arithmetic.

A crossfade eats half its length off either side of its cut, so a span has to
be at least `(cf_in + cf_out) / 2` long. Cuts used to be thinned against a
constant — twice `crossfade_min_ms`, 4 ms — which says nothing about the fades
that actually meet there. With the breath ending at 5.107 s and a structural
cut landing at 5.112, the span between them was 5.3 ms with a 5 ms fade on one
side and a **20 ms** fade on the other.

REAPER expresses a crossfade by moving the right-hand item earlier. A fade
longer than the item to its left therefore moves that item's neighbour *past*
it, the timeline stops being ordered, and what came out was a 2.2 second hole
in the middle of the take.

Two things prevent it. A gap cut that falls within a crossfade of an element
edge **adopts that edge** instead of adding a second cut beside it. And the
thinning rule in `spans` is now the real one — `max(floor, (cf_in + cf_out) /
2)` — as a backstop, so no span can be shorter than its own fades however the
cuts arose. Where two cuts do collide, the element edge wins: the edge of a
breath or an /s/ has to be exact or the clip's gain runs into the audio either
side, while a cut in a pause only has to be somewhere quiet, and the element
edge already is.

## Known limits

- Operates on the first selected item. Multi-item is a loop over the same
  pipeline, not yet wired up.
- No LUFS reference mode; levels are RMS.
- The analysis cache lives for the session only.
- Settings are versioned (`Config.VERSION`). When a stored key changes what it
  *means* rather than what its default is, the migration list drops it back to
  the default and the panel says which keys it reset. Without that, an ExtState
  value saved under the old meaning silently outranks the new default —
  `breath_sib_hi = 0`, a harmless way of saying "score HF content generously"
  under the graded rule, rejects every frame in the take under the absolute
  one.
