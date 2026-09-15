# Mix Reference (JSFX)

A REAPER JSFX plugin for A/B-ing your mix against up to six reference tracks,
with a 1/3-octave tonal difference curve and a per-band dynamics comparison.

## Install

```
ln -s "$PWD/Magnolius_MixReference.jsfx" ~/.config/REAPER/Effects/Magnolius_MixReference.jsfx
mkdir -p ~/.config/REAPER/Data/mixref
```

Drop your reference WAVs into `Data/mixref/` **before** opening the plugin —
file sliders only list what was there when the dropdown was populated.

Put the plugin on the master. `Analyse mix from` defaults to Main 1/2, so no
extra routing is needed; the sidechain option (ch 3/4) is there if you want to
analyse something other than what the plugin is inserted on.

## Tests

Headless REAPER renders, checked with pure-Python analysis. They run while your
normal REAPER is open.

```
python3 tools/make_test_refs.py     # once: writes reference WAVs to Data/mixref/
python3 tools/render_test.py        # all tests
python3 tools/render_test.py refplay analysis
```

15 tests: slider-header parse (via a ReaScript probe), bit-transparent
passthrough, sample-exact reference playback / looping / trim / mono / 96 kHz
resampling, short-file rejection, six slots at once, and — via a generated
debug build that streams internals out as audio — analyser calibration, auto
gain match, dynamics percentiles, freeze and the analysis-source switch.

`tools/render_test.py` regenerates `mix_reference_dbg.jsfx` from the real source
on every run and deletes it afterwards, so the tested code can never drift from
the shipped code. Set `MIXREF_KEEP_DBG=1` to keep it for inspection.

### Things that bit, and that the tests now pin down

- **@gfx and the audio thread share every global.** A loop counter named `i` in
  both stomps `r_pos`/`r_rate` mid-loop. Audio-side counters are `ai`, UI-side
  `gi`/`gj`, and nothing is named in both. Offline renders never run @gfx, so no
  render test can catch a regression here — `tools/` has no substitute for
  keeping the names disjoint.
- **The band-power scale is a real spec, not an arbitrary constant.** A band
  holding a sine of amplitude A must read `10*log10(A^2/2)`. It cancels out of
  everything the GUI plots, so only the `analysis` test can see it wrong.
- **REAPER zeroes a track's entire render if the FX emits samples far outside
  ±1.** A debug probe that wrote a raw `-1000` produced a completely silent
  render, which is indistinguishable from a dead plugin.
- **Loop-phase alignment aliases.** 200 Hz repeats every 240 samples, so many
  offsets fit a fade-free window; only the 64-sample loop-edge fade picks out
  the true one. `align2()` re-scores every coarse candidate over the full
  window for this reason.
