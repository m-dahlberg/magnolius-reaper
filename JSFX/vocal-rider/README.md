# Vocal Rider (JSFX)

A vocal rider for REAPER. It continuously measures the vocal's loudness and
smoothly rides its gain toward a target level, which is gentler and more
transparent than a compressor. Optionally it listens to a sidechain (the
instrumental) and pushes the vocal target up when the music gets loud.

The target can be automated. The **Loudness Envelope** script
(`Scripts/loudness-envelop`) writes a phrase-level Target lane. The macro
dynamics then come from that lane, and the rider only has to bring the vocal
onto it smoothly.

## Install

```bash
ln -s "$PWD/Magnolius_VocalRider.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/Magnolius_VocalRider.jsfx
```

Symlink it, never copy it: a copy goes stale silently. Then in REAPER, add FX
on the vocal track and search **vocal rider** (it is listed under JS). After
editing the file, reopen the FX (or press Ctrl+S in REAPER's JS editor) to
reload. The panel shows the version (v2.3) in its top-right corner.

## Sliders

| Slider | What it does |
|---|---|
| Target level | The loudness the rider steers the vocal toward. Automate it, or let Loudness Envelope write it. |
| Max boost | The most the rider may raise the vocal, in dB. (This was *Ride range* before 2.0. An older project keeps its value here.) |
| Ride speed | How quickly the gain moves. Lower follows word by word; higher follows phrase by phrase. Cuts react slightly faster than boosts, to avoid pumping. |
| Noise floor | Below this input level the rider stops riding and **holds** its gain (see *Gaps*). |
| Sidechain influence | How many dB the target is raised when the sidechain is loud. The full amount applies when the music is 12 dB above the target. 0 = off. |
| Vocal loudness window | RMS measurement window for the vocal. Shorter is snappier, longer is smoother. Loudness Envelope measures with the same window. |
| Sidechain loudness window | RMS measurement window for the sidechain. |
| Output trim | Static make-up gain after the rider. |
| Max cut | The most the rider may lower the vocal, in dB. It is set independently of Max boost. |
| Correction amount | How much of the distance to the target is corrected. 100 % lands on the target; 50 % goes halfway, so the vocal keeps half of its own phrase dynamics around the target. |
| Breath guard | What happens to a breath. In every mode except Off, a breath gets no say in the gain. **Freeze** (default): the gain stays at the value it had when the breath began, so the breath keeps the gain of the note before it. **No boost**: if that gain was a boost, the breath is left at 0 dB; if it was a cut, the breath is frozen as in Freeze. Use No boost when the rider lifts the ends of long notes and the breaths after them come out too loud. Neither mode turns a breath down below 0 dB; this is not a de-breather. |
| Breath threshold | How noise-like a quiet frame must be to count as a breath: its energy above 3 kHz minus its energy below 1.5 kHz, in dB. Lower catches more. The default −8 dB was tuned on a real take, where sung frames sit at −11 to −26 dB and breaths at −3 to +5 dB. Watch the BREATH light while you set it. |
| Tail lift | How much the rider may raise the gain while the vocal's level is **falling**: the end of a long note, or the softer last words of a phrase. 100 % (default) lifts them like any other quiet part. 0 % leaves those fades as sung, at the gain the note body had. 50 % gives about half the lift. Cuts are unaffected, and so is a quieter note once its level stops falling. |
| Lookahead | Delays the audio by this much and reports it to REAPER as latency (PDC), so the gain moves *before* a loud word instead of after it. This is a set-and-forget control: changing it re-syncs the track. 0 = no latency. |

Parameters 1, 4 and 6 (Target, Noise floor, Vocal loudness window) keep their
numbers, because Loudness Envelope automates the first and reads the other two.

## How it rides

1. **Detector.** The louder channel's energy goes through a one-pole of the
   Vocal loudness window, read in dB. This is the same detector Loudness
   Envelope measures with, so the lane and the rider use the same units.
2. **Correction.** `Amount × (target − level)`, clamped to −Max cut … +Max boost.
3. **Level weighting.** Not every frame gets the same vote:
   * A frame within 6 dB of the current phrase level votes fully. That level
     is a peak follower with instant attack and a 0.5 s release. Frames 6–12 dB
     below it are faded out, and anything further down gets no vote. Consonants,
     breaths and quiet tails therefore don't pull the gain up.
   * A frame whose level is **falling** fast is faded out: the release of a
     phrase. At the default 50 ms window, a frame falling faster than 30 dB/s
     starts to lose its vote, and one falling at 60 dB/s or more gets none. Both
     thresholds scale with 50 / window, because a longer window also decays
     more slowly. With a 300 ms window they are 5 and 10 dB/s. Without this
     rule, every phrase end pushes the gain toward a boost, and the breath and
     the next phrase come out too loud. (In 2.0 the thresholds were fixed, so
     with a long window the rule never fired.)

   The phrase level follows the take itself, so a take that sits 12 dB under
   the target still climbs at full speed.
   * A **breath** gets no vote and does not move the phrase level (see 7).
   * **Tail lift.** If a frame would move the gain *up* while the level is
     falling, its vote is scaled down by the slider. A frame counts as fully
     falling at 20 % of the fast-fall threshold: 6 dB/s at a 50 ms window,
     1 dB/s at 300 ms. Below that it counts in proportion. The slider is
     applied as (Tail lift)^2.5, so that 50 % gives about half the lift. A
     fade only slows the gain down, and a slowed gain catches up over a long
     fade, so a plain percentage would give 50 % only a fifth of the effect.
     Rising and steady frames are untouched. A quieter next note is
     therefore still brought up once its level settles: on the test case it
     ends 0.1 dB below the 100 % result.
4. **Two-pole smoother.** Two one-poles in series, each with half the Ride
   speed. They give the same overall speed as a single one-pole, but the gain
   has no corner where a word starts.
5. **Gaps.** The gate opens above the Noise floor. It closes only after the
   level has stayed 3 dB below the floor for 150 ms. While it is closed the
   gain is **held**, so a phrase starts where the last one ended instead of
   swelling in from 0 dB. After 2 s of continuous gap, a *boost* releases
   toward 0 dB with a 1 s time constant, so long pauses don't lift room noise.
   A cut is held indefinitely.
6. **Lookahead.** The detector reads the undelayed input, and the gain lands
   on the audio Lookahead ms later.
7. **Breath guard.** Two Butterworth filters split the input at 1.5 kHz and
   3 kHz, and their energies are smoothed over 10 ms. A frame is a breath when
   both of these hold:
   * its high-band energy exceeds its low-band energy by more than Breath
     threshold;
   * it is more than 12 dB under the phrase level, measured on a 10 ms window
     of its own, so this does not depend on the Vocal loudness window.

   The second test keeps a sibilant inside a word from counting as a breath.
   The breath flag travels through the lookahead delay with the audio. On the
   output, the gain is capped during the breath; it may fall but not rise:
   * **Freeze** caps it at the gain the breath began with.
   * **No boost** caps it at the lower of that gain and 0 dB. A breath after a
     boosted note is left at unity, and one after a cut is frozen.

   The cap engages over 10 ms and lets go over 50 ms. It starts 20 ms early
   when Lookahead allows, so the ramp lands in the last of the note's tail and
   not in the breath. Breaths that sit under the
   Noise floor are held by the gate anyway; the guard matters for the ones
   above it. With a long window, that is most of them.

## Riding a Target lane

Recommended settings when the lane comes from Loudness Envelope:

* **Correction amount 100 %** to land on the lane; lower it to keep some of
  the take's own phrasing.
* **Ride speed** 200–400 ms. The lane carries the phrase shape, so the rider
  only has to even out the gaps between the take and the lane.
* **Lookahead** about half the Ride speed (100–200 ms) for mixing. Leave it at 0
  while tracking.
* **Max boost / Max cut** of at least the level difference between the two
  takes plus your desired ride: the curve is the source take's absolute level.

**Lookahead does not apply to automation.** Measured on REAPER 7: with a
200 ms lookahead, a Target step lands in the output at the same time as
without it, plus about one block. REAPER plays the lane on the output
timeline while the detector reads audio Lookahead ms ahead. So the lane is
compared with audio that is Lookahead ms later than the lane intends. The
lane is smoothed over seconds, so 100–200 ms makes little difference. Keep
Lookahead well under the lane's smoothing if it matters.

**Weighting bias.** Fast-falling frames don't vote. On material with very deep
syllable modulation (7 dB swings in the 50 ms detector), the rider therefore
settles about 0.5–1 dB below the median that Loudness Envelope writes. On
ordinary material it is a few tenths of a dB. Use the script's **Offset** if
you hear it.

**Tail lift, measured.** The same take has 17 long notes whose last 0.3 s
fades more than 2 dB. Their ends are lifted, on average, this much above the
note body:

| Tail lift | 100 % | 75 % | 50 % | 25 % | 0 % |
|---|---|---|---|---|---|
| End-of-note lift | +0.66 dB | +0.49 | +0.26 | +0.04 | −0.03 |

At 0 % the median sung frame moves −0.09 dB, so the rest of the singing is
left alone. The frames that move most, by up to 3 dB, are the lifted note
endings themselves. A note end that is lifted less also leaves less boost
for the breath after it, so Breath guard No boost has less to do.

Two other designs were tried and dropped:
* **A note level that resets on each new note.** It controlled real fades,
  but the softer last words of a phrase each looked like a new note, so it
  removed only half the lift.
* **A note level that only resets after a gap.** It pulled all the singing
  down by 0.5 dB on average and up to 3 dB.

**Breaths, measured.** A 250 s take with 40 breaths, at Target −24.1, Noise
floor −28, a 300 ms window, Amount 58 % and 200 ms Lookahead. In 2.0 the median
breath came out 1.2 dB above the phrase before it, 31 breaths were over 1 dB
and the worst was +3.6 dB. In 2.1 the median is +0.1 dB, none is over 1 dB,
and the worst is +0.95 dB. With **No boost** in 2.2, a breath after a boosted
note sits at +0.0 dB; the most measured inside any breath is +0.12 dB, where
the guard's release starts. The 20 ms ramps at the edges reach up to +0.8 dB,
at −53 to −65 dB levels. The sung frames are unchanged (median difference
0.00 dB), except right after a breath: there a phrase used to start up to
about 2 dB hot, and now it starts where the last one ended.

## Sidechain hookup

1. On the vocal track: FX button → click the **2 in 2 out** button (pin connector) on the plugin → set track channels to 4.
2. On the instrumental track/bus: add a **send** to the vocal track, destination channels **3/4**.
3. In the plugin's pin connector, make sure input pins *Sidechain L/R* map to channels 3/4.
4. Raise **Sidechain influence** above 0.

The sidechain is analysis-only; it is never mixed into the output.

## Meter

- The **top line** shows the current Target (it moves with the lane), the
  Amount, and the Lookahead when one is set.
- **IN** shows the vocal input level (blue), with the target (yellow tick) and
  the noise floor (grey tick).
- **RIDE** shows the current gain. The left half spans Max cut and the right
  half spans Max boost. Green right of center is a boost, orange left of center
  is a cut. While the gate holds, the bar is dimmed grey and the label reads
  **HOLD**. **BREATH** lights above the bar while the breath guard is
  holding down the gain.

## Quick sanity checks by ear

- **Amount at 0 %:** the plugin is transparent; at any Lookahead it only
  delays, and REAPER compensates that.
- **A held note under the target:** the RIDE bar climbs smoothly to the
  difference and stops at Max boost.
- **A pause between phrases:** the label reads HOLD and the bar stays put. The
  next phrase starts at the same gain.

## Files

| Path | Role |
|---|---|
| `Magnolius_VocalRider.jsfx` | The plugin. |
| `tools/model.py` | Pure-Python reference that mirrors the DSP sample for sample. **Edit together with the .jsfx.** |
| `tools/render_test.py` | Headless REAPER render tests (`render_test.py`, or named: `render_test.py hold lane_step`). |
| `tools/render_harness.py`, `tools/wavio.py` | Shared render scaffold. |

## Tests

```bash
python3 tools/render_test.py
```

Renders run through `reaper -newinst`, so they are safe while REAPER is open.
The work dir is `~/.cache/vocal-rider-rendertest` (`VR_WORK` overrides it).

| Test | Proves |
|---|---|
| `params` | All 14 sliders parse, and parameters 0/3/5 are still Target / Noise floor / Vocal loudness window. |
| `model` | The render matches `model.py` to 3e-8 on phrase-like material with gaps, at the defaults and with Amount, both limits, Lookahead and trim moved. |
| `canary`, `srate` | A −24 dB tone with target −18 gets +6.00 dB at 44.1, 48 and 96 kHz. |
| `amount` | 50 % gives +3.00 dB. |
| `limits` | Max boost 4 caps at +4.00 and Max cut 2 caps at −2.00, independently. |
| `hold` | After a 1 s gap the gain is within 0.05 dB of where the phrase left it. |
| `release` | After a 4.5 s gap a +8 dB boost has released to about +1 dB, and a −6 dB cut is still −6 dB. |
| `weighting` | A 0.3 s dip 15 dB under the phrase moves the gain +0.2 dB (+4.6 unweighted); a 4 dB dip moves it at full rate. |
| `breath` | A 1.5 s breath above the gate, with 200 ms Lookahead and a 300 ms window. With the guard off, the breath's gain rises over 2 dB above the phrase. After a +6 dB phrase, Freeze holds the breath at +6.01 and No boost puts it at +0.00. After a −6 dB phrase, both modes freeze it at −6.00. The render matches the model. |
| `sibilant` | A noise burst at phrase level inside a phrase is not a breath: the output with the guard on and off is bit-identical. |
| `userfile` | The take in `Test files/` at the settings above, in both modes. Freeze: no breath more than 1 dB over its phrase. No boost: the same after a cut; after a boost, at most +0.25 dB inside a breath (+0.12 measured), with the 20 ms edge ramps reported separately. It is skipped when the file is absent, and the file is gitignored. |
| `tail` | A long note fading 9 dB, at the take's settings. The fade lifts +2.96 / +1.40 / −0.04 dB at Tail lift 100 / 50 / 0 %. A steady note 5 dB quieter after a louder one gets within 0.1 dB of the same gain at 0 % and 100 %, and a steady tone still lands on +6.00. The render matches the model. |
| `userfile_tail` | On the take with No boost: the fading-note end lift is +0.66 dB at 100 % and −0.03 at 0 %, with the median sung frame within 0.1 dB. |
| `lookahead_null` | With 200 ms lookahead and Amount 0, the output is bit-identical to the input: the real latency equals the reported latency. |
| `lane_step` | Measures where a Target automation step lands, with and without lookahead (see above). |

The render tests can't check the panel, because @gfx doesn't run in an
offline render.
