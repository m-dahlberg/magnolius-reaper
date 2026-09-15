# Vocal Normalizer

Normalises vocal clips to a target loudness measured **through the frequency
range the melody's fundamentals occupy**, instead of across the whole spectrum.

## The problem

Ordinary LUFS normalisation is K-weighted: BS.1770 puts a +4 dB shelf above
~1.5 kHz on top of a measurement that already counts every joule in the signal.
So a bright, close, sibilant vocal **measures** several dB hotter than a soft
one singing the same line at the same perceived level — and a normalizer then
turns the bright one down by exactly that difference. Two takes that measure
identically end up sounding nothing alike, and the bright one always ends up
the quieter of the two.

The fix is not to abandon the standard, because the part of BS.1770 that is
right is the **gating** — 400 ms blocks, an absolute floor and a relative gate
10 LU down, which is what lets a take with breaths and pauses in it be measured
at all. The part that misjudges a voice is the **weighting**. So this script
keeps the gating exactly and replaces the weighting with a band:

```
        LUFS:   [ RLB high-pass 38 Hz ] -> [ +4 dB shelf @ 1.5 kHz ] -> gate
   this script: [ Butterworth 100 Hz  ] -> [ Butterworth 1 kHz     ] -> gate
```

100–1000 Hz spans the sung fundamental range of essentially every voice — G2
(98 Hz) at the bottom of a bass, C6 (1047 Hz) at the top of a soprano — while
excluding the rumble, proximity boom and handling noise below it and the
consonants, breath and air above it. At the default 24 dB/octave, a full-scale
6 kHz sibilant measures below −50 dB and a full-scale 40 Hz rumble below
−30 dB: neither can move the answer.

The panel shows the take's **ordinary LUFS alongside the band measurement, and
the gap between them, per clip**. That gap is the bias, measured. A bright take
shows a bigger one than a dark take at the same LUFS, and that difference is
precisely what plain LUFS normalisation would have charged the bright take for.

## What it writes

One number per clip: **take volume** (`D_VOL`), or item volume on request.
Nothing is rendered, no audio is written, no envelope is touched. A pass is one
undo, and the original take is untouched underneath it.

Because the accessor applies neither take nor item volume, the measurement is
of the raw file and the existing volume is folded back in — which makes the
reported gain a **move** rather than an absolute setting. Normalising an
already-normalised clip therefore asks for 0.00 dB, and the two volume controls
multiply correctly: writing take volume on a clip whose item volume sits at
−6 dB accounts for the −6.

## Using it

1. Select the vocal clips.
2. **Analyse.** The reads are the only expensive part, and they are cached.
3. Set the band. The presets are a starting point; narrow it toward the
   singer's actual register when you know it.
4. Set the target — most usefully with **"Target from this clip"** on a vocal
   you are already happy with. The target is in the band's own scale, not in
   LUFS, for a reason worth stating: a band measurement discards energy, so it
   always reads lower, and *how much* lower depends on the voice. That is the
   bias being removed. A constant offset that made the numbers "look like LUFS"
   would be a lie about a quantity that is not constant.
5. **Apply.** The gain column then reads 0.00, which is the visible proof that
   the pass landed where it said it would.

Everything below the band and the block length re-prices from frames already in
memory, so the gate, the target and the limits move at frame rate. The panel
says which controls need another Analyse.

**Link items** measures every selected clip as one programme and gives them one
common gain. That is what a comped lead vocal split across forty items wants —
normalising each phrase on its own would flatten the performance. Off, each clip
is normalised separately, which is what comparing takes wants.

## Limits, stated rather than discovered

- Operates on **every selected media item with an audio take**. MIDI takes and
  empty items are skipped, not refused.
- The peak ceiling is checked against the **sample peak**, not a true peak.
  The −1.0 dB default is chosen to leave room for the difference rather than to
  pretend it does not exist.
- Channel weighting is BS.1770's for mono and stereo (unity on L and R). The
  surround weights are not implemented; this measures a voice.
- The accessor applies **take FX**, so a take with FX on it is measured through
  them. It does not apply take volume, item volume or pan.
