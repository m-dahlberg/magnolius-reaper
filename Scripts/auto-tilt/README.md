# AutoTilt

Matches the spectral balance of one vocal clip to another with a single tilt EQ.

Two close-miked takes of the same part usually differ by a *tilt*: a different
mic, a different working distance, more or less proximity effect. The audible
result is a broad rotation of the spectrum about some mid frequency rather than
anything narrowband, and one number can undo it. AutoTilt measures the high/low
energy balance of both clips about a pivot you set, solves for the shelf-pair
gain that equalises them, and renders the target as a new take.

You set the pivot. Everything else is derived.

## Install

```bash
ln -sfn "$PWD" ~/.config/REAPER/Scripts/AutoTilt
```

Then Actions → Show action list → New action → Load ReaScript → pick
`Magnolius_AutoTilt.lua` inside the symlink. Needs [ReaImGui](https://github.com/cfillion/reaimgui)
(the panel and the EEL kernel both come from it).

## Use

Select two clips and press **Analyse**. The clip on the **lowest**-numbered
track is the reference; the one on the **highest**-numbered track is the target.
Everything above the target track counts as reference, so a lead against two
doubles works without any extra ceremony.

REAPER does not expose item *selection order* at all — `GetSelectedMediaItem`
walks the project in track-then-position order however you clicked — so the rule
has to be positional. It is also the only rule that is deterministic from
project state alone, which is what the headless second iteration needs.

**Apply** renders the target through the solved tilt and adds the result as a
new take. The original is kept, so A/B is a take switch. Pressing Apply without
having analysed analyses first.

### What the numbers mean

The balance figure is

```
ratio = 10·log10( high / low )   dB      about the pivot, energy per octave
```

Pink-flat material reads **0.00**. A bright condenser reads positive, a dull
dynamic negative. The *difference* between the two clips is what gets corrected.

Both sides are divided by their own octave span, which has two consequences
worth knowing: pink reads exactly zero rather than the +0.3 dB the raw sums give
for a band that is 3.6 octaves below the pivot and 4.0 above, and the reading
does not move when you change the band edges — so a captured fixed reference
still means the same thing at other settings.

### The measurement band

80 Hz – 16 kHz by default, and it bounds only the *measurement* — the tilt
itself is full range. Below 80 Hz a close mic carries proximity rumble,
plosives, stand thumps and HVAC; above 16 kHz it carries preamp hiss. Both hold
real energy and no tone, and both would otherwise move the number for reasons
nobody can hear.

### The gate

A vocal track is mostly not vocal. Room tone has a completely different spectral
slope from a voice, so how tightly a clip happens to be trimmed would leak
straight into its measured balance. The gate keeps only frames within
`gate_db` (30 by default) of the clip's own loud level, taken as the 95th
percentile frame — from the top, so a clip that is three-quarters silence still
finds its words. The panel reports how many frames survived.

### The fixed reference

With only one clip selected there is nothing to measure against, so the fixed
ratio stands in. **Capture from reference** copies the measured reference ratio
into it, which is how a house target accumulates across sessions.

### The plot

Reference, target, and target-after-the-tilt, each normalised to its own mean,
so the comparison is about shape rather than level. It is the honest check on
the whole idea: if the orange lands on the green, one number was enough — if it
does not, the difference between those two takes was never a tilt, and no
setting of this script will make it one.

Everything except FFT size, hop and target track redraws without touching the
audio, so the pivot is a control you drag.

## Notes on the design

**The cube is the architecture.** One accessor pass leaves behind a spectrum
cube bucketed by frame level — `cube[lev][bin] += |X(bin)|²`, summed over
channels. Everything afterwards is a choice made over that cube: the gate picks
which rows to sum, the band limits and the pivot pick which bins. `build` turns
it into cumulative-from-the-top rows once, so selecting a gate is an array
lookup and dragging the pivot costs one pass over 2049 bins. Bucketing is by
*broadband* level deliberately: the band limits have to stay free to change
after analysis, and they could not if they decided which row a frame landed in.

**The gain is solved, not set to the difference.** A shelf pair only reaches its
full ±G/2 far from the pivot, so a tilt of G moves the measured balance by
rather less than G — how much less depends on where the material's energy sits.
Setting `gain = difference` undershoots every time, by a varying amount. Instead
the solver applies the pair's *actual* biquad |H(f)|² to the cached spectrum and
bisects; the ratio is strictly increasing in G, so forty halvings settle it well
past the resolution of anything downstream.

**One definition of the curve, read from both ends.** `at/solve.lua` owns the
RBJ shelf coefficients. It evaluates them analytically to predict what the
render will do, and `at/kernel.lua` hands the same five numbers per filter to
the EEL that does it. That shared definition is what lets the selftest assert
the *measured* response against the *predicted* one rather than hoping they
agree; on the last run they agreed to 0.0000 dB.

**Why the shelf pair and not a slope.** A low shelf at −G/2 and a high shelf at
+G/2, both cornered at the pivot. Each RBJ shelf reaches half its dB gain at its
own corner, so the pair is exactly unity at the pivot, asymptotes to ∓G/2, and
spans G dB overall. At G = 0 every coefficient collapses term for term — `b0`
is exactly 1 and `b1 == a1`, `b2 == a2` — so a zero-gain render is bit-exact,
not merely quiet. That is what makes the null test an assertion rather than a
tolerance.

**Level compensation is not optional in practice.** A tilt about 1 kHz changes
overall level, because a vocal's energy is not centred there. Without the makeup
gain the match arrives with a level change attached and reads as the tilt being
wrong. It is computed analytically from the cached spectrum, so it costs
nothing, and it is exactly 1 at G = 0.

**Every clip is read at the target's rate.** The accessor resamples on the way
out, so it is free, and it buys two things that would otherwise be bugs: several
reference clips can be power-summed into one cube, and one bin-to-Hz mapping
covers both sides. A 44.1 kHz reference against a 48 kHz target would otherwise
put the pivot between different bins on each side. The *render* still writes at
the take's own source rate, so the shelves are designed there.

**The job never reads its own audio.** `GetAudioAccessorSamples` returns `nil`
inside a Lua coroutine and leaves the buffer untouched — no error, not the
documented 0 — so a job that read for itself would analyse an entirely silent
file. It yields a read request instead and the main-thread driver fills it. An
unserviced request is a hard error, because the silent version of that bug hides
indefinitely.

## Layout

| File | Role |
| --- | --- |
| `Magnolius_AutoTilt.lua` | entry action — the panel |
| `at/config.lua` | defaults, ExtState, parameter-class signatures, shared geometry |
| `at/select.lua` | which selected clips are reference and which is target |
| `at/dsp/tilt.eel` | task 1 STFT into the cube; task 3 the shelf-pair render |
| `at/kernel.lua` | compiles it and owns the memory map; nothing above knows an address |
| `at/analyze.lua` | the accessor edge — clips in, cube out |
| `at/spectrum.lua` | **pure**: cube → gate → band → balance figure |
| `at/solve.lua` | **pure**: the shelf pair, its response, the search, the makeup gain |
| `at/render.lua` | accessor loop → tilted samples → WAV |
| `at/wav.lua` | 32-bit float WAV writer (verbatim from DeClick) |
| `at/apply.lua` | adds the result as a take — the only file touching the project |
| `at/ui.lua` | the panel |
| `test/ui_frame.lua` | one panel frame against a stub ImGui |
| `test/panel_in_reaper.lua` | the panel against the real ReaImGui |
| `tools/run_tests.py` | runs the three headless-drivable suites |
| `tools/run_panel_test.py` | runs the panel suite and waits for its result |

## Tests

There is no system `lua` on this machine; the suites run inside the already
running REAPER. `tools/run_tests.py` drives the first three;
`tools/run_panel_test.py` drives the fourth.

| Suite | Covers | Cannot cover |
| --- | --- | --- |
| `headless.lua` | pure Lua, 176 assertions: pink reads 0.00 and stays there across band edges and pivots; out-of-band rumble does not move it; a degenerate pivot is refused by name; the gate on a synthetic two-level cube; the shelf pair's asymptotes, span and exact G=0 pass-through; the solve's monotonicity, round trip, clamping and makeup invariant; the parameter-class split; six panel states rendered twice each, quiet and with every control moved; a scan asserting every control names a real config key and every key has a control | that the kernel produces the spectrum Lua assumes; anything touching audio; whether the ImGui calls have the right *arity* |
| `selftest_in_reaper.lua` | the compiled EEL on generated signals: a bin-centred sine buckets at −3 dBFS and peaks in the right bin, with Parseval reading back its mean square; two levels 20 dB apart bucket 20 apart; **the render biquads measured on sine sweeps against `solve.lua`'s analytic \|H(f)\|**, nine frequencies × four gains; unity at the pivot; G=0 bit-exact and the makeup gain exact; every ImGui symbol the panel names exists | that the accessor hands the kernel real audio; ImGui arities |
| `panel_in_reaper.lua` | the panel against the **real** ReaImGui, seven layout states × three frames: the window actually drew, `frame()` did not raise, the disabled stack balanced | anything needing a control to be *moved* — the real library cannot be given fake input, which is what the stub is for |
| `verify_edit_in_reaper.lua` | the whole pipeline on a self-built two-track fixture — reference noise, target the same noise pre-tilted by a known −4 dB — at playrate **1.0 and 1.25**: selection resolves the right way round; analysis saw audio and not silence; the solved gain undoes the pre-tilt; **the applied take, re-read through the accessor and measured again, matches the reference's balance**; take properties neutralised and `D_STARTOFFS = 0`; peaks built and non-zero; a zero-gain render nulls at −300 dB at shift 0 with ±1 sample 280 dB worse | whether the rule sounds right on a real voice |

All suites end with a guarded `os.exit(fails == 0 and 0 or 1)`, and count
anything that stops a run — "ReaImGui is missing", a kernel that would not
build — as a failure rather than an early return.

**Why the panel needs its own runner.** ImGui will not draw outside the defer
cycle, and forcing a frame from the main thread blocks REAPER on a modal task
dialog — so the panel suite has to be a deferred script. `reascript_test.py`
would report it green as soon as the *file* finished loading, before a single
frame had been drawn, so `tools/run_panel_test.py` launches it and polls for the
result file the suite writes itself.

The two panel suites are complements and neither is redundant: the stub can move
every control but answers any call with any arguments, so it cannot see a wrong
argument count or a renamed symbol; the real library catches those but cannot be
handed fake input.

The fixture is built and deleted by the suite with the item selection restored,
so it needs no selection and cannot silently skip the stretched case. At
playrate 1 every quantity in the take geometry is the same number, which is why
every scaling mistake passes there and the 1.25 case is the one that can fail.

## Known limits

- **Operates on whole clips.** There is no time selection and no per-phrase
  tilt; the answer is one number for the whole target row.
- **A very quiet clip can defeat the gate.** The loud level is the 95th
  percentile *of all frames*, so a clip that is 99% silence with one short word
  in it puts the reference below the word and the gate then admits the room
  tone. The panel's frames-kept readout is how you would see it; raise
  `gate_pct` if you hit it.
- **The measurement is not perceptual.** Energy per octave, not loudness — no
  K-weighting, no equal-loudness contour. For matching two takes of one source
  that is the right call; for comparing a voice against a snare it is not.
- **The target clips must agree about channel count.** The kernel's memory map
  fixes it, and a mismatched clip is refused by name rather than rendered
  wrongly.
- **`Liteon/tilteq` is not a null target.** That plugin is a one-pole shelf with
  a deliberately asymmetric response (`g1 = -4·gain, g2 = gain` above zero), so
  it is a different curve from the symmetric RBJ pair by construction. It is an
  ear reference, not a bit-exact one; the equivalent rigour here is the
  analytic-vs-measured response sweep in `selftest_in_reaper.lua`.
- **Headless operation is not built yet.** The modules are arranged for it —
  `select.lua` is deterministic from project state and
  analyse → measure → solve → render → apply takes no UI — so it is a short
  second entry point alongside `Magnolius_AutoTilt.lua`.
