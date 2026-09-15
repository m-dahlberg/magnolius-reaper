# Convolution Reverb (JSFX)

A REAPER JSFX true-stereo convolution reverb, extracted from the reverb stage
of `Magnolius_PerceptualEQ.jsfx` as a standalone plugin. Uniform partitioned FFT
convolution with a 4-channel (true-stereo) impulse response, PDC-reported
latency, and sample-aligned dry/wet mix.

Wet-path shaping: pre-delay, IR length (stretch), and 12 dB/oct high-pass and
low-pass. Plus a built-in IR browser with a search field and folder list.

## Install

Symlink (do not copy — a copy goes stale silently) `Magnolius_ConvolutionReverb.jsfx`
into REAPER's effects folder:

```sh
ln -s "$(pwd)/Magnolius_ConvolutionReverb.jsfx" ~/.config/REAPER/Effects/Magnolius_ConvolutionReverb.jsfx
```

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
case-insensitive), Backspace to erase, Esc to clear, ↑/↓ and PgUp/PgDn to move,
Enter to load. Click a folder to narrow, click a file to load it, mouse wheel
scrolls.

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

Details worth knowing:
- Engine: uniform partitioned FFT convolution, 2048-sample partitions. The
  one-partition latency is reported to REAPER (PDC), which compensates it
  automatically; the dry path is internally delayed to stay sample-aligned
  with the wet path. **Pre-delay is not latency** — it is an internal delay on
  the wet path only, and does not change the reported PDC.
- IRs are capped at 262144 samples (~5.5 s at 48 kHz) and energy-normalized on
  load, so switching IRs keeps a comparable wet level (a unit-impulse IR at
  100 % length passes at exactly 0 dB). The display says when an IR (or a
  stretched one) hit the cap.
- **IR length is a resampling stretch**, so it shifts the IR's spectrum the way
  playing a tape slower does — that is the intended character, not a bug. Above
  100 % it interpolates; below 100 % it box-averages the source span that maps
  onto each output frame, so shortening does not alias. The same anti-aliasing
  now applies to loading a 96 kHz IR into a 48 kHz project.
- Changing IR length re-resamples and re-FFTs the staged IR but does **not**
  re-read the file. Changing the IR itself does, on the audio thread — expect
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

## Testing

`tools/make_test_irs.py` writes synthetic test IRs (unit impulse, channel
swap, delayed impulse, 2-ch fallback, 96 kHz variant, dense 5.4 s hall) into
`~/.config/REAPER/Data/ReverbIRs/`.

`tools/render_test.py` is a headless end-to-end suite: it renders small REAPER
projects through the installed plugin (`reaper -newinst -nosplash
-renderproject`, safe to run while REAPER is open) and asserts on the audio —
unity gain through the convolver, true-stereo routing, partition indexing, IR
resampling, dry/wet alignment, pre-delay, IR stretch in both directions, the
filter magnitude responses (against a biquad reference model in the test), that
the filters never touch the dry path, and that a serialized browser selection
loads in preference to the file slider.

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
`.jsfx` together.

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
