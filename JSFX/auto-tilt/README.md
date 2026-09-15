# AutoTilt

An automatic tilt EQ for sung vocals.

You set a **pivot frequency** and a **tone target**; AutoTilt measures the
long-term spectral balance of the incoming vocal and sets the tilt gain so the
output lands on that target. It is meant to be set once and left alone: on a
normal vocal the gain settles in the first few seconds and then effectively
holds for the whole song.

The point is consistency. Different takes, singers, mics and rooms arrive with
different tonal balances; AutoTilt pulls them all onto the same tilt so the
rest of your chain works the same way every time.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes:

```
ln -s "$PWD/Magnolius_AutoTilt.jsfx" ~/.config/REAPER/Effects/Magnolius_AutoTilt.jsfx
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: AutoTilt** to a track.

## How it works

1. Every 85 ms an 8192-point FFT of the **pre-EQ** input is folded into 32
   log-spaced bands across the analysis range, and those band levels are
   averaged over `Analysis Window` seconds.
2. A least-squares line is fitted through the averaged band levels against
   log2(f). Its gradient is the signal's **slope**, in dB per octave.
3. The tilt gain that would move that slope onto the target is computed —
   using the sensitivity of the actual designed filter, not an assumed
   constant — and smoothed with the `Response` time constant.
4. Two RBJ shelves (−G low, +G high, sharing the pivot) apply it in the time
   domain.

The measurement is **feed-forward**: it is taken before the EQ, so there is no
control loop that can ring or hunt. All of the motion you hear is the two time
constants, and nothing else.

**Zero latency.** The FFT is only ever used to look, never to process, so no
PDC is reported and none is needed.

## Controls

| Slider | Default | What it does |
| --- | --- | --- |
| Tone (Dark to Bright) | 0 | Target offset around the neutral slope, ±0.5 dB/oct at the extremes. This is the one you actually ride. |
| Neutral Slope (dB per oct) | −8 | The target at Tone = 0. **Calibrate this once** — see below. |
| Tilt Pivot (Hz) | 1000 | Where the tilt crosses 0 dB. |
| Max Auto Tilt (dB) | 6 | Clamp on the automatic part. The manual offset is not clamped by it. |
| Response (s) | 20 | Time constant of the applied gain. Long is the point. |
| Analysis Window (s) | 8 | Time constant of the spectrum average feeding the fit. |
| Amount (%) | 100 | Scales the automatic correction. 0 = manual tilt only. |
| Manual Offset (dB) | 0 | Added to the automatic gain, instantly and unclamped. |
| Gate (dB RMS) | −40 | Below this the spectrum average freezes, so pauses and room tone cannot drag the correction. |
| Analysis Low (Hz) | 120 | Bottom of the fitted range. Keep rumble and the HPF region out. |
| Analysis High (Hz) | 9000 | Top of the fitted range. Keep hiss and air out. |
| Tilt Shelf Slope | 0.55 | Shelf steepness. Lower is gentler and wider. |
| Level Compensation | On | Removes the broadband level change the tilt causes, computed from the measured spectrum. |
| Freeze | Off | Holds the automatic gain where it is. The analysis and display keep running. |
| Output Trim (dB) | 0 | Plain output gain. |
| Fast Start | On | Uses a running mean until the configured time constants become the slower option, so the first few seconds converge instead of crawling. |

## Calibrating Neutral Slope

`Neutral Slope` is the only control that needs a number rather than an ear.
Set it empirically:

1. Put AutoTilt on a vocal you already think sounds right, with
   `Amount` at 0.
2. Play a chorus and read **measured** in the display header once it settles.
3. Type that number into `Neutral Slope`, set `Amount` back to 100, and use
   `Tone` from there.

Now every other vocal gets pulled to the balance of your reference. Typical
sung-vocal values land between −6 and −11 dB/oct over the default range; a
value that is far outside that usually means the analysis range is catching
rumble or hiss rather than voice.

## The display

- **blue** — the measured input spectrum, mean removed (shape only).
- **dim blue** — the straight line fitted through it. That gradient is
  "measured".
- **grey** — the target slope.
- **orange** — the tilt curve currently being applied.
- Red verticals mark the analysis range; the green vertical is the pivot.

Header line: measured slope, target slope, applied tilt. Second line: the
automatic and manual parts of the tilt separately, the level compensation, the
sensitivity (how much slope one dB of tilt buys, given the current pivot,
shelf slope and range), the input level, and `GATED` / `FROZEN`.

## State

The converged tilt is saved with the project, so reopening a session sounds
right immediately. On load the measured spectrum is deliberately relearned
from scratch while the restored gain is held steady, so nothing jumps.

## Quick sanity checks by ear

- `Amount` 0, `Manual Offset` swept: a plain, very clean tilt EQ, pivoting
  where you set it. Nothing should move on its own.
- `Freeze` on: the correction stops dead, the display keeps updating.
- Solo a bright take and a dull take with `Amount` 100 and a short `Response`
  (say 2 s): both should end up sounding like the same singer through the same
  mic. Then put `Response` back to 20 s or more for real work.
- Mute the singer mid-phrase: the readout says `GATED` and the tilt holds
  instead of drifting.

## Tests

```
tools/render_test.py            # everything
tools/render_test.py tilt slope # named tests only
```

Renders happen headlessly through `reaper -newinst`, so they are safe to run
while your normal REAPER is open. Work files go to
`~/.cache/autotilt-rendertest` (`AUTOTILT_WORK` overrides;
`AUTOTILT_KEEP_DBG=1` keeps the generated debug build).

| Test | Asserts |
| --- | --- |
| `params` | all 16 sliders survived the header parse |
| `unity` | Amount 0 with no offset or trim is transparent — which also proves there is no latency to report |
| `trim` | **canary**: +6 dB of trim gives exactly ×1.9953, something a dead plugin passing audio through cannot fake |
| `tilt` | the static tilt response matches `tools/model.py` shelf-for-shelf |
| `internals` | band power normalisation, input RMS and the sensitivity constant, read out of a debug build generated from the real source |
| `comp` | Level Compensation holds broadband level, and the same render with it off moves by clearly more |
| `serialize` | a stored tilt is restored from the project chunk |
| `slope` | **end to end**: a −5.8 dB/oct source with a −3.0 dB/oct target comes out at −3.0 |
| `rates` | the tilt response matches the model at 44.1 k and 96 k |

`tools/model.py` is the reference implementation of the filter design and the
band analysis. **It and `Magnolius_AutoTilt.jsfx` must be edited together** — the tests
are only worth anything while they agree.
