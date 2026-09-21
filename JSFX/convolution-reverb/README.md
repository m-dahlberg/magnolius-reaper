# Convolution Reverb (JSFX)

A REAPER JSFX true-stereo convolution reverb, extracted from the reverb stage
of `Magnolius_PerceptualEQ.jsfx` as a standalone plugin. Uniform partitioned FFT
convolution with a 4-channel (true-stereo) impulse response, PDC-reported
latency, and sample-aligned dry/wet mix.

Wet-path shaping: pre-delay, IR length (stretch), and 12 dB/oct high-pass and
low-pass. Plus a built-in IR browser with a search field and folder list.

The interface is built on the Magnolius GUI kit (`gui_kit/`): knobs and typed
value fields for every parameter, a decay view of the loaded IR, a scalable
layout and a built-in help panel (`Magnolius_ConvolutionReverb.help.txt`).

## Install

Symlink (do not copy — a copy goes stale silently) the plugin, its help file and
the GUI kit into REAPER's effects folder. All three have to be reachable from
where REAPER sees the `.jsfx`, or the plugin loads with no artwork and says so
in red across its title bar:

```sh
DEST=~/.config/REAPER/Effects/Magnolius
mkdir -p "$DEST"
ln -sfn "$(pwd)/Magnolius_ConvolutionReverb.jsfx"      "$DEST/"
ln -sfn "$(pwd)/Magnolius_ConvolutionReverb.help.txt"  "$DEST/"
mkdir -p "$DEST/gui_kit"
for f in gui_kit/*; do ln -sfn "$(pwd)/$f" "$DEST/gui_kit/"; done
```

The `gui_kit` assets are shared byte-for-byte with the other Magnolius plugins,
so linking one that is already installed is enough — but each plugin keeps its
own copy in the repo, because that is what ReaPack installs.

Then in REAPER: FX browser → refresh (F5) → "Convolution Reverb".

## Impulse responses

1. Create `~/.config/REAPER/Data/ReverbIRs/` and drop impulse-response WAVs in
   it (any bit depth REAPER can read; any sample rate — IRs are resampled to
   the project rate on load). **Subfolders are supported** and are the
   recommended way to organize a library.
2. Pick an IR either way — the last one you touch wins:
   - the **Reverb IR** file slider. REAPER recurses into subfolders on its own
     and lists them as `Bricasti M7/1 Halls 01 Large Hall, 48K`. This slider is
     automatable and needs no setup.
   - the **built-in browser** in the graphics pane: a search box, a folder
     list with per-folder counts, and a scrollable result list.
