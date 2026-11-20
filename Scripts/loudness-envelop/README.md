# Loudness Envelope (ReaScript)

Measures how loud a vocal track is singing **phrase by phrase** and writes that
outline as **Target level** automation for the **Vocal Rider (Magnolius)** on
another track.

The case it was built for: two takes of the same melody in different
languages. The rider on the second take aims at the first take's phrasing:
where the first take lifts into a chorus, so does the target. The syllables
are left out of the curve, because they fall in different places in the other
language. A dip for a consonant in the source would tell the rider to pull
down a vowel in the destination.

## Install

Requires **ReaImGui** (ReaPack). It is used for the panel *and* for the
measurement kernel, via `CreateFunctionFromEEL`.

```bash
ln -sfn "$PWD" ~/.config/REAPER/Scripts/LoudnessEnvelope
```

Then add `Magnolius_LoudnessEnvelope.lua` in Actions → Show action list → New
action → Load ReaScript.

## Use

1. Put a **Vocal Rider** on the destination track.
2. Select the **source** track (the take whose phrasing you want) and press
   **Analyse**. The script reads every audio item on that track. With
   **Limit to time selection** on, it reads only what is inside the time
   selection.
3. Look at the plot. The level is drawn in blue where the source is singing
   and in grey where the gate threw it out. The thin grey line is the outline.
   The orange line is the curve that will be written.
4. Pick the **Destination** track and press **Write**. The curve becomes the
   rider's *Target level* lane. A second Write replaces only the span it
   covers.

Every control except the source recomputes the curve while you drag, without
re-reading audio. The panel marks the one control that needs another Analyse.

### The controls

* **Measurement**: the rider's own detector.
  * **Detector window** is the rider's *Vocal loudness window* (50 ms).
  * **Gate** is its *Noise floor* (−50 dB).
  * **Relative gate** additionally drops anything that far under the take's
    typical sung level, which removes breaths and reverb tails in a loud room.
  * **Match the destination rider** copies the first two from the rider on the
    destination track. Use it if you have moved the rider's sliders, because
    the target has to be in the same units as the rider's detector.
* **Outline**: what makes the curve follow phrases and not syllables.
  * **Outline window** is the width of a sliding median over the singing
    frames. Raise it if syllables still show through; lower it to follow
    shorter phrases.
  * **Smoothing** is the σ of a zero-phase Gaussian after it.
* **Range**:
  * **Depth** scales the curve's movement around its own median: 100 % is as
    measured, 50 % is half the movement, 0 % is a flat line.
  * **Range** caps how far the curve may go from that median, in either
    direction.
  * **Offset** shifts the whole curve.
* **Output**:
  * **Destination** is the track to write to. It is remembered by GUID, with
    the name as a fallback.
  * **Point tolerance** is how far the written envelope may stray from the
    computed curve.

### Absolute level, and Offset

The curve is the source's **absolute** level in the rider's units. If the
destination take was recorded 4 dB hotter, the rider spends 4 dB of its
**Max cut** pulling it down before it rides anything (a quieter take spends
**Max boost**). Raise the limit, or use **Offset**.

Offset is also the fix when the destination's chain differs. The rider
compares its target with its **input**: the signal at its own position in the
FX chain. The source is measured as raw take audio. Any gain or compression
ahead of the rider on the destination moves the level that target is
compared against.

## How the curve is made

`le/curve.lua`, every stage a plain function:

1. **Detector.** The kernel reduces the take to 10 ms frames of `max(L², R²)`,
   the louder channel per sample. That is exactly what the rider squares.
   Lua then runs the rider's one-pole over those frames, so the curve is in
   the units the rider will compare it with. Take volume and item volume are
   folded in, because the rider hears them and the accessor does not apply
   them.
2. **Gate.** Frames below the gate, or more than the relative gate below the
   take's sung level, get no vote. Without this, every pause drags the curve
   toward silence.
3. **Outline.** A sliding **median** of the frames that are left. A median does
   not move for a burst or a dip that fills less than half its window. A
   follower of any time constant cannot do this: one slow enough to ignore
   syllables lags each phrase by that same time constant.
4. **Smoothing.** A zero-phase Gaussian, done as normalised convolution
   weighted by how much of each window was singing. A gap contributes nothing,
   rather than contributing silence.
5. **Gaps.** What is still empty becomes a straight line from one phrase's
   level to the next, and the ends hold. The curve never dips between phrases.
   The rider is gated there anyway.
6. **Shape.** Depth and range are applied around the curve's median over the
   sung points. Then offset, then a clamp to the rider's −40..0 dB.
7. **Simplify.** Ramer–Douglas–Peucker, with the error measured vertically, in
   dB at the same instant. A three-minute take writes tens of points.

## Notes on the design

**A JSFX parameter envelope stores the slider's own units.** Measured on 7.75:
a point written as −18 *is* −18 dB, and the lane interpolates linearly in dB.
This is not true of a volume envelope. It is also why the simplification can
be judged in dB.

**A fresh lane is not empty.** `GetFXEnvelope(…, create=true)` seeds one point
at time 0, holding the slider's current value. If it were left there, the
target would ramp from that value at the top of the song to the first real
point. So a lane this script created is emptied first. A lane that already
existed belongs to the user, and only the written span is cleared.

