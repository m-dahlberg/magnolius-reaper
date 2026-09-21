# Upward Compressor

A low-level lift for REAPER. It raises what is **below** the threshold and
leaves what is above it alone — the mirror image of an ordinary compressor.

A downward compressor turns the peaks down; this turns the quiet parts up. The
loud parts keep their level and their transients, and only the low-level
detail moves: breaths, room, the tail of a reverb, the quiet half of a
performance. On a vocal it is the difference between "consistent" and
"squashed".

Zero latency. No lookahead, no PDC.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and there is no warning anywhere in REAPER when it happens:

```
ln -s "$PWD/Magnolius_UpwardCompressor.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_UpwardCompressor.jsfx"
ln -s "$PWD/Magnolius_UpwardCompressor.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_UpwardCompressor.help.txt"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Upward Compressor** to a track.

The interface loads its artwork at runtime, so `gui_kit/` has to be reachable
from the plugin **as REAPER sees it** — next to the symlink, not just next to
this README. The Magnolius Effects folder is flat and every plugin there
shares one `gui_kit/`, so if a sibling plugin is already installed the assets
are already in place. If nothing draws and the header says *images failed to
load*, that folder is what is missing.

If a change to the source seems to have no effect, check the link first:

```
readlink -f ~/.config/REAPER/Effects/Magnolius/"Magnolius_UpwardCompressor.jsfx"
```

…and then reload the FX, because REAPER caches the compiled code per
instance. The version number in the top-left of the UI is there so a stale
instance is visible at a glance.

## How it works

1. The detector runs on a high-passed copy of the input (**Sidechain HPF**),
   so low-frequency energy does not decide how much lift the whole signal
   gets. Peak or RMS, your choice.
2. The two channel detectors are pulled toward the louder one by **Stereo
   Link**, so a lift never shifts the stereo image.
3. The static curve asks *how far below the threshold* the detector is and
   multiplies that by `1 − 1/ratio`. A quadratic **Knee** straddles the
   threshold, continuous in both value and slope.
4. **Range** caps the result at up to 12 dB, so a silent bar cannot be
   dragged all the way up to the threshold, and the **Noise Floor** control
   fades the lift out over the 6 dB below it, so hiss, room tone and pauses
   stay where they are.
5. The result is smoothed with the attack/release ballistics and applied as a
   gain.

### Attack and Release are mirrored too

This is the one thing that trips people up:

- **Attack** is how fast the lift comes **in** as the signal gets **quieter**.
- **Release** is how fast it backs **off** as the signal gets louder again.

So a *fast* attack here means quiet detail jumps up quickly — which is the
setting that sounds pumpy. That is the opposite intuition from a downward
compressor, and the sliders are labelled accordingly.

## Controls

| Slider | Default | What it does |
| --- | --- | --- |
| Threshold (dB) | −30 | Everything below this gets lifted. Set it under the body of the performance and above the noise. |
| Ratio (1:N) | 2.00 | How much of the distance below the threshold is made up. 1:2 halves it, 1:∞ would flatten everything onto the threshold. |
| Range / Max Lift (dB) | 12 | Hard ceiling on the lift, 0–12 dB. The single most important safety control. |
| Knee (dB) | 6 | Width of the soft knee around the threshold. |
| Attack – lift in (ms) | 20 | Speed the lift comes in as the signal drops. Fast = pumpy. |
| Release – lift out (ms) | 200 | Speed the lift backs off as the signal returns. |
| Noise Floor (dB) | −70 | Lift fades to zero over the 6 dB below this. Raise it until hiss and room stop breathing. |
| Sidechain HPF (Hz) | 20 | Detector-only high pass. Raise it so bass does not govern the lift. |
| Detector | RMS | RMS (30 ms) follows loudness; Peak (20 ms release) follows transients. |
| Stereo Link (%) | 100 | 100% keeps the image locked; 0% lets each channel act alone. |
| Makeup (dB) | 0 | Output gain on the **wet** path only. |
| Mix (%) | 100 | Wet/dry blend. **0% is an exact bypass**, whatever Makeup is set to. |
| Display History (s) | 6 | Time span of the scrolling display. Cosmetic. |

## The interface

Built on the Magnolius GUI kit. Every knob has a value field under it: drag it
to scrub, click it to type. Ctrl-click a knob or a field resets it, Shift
while dragging is fine adjustment.

The header carries an interface scale dropdown and a **?** button that opens
`Magnolius_UpwardCompressor.help.txt` in a scrollable panel. The scale is
shared through `gmem` with every other `options:gmem=Magnolius` plugin, so
setting it in one window sets it everywhere; it is session-scoped, plus a
per-project copy in `@serialize`. A JSFX cannot resize its own window, so a
scale larger than the window clips — `Fit` follows the window instead.

## The display

- **Grey** waveform is the input, **cyan** is the output, both peak per column
  on a −78 dB scale, mirrored about the centre line, newest at the right edge.
  Cyan standing outside grey is the lift.
- **Green**, overlaid from the bottom of the same plot: the applied lift, on
  a **fixed** 0…12 dB scale — the top of the plot is 12 dB, which is also the
  most Range will allow. The scale deliberately does not follow Range: when it
  did, raising Range made the same lift draw shorter, which reads as less lift
  when it is the opposite. Range now shows up as the height the green stops
  climbing at.
- **Orange** horizontal lines: the threshold. **Dotted grey**: the noise
  floor.
- **CURVE panel, right**: the live transfer curve, −80…0 dB in. It plots what
  actually leaves the plugin, Mix and Makeup included, against the grey unity
  line, with the threshold marked in orange and the noise floor dotted. Watch
  it while you move Ratio and Knee.
- **Lift**, **Det Level** and **Out Peak** are read-only fields: the lift being
  applied, the level the curve is being fed, and the peak leaving the plugin.

The waveform is drawn by the plugin rather than by the kit's `gk_wave_draw`,
which plots linear amplitude. On a plugin whose whole subject is what happens
40–70 dB down, a linear scale puts everything of interest on the centre line.

Each drawn column is the **maximum** over every history slot it covers, so a
transient cannot fall between pixels and make the display disagree with your
ears.

## Quick sanity checks, by ear

- Set **Ratio to 1:1**. The plugin must be completely inaudible — this is a
  bit-exact bypass, not a "close enough".
- Set **Mix to 0%** with a big Makeup dialled in. Still silent. If you hear a
  level jump, you are running an old build.
- Put it on a vocal, set **Range to 12** and **Threshold to −10**. It should
  sound obviously, horribly wrong — everything crushed up to the threshold.
  If nothing happens, the plugin is not actually processing.
- Bring Range back to about 6, Threshold under the body of the vocal, and
  raise the **Noise Floor** until the pauses stop breathing.

## Tests

`tools/render_test.py` renders projects headlessly through
`reaper -newinst`, so it is safe to run while a normal REAPER is open.

```
tools/render_test.py                 # everything
tools/render_test.py unity canary    # named tests only
```

Work files land in `~/.cache/upcomp-rendertest` (`UPCOMP_WORK` overrides);
`UPCOMP_FX_NAME` overrides the FX lookup name.

| Test | What it pins |
| --- | --- |
| `params` | All 13 sliders survive the header parse. A JSFX header error has no error UI — the bad slider and every one after it just vanish. |
| `unity` | Ratio 1:1 is **bit-identical** to the input: reported PDC (zero) equals actual latency. |
| `canary` | +6.0206 dB makeup gives exactly 2×. The one assertion a dead-`@init` passthrough cannot fake. |
| `mix_bypass` | Mix 0% is exact bypass with Makeup +12 — regression guard for the old topology that multiplied the dry path. |
| `model`, `model_peak` | Sample-for-sample agreement with `tools/model.py`, both detector modes. |
| `static_curve` | Settled lift lands on the closed-form static curve at six input levels. |
| `range_clamp` | Range is a hard ceiling however greedy the ratio. |
| `gate` | Lift fades out under the noise floor. |
| `link` | Stereo Link moves the quiet channel onto the loud channel's detector. |
| `rates` | Model agreement at 44.1 / 48 / 96 kHz — every coefficient really is rebuilt from `srate`. |

`tools/model.py` is a pure-Python mirror of `@init`/`@slider`/`@sample`.
**It and the `.jsfx` must be edited together.** If `model` fails after a DSP
change, one of the two is wrong; do not loosen the tolerance.

## Files

```
Magnolius_UpwardCompressor.jsfx       the plugin
Magnolius_UpwardCompressor.help.txt   text shown by the ? button, read at runtime
gui_kit/                  widget library + PNG artwork, loaded at runtime
tools/model.py            pure-Python reference model of the DSP
tools/render_test.py      headless render tests
tools/render_harness.py   .rpp writer, render(), ReaScript probe, DFT probes
tools/wavio.py            stdlib WAV I/O
```

## Notes for the next person

- **Threading.** Every `@gfx` variable is `g_`-prefixed and no name is used on
  both sides. The rule is not "`@gfx` calls no functions" — it is that *no
  function is called from both threads*. EEL2 function locals *and parameters*
  are static and shared, so drawing the transfer curve through `lift_db()`
  would stomp the audio thread's copy of `x`/`hk`/`g` mid-sample. So
  `db2lin`/`lin2db`/`lift_db`/`recalc` belong to the audio thread, and
  `accent`/`ui_scale`/`count_missing_images`/every `gk_*` belong to `@gfx`.
  The curve maths is inlined in `@gfx` instead. It looks like duplication. It
  is not — do not "clean it up".
- **Widget changes go through a flag, not a call.** A knob writes its slider
  and calls `slider_automate`, then `@gfx` sets `need_recalc`; `@block` picks
  it up and calls `recalc()` on the audio thread. Calling `recalc()` from
  `@gfx` would enter `db2lin()` from the UI thread and stomp its parameter
  underneath `@sample`, and relying on REAPER to re-run `@slider` after
  `slider_automate` is not something to depend on.
- **The display readouts are converted in `@block`.** `out_db` and `det_db`
  are `lin2db()` of two envelopes, done once per block on the audio thread, so
  `@gfx` only ever formats a number.
- **The lift overlay's scale is fixed at 0…12 dB** (`LIFT_FULL_DB`), and the
  Range slider's maximum is the same number. They are two halves of one
  decision: change one without the other and the overlay either stops short of
  the top of the plot or clips against it.
- **`ext_noinit = 1`** stops `@init` re-running on transport start, so
  detector state and the display survive hitting play. `@init` still re-runs
  on a samplerate change, which is why every rate-dependent coefficient lives
  in one `recalc()` that both `@init` and `@slider` call.
- **No `ext_tail_size`.** The output is always a gain applied to the input, so
  silence in is silence out at every setting. There is no tail to render.
- Offline renders never run `@gfx`, so no test in this repo can catch a
  threading regression. The naming convention is the only defence.