- Loudness range is a readout, not an input. It is the number that says whether
  normalising this take to a single figure is a sensible thing to do at all: a
  vocal at 4 LU takes a gain well, one at 15 LU is asking for a rider.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_VocalNormalizer.lua` | Entry point: finds its own modules, checks for ReaImGui, hands off to the panel |
| `vn/config.lua` | Defaults, ExtState persistence, and the parameter classes |
| `vn/biquad.lua` | Filter design: the Butterworth band, BS.1770 K-weighting, magnitude response |
| `vn/loudness.lua` | Blocks, gating, reduction, loudness range, the gain law |
| `vn/plan.lua` | One priced row per clip; pooling for linked mode |
| `vn/kernel.lua` | The EEL kernel wrapper and the memory map. The only file that knows an address |
| `vn/dsp/loudness.eel` | The measurement kernel: two filter chains, per-frame sums of squares, peak |
| `vn/analyze.lua` | The accessor edge: geometry, the coroutine job, the read-request protocol |
| `vn/select.lua` | Which clips a pass operates on |
| `vn/apply.lua` | **The only file that touches the project** |
| `vn/ui.lua` | The ReaImGui panel |

`biquad.lua`, `loudness.lua`, `plan.lua` and `config.lua` import no `reaper` and
are directly unit-testable. That split is the architecture, and its seams are
where the bugs live — see *Tests*.

### Parameter classes

| Class | Keys | Invalidates |
| --- | --- | --- |
| `ANALYSIS` | band lo/hi/order, K-weight, block length | the reads |
| `MEASURE` | absolute gate, relative gate, reduction, percentile | the price |
| `GAIN` | target, boost/cut limits, peak ceiling, link | the price |
| `OUTPUT` | write to, note on item | nothing |

The headless suite asserts the split both ways: every `ANALYSIS` key must move
`analysis_sig`, and no other key may. Every default must belong to exactly one
class — a key in none is a control that silently changes nothing, a key in two
is a cache thrown away for the wrong reason.

## Tests

```bash
python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py \
  test/headless.lua test/selftest_in_reaper.lua \
  test/panel_in_reaper.lua test/verify_edit_in_reaper.lua
```

REAPER must already be running; the harness will not start one.

Launching `Magnolius_VocalNormalizer.lua` through the same harness is a useful smoke
test even though its result is meaningless — the runner reports success as soon
as the file loads, but the panel really does open, on the real ReaImGui, with
the real enums and the real `BeginTable`. Check for the window rather than the
exit code.

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `headless.lua` | Filter design against BS.1770's published table, the block grid, the gate, percentile reduction, LRA, the gain law, volume folding, the parameter classes, a source scan of the panel's control keys | Whether the kernel filters the way `biquad.lua` says it does, and whether the accessor hands over the samples the geometry claims. Synthetic frames are green whatever the audio path is doing |
| `selftest_in_reaper.lua` | The EEL kernel on generated signals: the BS.1770 calibration point, channel summation, every band tone against the designed response, filter state across Executes, fractional hops, the heap probe, and that every coefficient reached the kernel unchanged | Anything about a real take. It never opens an accessor |
| `panel_in_reaper.lua` | That every panel state renders without throwing, with every control reporting "just moved", and with the optional ImGui symbols absent. Stack balance | Whether the panel *looks* right. That stays a manual check |
| `verify_edit_in_reaper.lua` | The whole pipeline on real takes at playrate 1 and 1.25: geometry, the LUFS null against SWS, channel summation through the accessor, the bias demonstration below, the measure→apply→measure round trip, polarity, item-volume compensation, linked mode | Whether the band is the *right* band for a given voice. That is a judgement, not a test |

As of the last full run: **174 + 28 + 64 + 44 = 310 checks, all passing.** The
suites leave nothing behind — fixture files, fixture tracks and the item
selection are all restored — and `verify_edit_in_reaper.lua` sweeps any fixture
track an interrupted earlier run left in the project before it builds its own.

### The two assertions that carry the most weight

**The LUFS null.** Open the band to 20 Hz–20 kHz and switch K-weighting on and
this script *is* an ordinary BS.1770 meter. SWS's `NF_AnalyzeTakeLoudness` is an
independent implementation of the same standard sitting in the same process, so
the two must agree on a real file — and if they do, the accessor read, the frame
grid, the filters, the channel summation, the gate and the integration are all
right together. This is the equivalent of the DeClick script's null against its
JSFX, and it is worth as much.

**The bias, demonstrated rather than argued.** The suite builds two takes of
the same performance — identical fundamentals, one with 3/6.5/9 kHz content and
one without — and trims the dark one until the two have *exactly the same
LUFS*. That is where a LUFS normalizer stops: it would leave both where they
are, and they would not sound alike. The band measurement then reads them
**5.84 dB apart**, the bright one being the quieter, and normalising on the band
lifts the bright take by that much. Afterwards the two match where the voice is
and differ in LUFS by exactly the bias that was removed. If that assertion ever
goes green with a small number, the band has stopped doing its job.

**The fixture ends loud.** The take accessor's timeline is *take* time and the
audio already has the playrate applied, so the span to read is the item length —
**not** the item length times the playrate. Reading the scaled span runs past
the end of the accessor and pads the tail with silence, which a gated
measurement quietly swallows. So the fixture's last second is a burst, and the
suite asserts the final block is above the absolute gate and inside the
measurement. That is what makes the playrate-1.25 case an actual test rather
than a second run of the playrate-1 one.

## Facts worth not rediscovering

**`reaper.array.copy` does not read a Lua table in integer-key order.** Building
the coefficient array like this —

```lua
local t = {}
t[1], t[2], t[3], t[4], t[5] = a, b, c, d, e          -- five at once
t[6], t[7], t[8], t[9], t[10] = f, g, h, i, j
arr.copy(t)                                            -- arr[9] and arr[10] SWAP
```

— transposes the last two elements. A multiple assignment wide enough to outrun
the table's array part leaves the last keys in the hash part, and `copy` does not
walk those in index order. `#t` is still 10 and every `t[i]` reads back
correctly, so nothing about the table looks wrong; the damage appears only on
the far side of `copy`. Filling the same table one index at a time, or in pairs,
or with a constructor, is all fine — it is the five-at-once form that does it.
Here it transposed a biquad's `a1` and `a2`, which is an unstable pole pair, so
the symptom was a K-weighted level of `inf` rather than a slightly wrong number.
`vn/kernel.lua` writes into the `reaper.array` element by element and then
**reads the coefficients back out of the kernel and compares**, so a corruption
between Lua and EEL is a startup error instead of a wrong filter.