3. Balance *wet*/*dry* (−60 dB = fully off). The reverb is active whenever a
   valid IR is loaded.

Channel formats:
- **4-channel WAV = true stereo.** Channel order `LL, LR, RL, RR` (input
  letter first): ch1 = left input → left output, ch2 = left → right,
  ch3 = right → left, ch4 = right → right.
- 2-channel WAV = parallel stereo (ch1 = L→L, ch2 = R→R, no cross-feed).
- Mono WAV = the same IR on both channels.

### The IR browser and its index file

The browser needs a list of filenames, and JSFX cannot enumerate a directory.
REAPER's host owns the file slider's index→filename mapping: a plugin can read
only the *current* name (`strcpy_fromslider`), and writing the slider from code
— `slider_automate` included — changes the number but not the file. So the
browser loads by path with `file_open(#string)` and reads its names from a
plain-text index:

`~/.config/REAPER/Data/ConvReverbIRs.idx` — one IR path per line, relative to
`Data/ReverbIRs`. It lives in `Data/` and *not* inside `Data/ReverbIRs`,
because anything in that folder also shows up in the file slider's dropdown.

Generate or refresh it after adding IRs, then press **Rescan** in the plugin:

```sh
python3 tools/index_irs.py            # or pass a resource dir
```

or, from inside REAPER, run `tools/RescanReverbIRs.lua` (Actions → Load
ReaScript). Without the index the browser just says so; the Reverb IR slider
keeps working.

The browser's choice is stored in the project as a **path**, not an index, so
adding IRs later never silently repoints a saved project at a different file.

Browser keys: type to search (space-separated terms, all must match,
case-insensitive), Backspace to erase, Esc to clear (or the **x** in the search
box), ↑/↓ and PgUp/PgDn to move, Enter to load. Click a folder to narrow, click
a file to load it, mouse wheel scrolls.

Typing goes to the search box only while no value field is being edited and the
help panel is closed — a field drains the keyboard first, so typing a number
into one never leaks into the search.

## Interface

`@gfx 958 664`. A JSFX cannot resize its own window, so that literal is the only
real size; the scale menu in the title bar (Fit / 100 / 125 / 150 / 200 %)
scales the content inside whatever window REAPER gives it. The scale lives in
`gmem` under the shared `Magnolius` namespace, so it is the same across every
plugin in this repo, and in `@serialize`, so it saves with the project.

Panels, top to bottom:

- **The browser** — search box, Rescan, folder list, file list.
- **The loaded IR** — channel count, length after stretch, which source loaded
  it, and a decay view: the peak envelope of the IR against a **fixed** five
  second ruler, with the pre-delay drawn as the dim silent band before it. The
  axis never rescales, so changing IR length stretches the envelope rather than
  relabelling the ruler under it; a tail past 5 s is clipped at the right edge.
  `DECAY_SECS` sets the window. The envelope is the
  square root of amplitude, which keeps the tail readable without lifting the
  whole decay into a solid block the way a dB floor does. `rvb_build()` writes
  it (512 bins) on the audio thread; `@gfx` only reads it.
- **Shape** (cyan) pre-delay and length, **Filter** (orange) high- and low-pass,
  **Mix** (yellow) wet and dry, **Modulation** (cyan) depth, rate and onset.
  Modulation reuses the cyan filmstrip because the kit ships three knob
  colours and this is the fourth panel.

Neither of the top two panels carries a section header — what they are is plain
from what is in them.

Every knob drags vertically, takes Shift for fine, the wheel, and Ctrl-click to
reset. Every value field under a knob drags the same way or takes a typed number
on a single click. The filter knobs run a logarithmic taper so the low end is
not squeezed into the first tenth of the travel — the sliders themselves stay
linear in Hz, so automation and saved projects are unaffected.

Sliders 2–10 carry a leading `-`, so REAPER's generic controls stay hidden while
the parameters remain automatable. **Slider 1 deliberately does not**: a file
slider can only be driven by the host, so hiding it would remove the one IR
source that needs no index file.

## Controls

| Slider | Range | What it does |
| --- | --- | --- |
| Reverb IR | file list | Native file slider; recurses into subfolders. |
| Reverb wet | −60…+12 dB | Wet level; −60 = off. |
| Reverb dry | −60…+12 dB | Dry level; −60 = off. |
| Pre-delay | 0…500 ms | Delays **only** the wet path. Not latency. |
| IR length | 25…400 % | Resamples the IR, stretching or shortening the tail. |
| Wet high-pass | 20…2000 Hz | 12 dB/oct, wet only. 20 = off. |
| Wet low-pass | 200…20000 Hz | 12 dB/oct, wet only. 20000 = off. |
| Modulation depth | 0…100 % | Movement in the late tail. 0 = off, and then the output is bit-identical to a build without this feature. Also drives the sine-to-random blend. |
| Modulation rate | 0.05…2 Hz | LFO speed, and the bandwidth of the random walk. Slower than feels right is usually correct. |
| Modulation onset | 0…200 ms | Where "late" begins, measured from the start of the IR file. 0 = auto, and the field then shows what the detector chose (with a `?` if the cross-check disagreed). Changing it costs a rebuild. |

Details worth knowing:
- Engine: uniform partitioned FFT convolution, 2048-sample partitions. The
  one-partition latency is reported to REAPER (PDC), which compensates it
  automatically; the dry path is internally delayed to stay sample-aligned
  with the wet path. **Pre-delay is not latency** — it is an internal delay on
  the wet path only, and does not change the reported PDC.
- IRs are capped at `MAXPARTS * CONV_P` = 393216 samples (~8.2 s at 48 kHz, ~8.9 s
  at 44.1 kHz) and energy-normalized on
  load, so switching IRs keeps a comparable wet level (a unit-impulse IR at
  100 % length passes at exactly 0 dB). The display says when an IR (or a
  stretched one) hit the cap.
- **IR length is a resampling stretch**, so it shifts the IR's spectrum the way
  playing a tape slower does — that is the intended character, not a bug. Above
  100 % it interpolates; below 100 % it box-averages the source span that maps
  onto each output frame, so shortening does not alias. The same anti-aliasing
  now applies to loading a 96 kHz IR into a 48 kHz project.
- Changing IR length re-resamples and re-FFTs the staged IR but does **not**
  re-read the file. A rebuild costs far more than one audio block, so it is
  scheduled rather than done on the spot. The GUI writes the value live (so the
  field reads right and automation records the whole move) and holds
  `pend_lenhold` for the duration of the gesture; the rebuild fires on mouse up.
  A `~120 ms` debounce in `@block` covers what `@gfx` cannot schedule — length
  arriving through `@slider` as automation.
- The readout does **not** wait for the rebuild. Stretching is a pure time
  scaling of the same impulse, so `@gfx` scales the seconds figure — and with it
  the width the envelope occupies in the fixed window — by
  `rvb_len / ir_built_len`. `ir_built_len` is the length the current spectra were
  built at, the same pattern as `ir_built_srate`, and *not* `l_rvb_len`, which
  `@slider` moves the instant the knob does. When the rebuild lands the ratio
  becomes 1 and the preview hands over invisibly. The seconds figure is clamped
  to the same `MAXPARTS * CONV_P` ceiling the build applies, so it cannot
  promise a tail longer than you will get.
- `rvb_build()` never clears `ir_ready` or `env_n` on the way in — it assigns
  `ir_ready` once, at the end, from whether the build produced anything, and
  publishes the envelope by copying a completed `ENVW` into `ENV`. Clearing them
  up front meant `@gfx` saw "no IR loaded" for the whole length of every rebuild
  and flashed the orange warning for it. Changing the IR itself does, on the audio thread — expect
  a brief glitch when switching IRs during playback, as with any convolver.
- The filters are 2-pole Butterworth (RBJ) biquads on the wet signal only, and
  are always clamped below Nyquist. Their cutoffs glide over ~30 ms, so moving
  a knob during playback sweeps instead of stepping.
- Pre-delay changes equal-power crossfade over 512 samples between the old and
  new tap, rather than moving one read pointer (which would pitch-shift the
  tail).
- Long IRs cost real CPU (up to 512 spectra multiplied per partition at the
  cap). Offline renders are fine regardless; for live use with very long IRs,
  REAPER's anticipative FX processing absorbs the per-partition spikes.

## Late-tail modulation

A convolution reverb is a fixed linear filter, so its tail is frozen — the same
comb structure on every note. On sustained material that reads as a static,
slightly glassy quality that algorithmic hardware does not have. This adds slow
movement to the tail **only**, leaving the early reflections that carry source
position and room identity completely untouched.

**Where "late" begins is derived from each IR, not fixed.** The mixing time —
where countable reflections give way to a diffuse field that is statistically
noise — runs from about 10 ms in a small wooden room to 150 ms in a cathedral,
so one constant would be wrong for most of any library. `rvb_detect()` measures
it with an Abel–Huang normalised echo-density profile: over a sliding 20 ms
window, the fraction of samples above that window's own standard deviation,
divided by the 0.3173 that fraction converges to for Gaussian noise. The mixing
time is the first point that reaches 0.9 and *stays* there for 30 ms — without
that hold, a dense early-reflection cluster triggers it tens of ms early.
Excess kurtosis over the same window is a cross-check: it does not override the
answer, it just sets the `?` in the readout. Detection runs once per file, on
the raw staged audio at the file's own rate, so an IR length change rescales
the answer instead of re-deriving it.

Across all 134 IRs of the Samplicity M7 set the detector converged on every
one, with results from 34 to 150 ms (median 71) and the cross-check disagreeing
on two — Car Park and Arena, both genuinely slapback-heavy.

**The split is in the IR, not on a partition boundary.** Partitions are 2048
samples, or 42.7 ms, which would quantise those 134 detections onto four
possible split points with 83 of them landing on the same one. Instead
`rvb_split()` builds two small side stores covering just the partitions the
crossfade touches: `EARLY` holds `ir*(1-w)` and `LATEHD` holds `ir*w`, where `w`
ramps across a 30 ms crossfade at the detected onset. Past the fade `w` is 1, so
the late path reads `IRSPEC` — which still holds the whole, unweighted IR. That
is what keeps Depth = Off bit-identical: the unmodulated path never learns any
of this happened. The crossfade is amplitude-complementary rather than
equal-power, so the two halves sum back to the original exactly and Depth just
above Off sounds like Depth Off.

**The movement is moving delay taps, not rotated partitions.** The late
partitions are split into four contiguous groups, each convolved into its own
accumulator per IR path, and each group's time-domain output then runs through
its own interpolated delay line that the LFOs move. Delaying the output of a
linear filter *is* moving its taps, so this is the same physics as the hardware
— and far cheaper here than rotating the stored IR partitions, which would add
a second `convolve_c` per late partition per path to a plugin already at 0.58×
real time on a 5.4 s IR. Measured cost of the whole feature: **+8 %**.

Four groups is what decorrelates the tail; one delay across the whole late
region would slide it as a block, which is audible as pitch shift. Group phases
are golden-ratio spaced and the excursion (not the mean delay) is scaled per
group, so later tail moves more. Depth drives the sine-to-random blend as well
as the excursion, the way the hardware grades low/mid/high off one control.

The interpolator is a **first-order allpass**, deliberately. Linear and Lagrange
interpolators are lowpass filters that null at Nyquist for a half-sample delay,
and since the fractional part sweeps with the LFO that reads as a *moving* high
frequency loss — measured at −1.7 dB broadband with linear and −2.5 dB above
15 kHz with 4-point Lagrange. An allpass has unit magnitude at every frequency,
which is the premise: this is phase movement, and the spectral balance is
supposed to survive it. Measured tilt with the allpass is under 0.1 dB in every
band.

Stereo: the four IR paths are modulated **by input path**, never by output
channel. LL and LR share one delay, RL and RR share a second, offset in
quadrature. (Honest note: a build repaired to pair by output channel measured
the same on the image-stability test — in this architecture the delay lands on
each path's output, so both pairings hold a hard-panned source still. Pairing by
input is kept because it is the principled choice and costs nothing.)

Guards, all of which switch modulation off entirely:
- IRs under 500 ms — not enough diffuse tail, too much early structure. This is
  also what keeps cabinet impulses and correction curves out of it, since phase
  movement destroys exactly what those encode.
- Fewer late partitions than groups.
- Depth at 0, which drops back to the unmodulated code path and costs nothing.

Switching between the two structures happens only on a partition boundary and
hands the tail over exactly in both directions: going in, `OLAP_L/R` still holds
the whole IR's overlap, which is the late tail the groups cannot supply yet;
coming out, the group overlaps fold back into it once every delay has slewed to
a true zero. Neither direction needs a crossfade.

The random end runs off a seeded Park–Miller LCG rather than EEL2's `rand()`,
which cannot be seeded — two bounces of the same project have to match.

## Testing

`tools/make_test_irs.py` writes synthetic test IRs (unit impulse, channel
swap, delayed impulse, 2-ch fallback, 96 kHz variant, dense 5.4 s hall) into
`~/.config/REAPER/Data/ReverbIRs/`. Three of them exist for the modulation
work: `test_mix60.wav` has a **designed** 60 ms mixing time (sparse discrete
reflections, then continuous noise) so the onset detector has a known right
answer; `test_short4.wav` is 300 ms, under the floor where modulation must
switch itself off; and `test_ts4.wav` is a real true-stereo arrangement, where
each source's two mic channels are one room response at slightly different
times and levels. The dense hall's four channels are *independent* noise, so it
has no stereo image to hold still and cannot test coherence at all.

`tools/render_test.py` is a headless end-to-end suite: it renders small REAPER
projects through the installed plugin (`reaper -newinst -nosplash
-renderproject`, safe to run while REAPER is open) and asserts on the audio —
unity gain through the convolver, true-stereo routing, partition indexing, IR
resampling, dry/wet alignment, pre-delay, IR stretch in both directions, the
filter magnitude responses (against a biquad reference model in the test), that
the filters never touch the dry path, and that a serialized browser selection
loads in preference to the file slider.

Every one of those runs with the modulation depth pinned at 0 rather than at
the plugin's own default, which makes all of them bypass-null canaries: if
modulation ever leaks into the Off state they stop matching to 1.5e-08. The
modulation tests proper are:

| Test | What it pins down |
| --- | --- |
| `onset` | The detector, read back off the audio thread and checked against `tools/ir_onset.py` on the same file *and* against the designed 60 ms. |
| `modearly` | The central claim. Rendered as the IR itself (impulse in), everything before the crossfade is bit-identical at depth 0 and depth 100, while everything after it is not — so the test cannot pass on a build where modulation never engaged. |
| `modlevel` | Level and spectral balance survive. The HF-weighted figure is the one that matters: broadband RMS barely moved when a Lagrange interpolator was costing 2.5 dB above 15 kHz. |
| `modpan` | A hard-panned source does not move as depth rises. |
| `modshort` | A 300 ms IR bypasses modulation entirely. |
| `modonset` | The override actually moves the split, and the auto split lands where the detector said. |
| `moddet` | Two identical renders are bit-identical. |
| `cpu` | Cost per second of audio, unmodulated and modulated, with REAPER's startup differenced out. Fails above 1.0. |

One more, `case`, renders nothing: it scans the source for two global
identifiers that differ only in case. EEL2 identifiers are **case-insensitive**,
so a constant `NAME` and a runtime variable `name` are one variable. That
silently broke two things here — a `mod_sub` counter decrementing the `MOD_SUB`
update interval until the LFO ran every sample and divided by a negative, and
`pre_xf` zeroing `PRE_XF` so the pre-delay crossfade never ran at all in 1.3.
Neither raised an error anywhere and no render test could see either.

`tools/ir_onset.py` is the offline reference implementation of the detector and
the thing that says whether its numbers are plausible across a whole library.
It prints one line per IR, or `--profile <file>` to dump the full echo-density
and kurtosis curves. It and `rvb_detect()` in the `.jsfx` are two
implementations of one algorithm and must be edited together — the `onset` test
is what holds them to it.

```sh
python3 tools/ir_onset.py ~/.config/REAPER/Data/ReverbIRs/"Bricasti M7"
```

`index` is the one test that observes plugin internals rather than audio: @gfx
never runs in an offline render, so it generates a debug build from the real
source, feeds it a known index file, and reads back what the parser produced.
It saves and restores your real index around itself. `CONVRVB_KEEP_DBG=1` keeps
the generated build for inspection.

`tools/gfx_test.py` covers the IR browser, which no render can reach: @gfx runs
on the UI thread and never runs in an offline render. It generates a debug
build, opens the FX window in a throwaway REAPER instance (isolated via
`-cfgfile`, so your config is untouched), and makes @gfx run its own
search/filter steps and publish the counts through hidden sliders that a
ReaScript reads back. It needs a graphical session, and it checks the browser's
*logic* only — nothing available here can screenshot a JSFX graphics pane under
Wayland (`xwd` misses it, `x11grab` returns black), so how it looks is on you.

```sh
python3 tools/make_test_irs.py   # once
python3 tools/index_irs.py       # once, and after adding IRs
python3 tools/render_test.py     # all tests; or: render_test.py unity swap
python3 tools/gfx_test.py        # IR browser (needs a desktop session)
```

Run the suite after any DSP change. Note that the filter tests mirror
`biq_design()` in Python — edit `biquad()` in `tools/render_test.py` and the
`.jsfx` together, and the same goes for `ir_onset.py` and `rvb_detect()`.

One harness note: `RENDER_RANGE` mode 1 means "entire project", so the render
length is the item length plus REAPER's ~1 s tail and nothing else. There used
to be a `length` argument wired into the range-end field, which mode 1 ignores —
every render came out at 2 s however it was called, including the CPU test that
reported "render of 3.0s". Pass a longer `in_len` to render more audio.

## Quick sanity checks by ear

- Load `test_unity4.wav`, wet 0 dB / dry off: the output should be
  indistinguishable from the input.
- Load `test_swap4.wav`: left and right should swap.
- Load a real hall, dry off, and sweep **IR length** — the tail should get
  audibly longer and darker above 100 %, shorter and brighter below.
- Set **pre-delay** to ~120 ms on a percussive part: the reverb should arrive
  clearly after the transient, with the dry hit unmoved.
- Set **wet high-pass** to ~300 Hz: the tail should thin out while the dry
  signal keeps its low end.
- On a sustained pad with a long hall, A/B **modulation depth** between 0 and
  25 %: the tail should start breathing rather than sitting still, with no
  audible pitch wobble and no change to the attack, the stereo placement or the
  level. Then try 100 %: obvious shimmer and diffusion, early reflections still
  rock-steady.
- Feed a hard-panned mono source and raise depth: it must not drift toward the
  centre. If it does, modulation is leaking into the early region and the onset
  is too early.
- Sum to mono at a few depth settings and listen for the tail thinning or
  flanging. If it does, the two input-side LFOs have drifted too far apart.
- Try a library from a unit that modulates heavily in hardware — a 480L, 224 or
  PCM90 capture arrives with flutter already baked in by the sweep
  deconvolution, and adding movement on top can amplify it rather than mask it.
