# Vari-Mu Compressor

A Fairchild 670-style variable-mu compressor/limiter for REAPER, with a custom
panel: a scrolling input waveform with both gain-reduction traces drawn over
it in real time, and in/GR/out meters.

The detector is Thomas Scott Stillwell's, from "Fairly Childish" (which ships
with REAPER as `sstillwell/fairlychildish2`), used under the 3-clause BSD
licence — see [LICENSE](LICENSE). At default settings this plugin renders
**bit-identical** audio to his original; that is pinned by a test, not a
claim (`render_test.py original`, which renders both plugins and diffs them).

Zero latency: no lookahead anywhere, so `pdc_delay` is 0.

## Install

Symlink, never copy — a plain copy goes stale silently, and REAPER resolves
`<JS "name.jsfx">` by name across the whole Effects tree, so any stray copy
anywhere can shadow the repo file:

```sh
ln -s ~/repos/jsfx/FairchildComp/Magnolius_VariMuCompressor.jsfx \
      ~/.config/REAPER/Effects/Magnolius/Magnolius_VariMuCompressor.jsfx
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then find it as
**VariMuComp**.

If a change ever seems to have no effect, check what the name actually
resolves to before suspecting the code:

```sh
readlink -f ~/.config/REAPER/Effects/Magnolius/Magnolius_VariMuCompressor.jsfx
find ~/.config/REAPER/Effects -name 'VariMuComp*'
```

The version number in the top-right of the panel exists for the same reason:
REAPER caches compiled JSFX per open FX instance, so a stale instance is
otherwise invisible. If it does not match the `v` in the source header,
remove and re-add the FX.

## How it works

1. The detector feed is either L and R, or Mid and Side, depending on Mode.
2. Optional sidechain high-pass on that feed only (never on the audio).
3. In L/R mode the two feeds are blended toward `max(|L|,|R|)` by Stereo
   Link. Mid/Side is deliberately left independent — that is the point of
   the mode.
4. Each feed runs a short RMS window, then Stillwell's detector: overshoot in
   dB, attack/release one-poles from the selected time constant, and a
   **program-dependent ratio** that climbs from 1:1 toward Max Ratio as the
   overshoot grows relative to Bias:

   `ratio = 1 + (MaxRatio - 1) * sqrt(overshoot / bias)`

   That is what makes it behave like a vari-mu tube stage rather than a
   fixed-ratio compressor: quiet passages are barely touched, loud ones are
   limited hard, with no knee control anywhere.
5. Gain, makeup, then wet/dry mix and output trim.

### The two "blown capacitor" modes

Modes 0 and 1 run the detector at 2.08x the dB slope of modes 2 and 3. It is
Stillwell's emulation of a specific Fairchild fault condition, and it makes
the compressor considerably more aggressive for the same threshold. It is not
a bug and it is not a bypass.

## Controls

Every parameter is a knob on the panel. Drag vertically; **shift** = fine,
**right-click** = back to default. The native REAPER slider list is hidden
(each label starts with `-`), but every parameter is still fully automatable
and still appears in the Param menu.

| Knob | Default | What it does |
|---|---|---|
| Threshold (L/Mid, R/Side) | 0 dB | Where compression starts. |
| Bias (L/Mid, R/Side) | 70 % | How fast the ratio climbs with overshoot. Low bias = the ratio reaches Max Ratio almost at once (limiting); high bias = a long, gentle progression. 0 pins the ratio at Max Ratio. |
| Makeup (L/Mid, R/Side) | 0 dB | Gain after compression, per chain. |
| Time Constant (L/Mid, R/Side) | 1 | The six Fairchild programme presets, 1 (0.2 ms / 300 ms) to 6 (0.4 ms / 25 s). |
| RMS Window (L/Mid, R/Side) | 100 µs | Detector averaging. Short = peak-like, long = smoother and slower. |
| Mode | L/R | L/R or Mid/Side, each with or without "blown capacitor". |
| Max Ratio | 20:1 | The ceiling the program-dependent ratio climbs toward. Was hardcoded to 20 in the original. |
| SC HPF | off | High-pass on the detector only, so bass stops driving the gain. Fully bypassed at 20 Hz. |
| Stereo Link | 100 % | L/R mode only. 100 % is one shared detector (the original's behaviour); 0 % is fully independent channels. |
| Mix | 100 % | Wet/dry, for parallel compression. |
| Output Trim | 0 dB | Final gain, after the mix. |
| History | 6 s | Time span of the scrolling display. |

In L/R mode the R/Side row dims and reads "follows Left" — those settings are
kept, not overwritten (see below), and come back when you return to Mid/Side.

## The display

- **Blue-grey waveform**: the *input*, min/max per pixel column, newest at the
  right edge.
- **Orange trace**: gain reduction of the Left/Mid chain, hanging down from
  the top edge over a 0..24 dB range.
- **Red trace**: gain reduction of the Right/Side chain. In L/R mode with
  Stereo Link at 100 % the two sit on top of each other; that is correct.
- Faint horizontal lines mark ±0.5 amplitude and 6/12/18 dB of reduction.
- The bars at the bottom are input peak, output peak and gain reduction, all
  with a 300 ms release.

## Differences from the original

Fixed:

- `@init` read `attime`/`reltime`/`rmstime`, which are **never defined**
  anywhere (the real names are `lattime`/`lreltime`/`lrmstime`). Harmless only
  because `@slider` recomputed the coefficients first. Removed.
- `dcoffset` was used in the ratio formula but **never assigned anywhere** in
  any Stillwell plugin, so it was always 0. Removed rather than left as a
  phantom.
- **Mode switching destroyed settings.** The original assigned
  `slider2/4/6/9/11` from the left-hand sliders whenever the mode was L/R, so
  a round trip Mid/Side → L/R → Mid/Side silently reset every Side setting to
  its Left counterpart — and with no `slider_automate()`, REAPER's UI did not
  even show it happening. The right chain now mirrors the left chain's
  *derived* values instead and keeps its own sliders. `render_test.py
  modeswitch` pins this, and probes the stock plugin alongside as a control:
  it keeps 0 of 5 settings, this keeps 5 of 5.
- `ext_gr_meter` reported the Lat chain only in Lat/Vert mode; it now reports
  `min(left, right)`. (It is dB and non-positive — REAPER's changelog:
  *"add ext_gr_meter ... set to non-positive values"*.)
- The RMS Window range 1..10000 was unitless in the UI but divided by 1e6.
  It is microseconds, and now says so.

Simplified — the two `@slider` mode branches were about 90 % identical, and
the six-way time-constant ladder was written out twice. Those ~110 lines
became ~35 plus two tables, and the duplicated per-channel `@sample` detector
became one function called through two EEL2 instance namespaces.

Added: Max Ratio, sidechain HPF, stereo link, wet/dry mix, output trim, and
the panel. **Every one defaults to the original behaviour**, which is what
makes the bit-identical test above meaningful.

## Quick sanity checks, by ear

- Threshold 0 dB on quiet material should be inaudible, and the GR traces flat
  at the top of the display.
- Time Constant 6 on a drum bus: the GR traces should sag and take many
  seconds to recover. Time Constant 1: they should snap back between hits.
- Bias to 0 with a low threshold turns it into a hard limiter — the ratio no
  longer ramps.
- Mid/Side with a low Side threshold should narrow the image on loud passages
  and let it open up again in quiet ones; the two GR traces should visibly
  diverge.
- Mix at 50 % should sound obviously fuller and less controlled than 100 %.

## Tests

```sh
tools/render_test.py                    # everything
tools/render_test.py unity original     # named tests only
tools/gfx_test.py                       # the panel (needs a graphical session)
```

Renders go through `reaper -newinst`, so they are safe to run while your
normal REAPER is open. Work files land in `~/.cache/varimu-rendertest`
(`VARIMU_WORK` overrides).

| Test | What it pins |
|---|---|
| `params` | All 17 sliders survive the header parse **and** still enumerate as parameters despite being hidden. A bad slider line silently eats that slider and every one after it, with no error UI anywhere. |
| `canary` | +6 dB makeup gives exactly 2×. A dead `@init` degrades to passthrough, which cannot fake this. |
| `unity` | Threshold 0 dB on quiet material is passthrough to 1.5e-16 — REAPER injects roughly that much denormal-prevention DC into FX input buffers, so this is as exact as a render can be. |
| `original` | **Renders the stock `sstillwell/fairlychildish2` and this plugin on the same programme at matched settings and diffs them**, across L/R and Mid/Side, blown-cap and not, three time constants. Currently 0.0 — bit-identical. |
| `model` | Agreement with `tools/model.py` across modes and all the new controls. |
| `modeswitch` | The Side settings survive a round trip through L/R, with the stock plugin probed as a control. |
| `link` | Link 100 % ducks the quiet channel with the loud one; link 0 % leaves it alone. |
| `mix_trim` | Mix 0 % is bit-exactly dry; trim is exact dB. |
| `schpf` | The sidechain HPF is bit-identical to off at 20 Hz, and actually changes the gain at 300 Hz. |
| `rates` | 44.1 / 48 / 96 / 192 kHz stay finite and bounded. |
| `gfx_test.py` | `@gfx` compiles and runs, and a knob change reaches the **audio path** — it reads back derived state (`agc`, `l.threshv`), not slider values. See below for why that distinction matters. |

`tools/model.py` and `Magnolius_VariMuCompressor.jsfx` must be edited together — the `model`
test is meaningless otherwise. Do not loosen a tolerance to make a test pass.

## Files

```
Magnolius_VariMuCompressor.jsfx        the plugin
LICENSE                Stillwell's BSD notice, retained as the licence requires
tools/model.py         pure-Python mirror of @init/@slider/@sample
tools/render_test.py   headless render tests
tools/gfx_test.py      drives the panel in a throwaway REAPER instance
tools/render_harness.py  shared .rpp writer / render / ReaScript probe
tools/wavio.py         minimal WAV read/write
```

## Notes for the next person

**Threading — do not undo it.** `@gfx` runs on the UI thread while
`@init`/`@slider`/`@block`/`@sample` run on the audio thread, and *all*
globals and *all* function locals are shared between them. So every `@gfx`
variable is `g_`-prefixed, `@gfx` loop counters are `gi`/`gj` and audio-side
ones `ai`/`aj`, and no name is used on both sides. The knob helpers are
defined **inside** `@gfx`, below every audio-side section, so the audio thread
cannot call them and stomp their static locals. `@gfx` never calls `det()`.
It looks like gratuitous verbosity; it prevents real corruption.

**Offline renders never run `@gfx`**, so no test in `render_test.py` can catch
a threading regression — and a `@gfx` syntax error still lets every one of
them pass, `params` included (verified). `gfx_test.py` is what catches a dead
panel; the naming discipline is the only defence against tearing.

Scripted screenshotting of a JSFX pane does not work here, but the desktop
screenshot utility captures it fine — so appearance is checked by looking at
one, not by automating it. Worth doing after any layout change: the v0.1
dead-knob bug was visible in a screenshot as "RIGHT / follows Left" while Mode
read M/S, which is only possible if the audio-side `agc` was stale.

**Neither `slider_automate()` nor `sliderchange()` re-runs `@slider`.** Both
verified. They tell the *host* about a value the effect changed; the effect is
expected to have applied it already. v0.1 shipped with every knob dead for
exactly this reason: the panel wrote the slider variable and updated its own
display, while the DSP kept using the coefficients computed at load. `@block`
is not a fix either — **it does not run on a stopped, silent track**, so a
queued flag would leave the knobs dead until you pressed play.

So every derived value lives in `recalc()`, which `@slider` calls and `@gfx`
calls through `g_commit()`. That means `recalc()` is called from **both
threads**, which is safe only because it has no parameters, no `local()` and
no loops — every name in it is a global written deterministically from the
slider values, so two concurrent calls compute identical results. This is the
one deliberate exception to "@gfx never calls an audio-side function", and it
is the same exception MixReference documents for `clearstats()`.
**Do not add a `local()` or a loop to `recalc()`.**

The lesson for testing: a GUI test must read back a *derived* value. Checking
that the host sees the new slider value passes happily while the DSP is
stale — that is precisely what let v0.1 through.

**EEL2 is case-insensitive.** `HIST_N` and `hist_n` would be one variable,
silently. Never distinguish two names by case alone. There is also no
scientific notation: `1e-30` is a *silent* syntax error that kills the whole
section — write `10^(-30)`.

`ext_noinit = 1` stops `@init` re-running on transport start, which would
otherwise wipe the display ring. `@init` still re-runs on samplerate change
and recompile, which is why the one-time setup is behind the `initdone` guard
and only the rate-dependent scalars are recomputed below it.

The display ring is a single-writer power-of-two ring: `@sample` writes,
`@gfx` reads at most `HIST_N - 2` columns so it never touches the column
being filled. Index with `& HMASK`, never `%` — EEL2's `%` on a negative
operand is not guaranteed.
