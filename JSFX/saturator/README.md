# Saturator

A REAPER JSFX saturator with two independent amounts: **Symmetric** adds odd
harmonics, **Asymmetric** adds even harmonics, so you dial the colour instead of
picking a preset curve. A **Slew** stage softens fast, loud transients first,
like an op-amp or tape running out of speed, and **Knee** sets where the odd
curve bends. Static auto gain, parallel Mix, 1x / 2x / 4x oversampling with
anti-aliased curves, and a custom interface with input and output meters.

The transfer curves and ideas come from Airwindows (Console, Mojo, Spiral,
Dyno, Coils, Desk), rebuilt from scratch as one small per-channel function
with named constants. No Airwindows code is reused.

Latency: 0 / 43 / 46 samples at 1x / 2x / 4x, reported to REAPER (PDC).

## Install

Through ReaPack, with the rest of the Magnolius set. For development, symlink
— never copy. A plain copy goes stale silently the next time the repo changes,
and nothing in REAPER warns you:

```
ln -s "$PWD/Magnolius_Saturator.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_Saturator.jsfx"
ln -s "$PWD/Magnolius_Saturator.help.txt" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_Saturator.help.txt"
ln -s "$PWD/gui_kit/bar_cyan_grid.png" \
      ~/.config/REAPER/Effects/Magnolius/gui_kit/bar_cyan_grid.png
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: Saturator** to a track.

The interface loads its artwork at runtime, so `gui_kit/` has to be reachable
from the plugin **as REAPER sees it**. The Magnolius Effects folder shares one
`gui_kit/`; besides the common files this plugin needs `knob_orange_grid.png`,
`button_orange.png` and `bar_cyan_grid.png`. If the header says *images failed
to load*, that folder is what is missing.

If a change to the source seems to have no effect, check the link first:

```
readlink -f ~/.config/REAPER/Effects/Magnolius/"Magnolius_Saturator.jsfx"
```

## Controls

Every control is a hidden, automatable parameter (the panel replaces REAPER's
generic slider list). Ctrl-click resets a knob, Shift gives fine control, and
clicking a value field lets you type.

| Panel | Control | Range (default) | What it does |
|---|---|---|---|
| Header | Oversampling | 1x / 2x / 4x (2x) | Runs the stages at a higher rate. 2x is clean at any setting, 4x cleaner still, 1x is for gentle settings. Changes latency; may click once when changed. |
| Header | Fit / 100 % … 200 % | Fit | Interface scale, shared by every Magnolius plugin. |
| Drive (cyan) | Input | −18 … +18 dB (0) | Drives the stages. With Auto Gain on it changes the amount of saturation, not the level. |
| | Slew | 0 … 100 % (0) | Saturates the *step* between samples: loud high frequencies and sharp transients round off, quiet material and lows do not. |
| | IN meter | −60 … +6 dBFS | Peak after Input, with peak hold. |
| Colour (orange) | Asymmetric | 0 … 100 % (0) | Even harmonics (2nd, 4th …): warmer, thicker. |
| | Symmetric | 0 … 100 % (0) | Odd harmonics (3rd, 5th …): denser, louder. |
| | Knee | Soft / Medium / Hard (Medium) | Where the Symmetric curve bends. Same small-signal gain, odd harmonics only; a change of feel, not colour. Crossfaded, so it can be automated. |
| Output (cyan) | Mix | 0 … 100 % (100) | Parallel blend against a time-aligned dry signal. Linear law (dry and wet are highly correlated). |
| | Output | −18 … +18 dB (0) | Final trim. |
| | Auto Gain | Off / On (On) | Static level compensation, so you judge colour rather than loudness. |
| | Δ readout | | Output RMS minus input RMS over ~300 ms. Near 0 dB means Auto Gain is holding. |
| | OUT meter | −60 … +6 dBFS | Final output peak, with peak hold. |

## How it is put together

```
x -> Input -> upsample -> Slew -> Asymmetric -> Symmetric(Knee)
  -> out = dry + HPF_5Hz(stages - dry) -> auto gain, Mix -> droop EQ
  -> downsample -> Output