**ReaImGui destroys a context that has gone unused for a few seconds.** A
long-running in-REAPER suite spends real time writing a fixture and pushing
audio through a kernel between context uses, and the payoff is
`ImGui_Attach: expected a valid ImGui_Context*, got 0x...` several sections in —
*and a modal ReaScript Error dialog that blocks REAPER's main thread until
somebody clicks it*, which looks exactly like a hung test run. Both in-REAPER
suites take the context through a `get_ctx()` that validates and rebuilds, and
they create it lazily at first use rather than at the top of the file.

**SWS reads a mono take 3.01 dB above us, and neither is wrong.** Measured on
7.75: `NF_AnalyzeTakeLoudness` on a mono take returns exactly 10·log₁₀(2) more
than this script does. It is measuring the take as it lands on a stereo track,
where one channel of material appears on two; we sum the channels the file
actually has, which is BS.1770's rule read literally. Both are defensible and
the difference is a definition, not a defect — so the null against SWS is run on
a **stereo** fixture, where the question does not arise, and the mono/stereo
relationship is asserted separately on two of our own takes, where it is ours to
get right.

**A guessed sample rate is worse than a refusal.** A take whose media has been
offline reports `rate = 0` forever after, while its accessor returns perfectly
good audio. Falling back to the project rate puts the band's corners 8% off and
reports a number that is quietly not the one asked for. `analyze.lua` asks a
fresh source over the same path first, and returns a `known` flag so the panel
can say when it had to guess.

## Bisecting when the numbers look wrong

In the order the pipeline runs, because the seam between two tested stages is
where the untested bug lives:

1. `selftest_in_reaper.lua` — the kernel on a synthetic signal with a known
   answer.
2. `verify_edit_in_reaper.lua` — the same kernel through the accessor, on a
   fixture at two playrates.
3. The LUFS null inside that suite — the whole chain against somebody else's
   implementation of the standard.
4. The panel, on a real take.

The first stage that comes back wrong is the broken one, and it is usually the
last one that has any coverage at all.