**`DeleteEnvelopePointRange` will not delete an envelope's last point.** It
returns true and leaves the point there. That is how the seeded point at 0
survived the first version of the write, and a lone user point inside the span
would survive the same way. Points are deleted by index with
`DeleteEnvelopePointEx`, back to front.

**A job never reads its own audio.** `GetAudioAccessorSamples` returns nil and
reads nothing from inside a Lua coroutine. A job that read its own audio would
measure silence, and the curve for silence is a perfectly plausible flat line.
So the job yields a read request and the panel services it on the main thread.
An unserviced request is a hard error.

**The take accessor's timeline is take time.** It spans `0 .. item length`,
with playrate already applied. Adding the item position gives project time,
with no playrate factor anywhere. The verify suite checks this at playrate
1.25, on an item that does not start at 0.

**A stretched take does not measure the same as an unstretched one, and should
not.** Its syllables are shorter, and the rider's 50 ms detector rises less on
a shorter vowel. On the fixture that is about half a dB. With preserve-pitch
on (REAPER's default for new takes), the stretch algorithm also smears the
syllable steps, and the mean energy drops by another two thirds of a dB. Both
effects are real, and a rider on that track would hear them too. The test
therefore compares the pipeline against a pure-Lua model of the stretched
signal, not against the unstretched take.

## Layout

| Path | Role |
| --- | --- |
| `Magnolius_LoudnessEnvelope.lua` | entry action: the panel |
| `le/config.lua` | defaults, ExtState, parameter-class signatures |
| `le/kernel.lua` | owns the EEL memory map; nothing above it knows an address |
| `le/dsp/energy.eel` | per-frame louder-channel energy on a time-defined grid |
| `le/source.lua` | which items are read: the selected track, optionally the time selection |
| `le/analyze.lua` | the accessor edge: clip in, frame energies out |
| `le/curve.lua` | pure: frames → detector → gate → outline → smooth → fill → shape → points |
| `le/trackpick.lua` | the destination picker, a verbatim copy of `note-leveling/nl/trackpick.lua` |
| `le/apply.lua` | the only file that touches the project |
| `le/ui.lua` | the ReaImGui panel |
| `test/wav.lua` | float WAV writer, used only to build a fixture |
| `test/ui_frame.lua` | one panel frame against a stub ImGui |
| `tools/run_panel_test.py` | runs `panel_in_reaper.lua` and waits for its result |

## Tests

There is no system `lua` on this machine. The suites run inside the
already-running REAPER, one at a time.

```bash
python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py \
  test/headless.lua test/selftest_in_reaper.lua \
  test/verify_edit_in_reaper.lua --timeout 300
python3 tools/run_panel_test.py
```

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `headless.lua` | **The job, at the shipped defaults:** on a phrase with syllable movement, the curve moves 0.02 dB while the detector moves 8 dB, and a 6 dB phrase-to-phrase step comes through as 6.0. No dip in gaps, the lead-in holds, the level is the phrase's median in the rider's units. Then each stage on its own. A source scan checks that every control's key exists and every setting has a control. | anything in EEL; anything touching the project |
| `selftest_in_reaper.lua` | The kernel on signals with paper answers: a sine's `A²/2`; **quadrature stereo**, where the per-sample louder channel, the per-channel mean and the channel sum all give different numbers; a fractional hop at 44056 Hz that must not drift. The panel against a stub, empty and populated, quiet and with every control moved. | that the panel *looks* right |
| `verify_edit_in_reaper.lua` | The whole path: fixture WAV → item at 3.0 s → accessor → kernel → curve → Target lane → `Envelope_Evaluate` → undo, at playrate 1.0 **and** 1.25. The pipeline agrees with the pure path to 0.1 dB (0.15 dB stretched). Take and item volume are folded in, and a polarity flip is ignored. The time selection limits the span. A fresh lane holds exactly the curve. User points outside the span survive a second write; one inside it is replaced. Undo takes back the write and only the write. | that the rider *responds* to the lane during playback |
| `panel_in_reaper.lua` | the panel through the real ReaImGui, ten frames, with the controls column toggled | the same |

`verify_edit_in_reaper` builds its fixture on **two tracks added at the end of
whatever project is open**, and deletes them afterwards, even if the body
crashes. It never edits your tracks, items or selection. It borrows the time
selection and puts it back. Every fixture edit is committed in an undo block
of its own: an edit made outside a block is folded into the next block that
closes, and the undo assertion would otherwise take the fixture with it.

## Known limits

* The source is the **first selected track**, and every audio item on it. MIDI
  items are skipped.
* Overlapping items on the source track are summed in energy, which is how
  they play.
* The source is measured as **raw take audio** with take FX, take volume and
  item volume applied, and track FX not applied. Item fades are ignored.
* The rider is found by name ("Vocal Rider"), and its parameter 1 must be
  called *Target*. Otherwise the write is refused rather than automating the
  wrong control. Only the first Vocal Rider on the destination is written.
* The takes are assumed to share the song's timeline. Small phrase-timing
  differences between the languages are absorbed by the smoothing. There is no
  time-shift control.
* With the destination track in Touch, Write or Latch mode, playback will
  overwrite the lane. The panel warns, and does not refuse.
* The plot has no zoom. Hover it to read the level and target at a point.