```

- **Slew** (after Desk): `y += sign(d)·sin(min(|d|σR, π/2))/(σR)` with
  `d = x − y[n−1]`, `σ = 5·knob²` and `R = OS rate / 48 kHz`. R makes the
  ceiling a slope per second, so the stage sounds the same at every sample rate
  and oversampling factor. 0 % bypasses it exactly.
- **Asymmetric** (after Coils): `(1−A)x + A·(sin(gx+b) − sin b)/(g cos b)`,
  `b = 0.7·A` rad, `g = 1 + A`. Unity small-signal gain, offset removed.
- **Symmetric** (after Console; Knee after Mojo / Spiral / Dyno):
  `(1−S)x + S·f_k(gx)/g`, `g = 1 + 2S`, `f_k(u) = sin(u|u|^k)/|u|^k` with
  k = 0.25 / 1 / 4.
- Each curve is clamped at its **peak** (for f_k, where `tan v / v = (k+1)/k`,
  `v = u|u|^k`), so it flattens with a continuous slope instead of folding.
- **Anti-aliasing**: at 2x and 4x both curves run first-order ADAA
  (antiderivative anti-aliasing). The antiderivative is closed form for the
  asymmetric curve and a Hermite table with exact slopes for f_k. Polyphase
  Kaiser halfbands do the resampling (81 taps; a 21-tap second stage at 4x).
- **Auto gain** is a table measured by `tools/calibrate.py` on pink noise
  (20 Hz up, −18 dBFS RMS): Input × Slew × Asym × Sym for each Knee, read with
  multilinear interpolation every 32 samples and ramped in between. Input is
  divided out exactly.
- Every gain and amount is smoothed per sample (one pole, 20 ms) and snaps onto
  its target, so neutral settings are exactly neutral.

### Where it departs from the brief, and why

1. **Asymmetric gets a dry crossfade** like Symmetric. The brief's formula on
   its own gives `sin(x)` at 0 %, which adds odd distortion and breaks the null
   test.
2. **The DC blocker filters the residual** (stages minus dry), at the
   oversampled rate, instead of the whole signal. A 5 Hz high-pass on the full
   signal shifts low-frequency phase and fails the −120 dB null. The residual
   carries all of the Asymmetric stage's offset, so the DC is still removed;
   input DC passes untouched.
3. **The Knee curves clamp at their true peak**, `tan v / v = (k+1)/k`.
   Clamping the inner argument at π/2 lets f_k fall again first, which is the
   fold-over the brief wants to avoid.
4. **ADAA**, which the brief does not mention. At full Symmetric the drive
   (g = 3) clips a 0 dBFS 10 kHz sine hard enough that plain oversampling
   leaves aliasing at −33 dB (2x) and −44 dB (4x), whatever the filters. ADAA
   meets the target. On a curve's linear part it is `(1 + z⁻¹)/2`, so the dry
   path is aligned by exactly the same averages (Mix never comb-filters) and a
   fixed FIR (`tools/design_comp.py`) undoes the resulting `cos²(ω/2)` droop to
   ±0.08 dB at 20 kHz.
5. **The auto-gain table includes Input.** How hard the curves are driven
   depends on Input, so dividing out its gain alone cannot hold ±1 dB.
6. **Calibration noise is band-limited to 20 Hz upward.** Full-range pink
   noise's sub-audio wander moved the measured level change by ±1 dB from one
   seed to the next at heavy drive; band-limited, it moves by under 0.2 dB.

### Measured (render tests, 48 kHz unless noted)

| Check | Result |
|---|---|
| Null, 1x, all neutral (Auto Gain on or off, any Knee) | bit-exact |
| Latency vs PDC, 2x / 4x | aligned (residual 0.001 / 0.0006 on content to 12 kHz) |
| Symmetric alone, every Knee, −18 / −6 / 0 dBFS | even harmonics below −170 dB |
| Asymmetric alone | H2 dominant at every level |
| THD vs each knob, 5 % steps | rises every step, no kinks |
| Fold-over, input to +36 dBFS into the curves | peak-to-peak rises every cycle |
| Knee at −6 dBFS, Symmetric 25 % | THD 0.56 % > 0.42 % > 0.09 %, small-signal gain identical |
| Slew 100 %: 10 kHz 0 dBFS / 1 kHz 0 dBFS / 10 kHz −30 dBFS | −14.0 / 0.0 / −0.02 dB |
| Slew across 44.1 / 48 / 96 kHz, 2x and 4x | within 0.17 dB |
| Aliasing, 10 kHz 0 dBFS, full Symmetric, 2x (Soft / Medium / Hard) | −59.1 / −63.1 / −62.6 dB |
| Same at 4x | −77.6 / −81.8 / −77.3 dB |
| DC, Asymmetric 100 %, 50 Hz 0 dBFS | −176 dBFS |
| Auto gain, 14 settings, unseen noise | within 0.30 dB |
| Fast automation of every control incl. Knee | no clicks (2nd difference below a static reference) |
| 44.1 vs 48 vs 96 kHz | gain within 0.004 dB, harmonics differ by < −75 dB |

Two numbers miss the brief, and the tests hold them to the measured values
instead:

- **Soft at 2x aliases at −59 dB**, 1 dB short of −60. The product is the 11th
  harmonic folding at the oversampled rate, inherent to Mojo's shape at g = 3;
  4x is at −78 dB.
- **Slew at 1x** sits within 0.68 dB of the oversampled result rather than
  0.5 dB. A 10 kHz tone at 1x has only 4.4 samples per cycle, so the steps the
  stage sees are smaller than the slope it models. 2x and 4x agree within
  0.17 dB at every rate.

## Quick sanity checks (by ear)

- All amounts 0 %, Mix 100 %, Input and Output 0 dB: bypass and engage should be
  indistinguishable.
- Symmetric alone on a bass: denser, flatter peaks. Asymmetric alone: thicker,
  warmer. Turn Input up with Auto Gain on: more colour, same loudness (watch Δ).
- Slew 100 % on cymbals or a bright vocal: softer top on loud hits, quiet parts
  unchanged.
- Switch Knee on a sustained note: the feel changes, the level should not jump.

## Files and tools

| Path | What |
|---|---|
| `Magnolius_Saturator.jsfx` | The plugin. The auto-gain table near the top of @init is generated. |
| `Magnolius_Saturator.help.txt` | The in-plugin help (the **?** button). |
| `gui_kit/` | Interface artwork and the widget library. |
| `tools/model.py` | Pure-Python reference that mirrors the DSP sample for sample. **Edit together with the .jsfx.** |
| `tools/render_test.py` | Headless REAPER render tests: model match plus every acceptance test above (`render_test.py` or `render_test.py model alias`). |
| `tools/gfx_test.py` | Floats the panel in a throwaway REAPER and checks that @gfx runs and its edits reach the DSP. Needs a display. |
| `tools/calibrate.py` | Measures the auto-gain table and writes it into the .jsfx (about 10 min on 8 cores); `--check` re-checks off-grid points. Rerun after any change to the curves, drives or Slew. |
| `tools/design_comp.py` | Designs the ADAA droop-compensation FIRs. |
| `tools/mockup.py` | Renders the panel layout from the real artwork. |

## Open items

- **By ear:** B_MAX (0.7 rad), SLEW_MAX (5) and the drive laws (g = 1 + A,
  g = 1 + 2S) were set by measurement. They need a listening pass on vocals,
  bass and a full mix. Changing any of them means rerunning `calibrate.py`.
- Program-dependent asymmetry (Righteous4-style) and Coils2-style hysteresis are
  out of scope for v1.

## Credits and licence

The curves and ideas are from [Airwindows](https://github.com/airwindows/airwindows)
by Chris Johnson (MIT licence): Console and Spiral (Medium), Mojo (Soft), Dyno
(Hard), Coils (Asymmetric) and Desk (Slew). Behaviour was checked against those
plugins; no code was copied, so no Airwindows notice is carried here. Where this
differs on purpose: Mojo drives at π/2 and Dyno scales its output by 1.165, but
here every curve has unity small-signal gain and the knob sets the drive; Coils
runs its sine on the difference from a filtered copy (a transformer model), but
here it is static; Desk measures the step from the previous input and leaks in
some of the raw signal, but here the step is from the previous output, as the
brief specifies.

Licensed GPL-3.0-or-later, like the rest of the repository.
