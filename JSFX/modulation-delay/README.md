# Modulation Delay (JSFX)

A stereo modulation delay for REAPER with three characters, **Digital**, **BBD**
and **Tape**, from one delay engine. The character comes from what happens
inside the feedback loop, not from the delay line: each repeat gets darker,
thinner and a little more smeared, and the modulation moves the read position
inside the loop, so every repeat drifts a little further than the one before.

## Install

```bash
D=~/.config/REAPER/Effects/Magnolius
ln -s "$PWD/Magnolius_ModulationDelay.jsfx"     "$D/"
ln -s "$PWD/Magnolius_ModulationDelay.help.txt" "$D/"
mkdir -p "$D/gui_kit"
for f in gui_kit/*; do ln -sn "$PWD/$f" "$D/$f"; done   # skips files already there
```

Symlink, never copy: a copy goes stale silently. The knobs and panels load
from `gui_kit/` and the help page from the `.help.txt`, both next to the
`.jsfx` as REAPER sees it. If an image is missing the header says *images
failed to load*. ReaPack installs all of it.

Add FX on a track and search **mod delay** (listed under JS). The panel shows
its version in the bottom left. After editing the file, reopen the FX (or
Ctrl+S in REAPER's JS editor) to reload.

Outputs 1/2 are the mix. Outputs 3/4 are the wet signal alone (after ducking,
width and output trim, before the mix), for parallel processing; give the
track four channels to use them.

## Signal flow

The input and the loop return are summed into the delay line. Its modulated
output goes through the loop chain, and the result goes two ways: to the output
stage, and, times the feedback gain, back into the delay line. The dry signal
bypasses everything and meets the wet at the mix.

The chain order is fixed: **HPF and LPF, head bump (Tape), saturation, DC
blocker, smear**. The first echo goes through the chain once and plays at full
level (the feedback gain only scales what goes round again), the second echo
twice, and so on, so the colour compounds. Everything in the loop compounds;
everything in the output stage (ducking, width, mix, trim) does not.

### Decay curve

Feedback sets how many repeats it takes to fall 60 dB, `N = 3 / -log10(fb)`.
Curve sets the shape of the fall: the level of echo `m` is
`-60 dB x ((m-1)/N)^p` with `p = 2^(2 c)` and `c` = Curve / 100. At 0 this is
the plain constant gain per repeat. Positive holds the early repeats up and
drops the later ones faster; negative drops the first repeats quickly and
leaves a long tail. Every curve crosses -60 dB at repeat `N + 1`.

The loop has to know how many times a signal has been round, so the delay
keeps a tiny second ring (one entry per 16 samples) of the energy-weighted
repeat count of what it wrote. New input into a line that still holds echoes
therefore gets the average of the two. Above 100 % feedback, and at Curve 0,
this is bypassed and the gain is the plain feedback.

## Controls

Every knob has a value field: click to type, drag to scrub. Sliders are hidden
from the generic list but stay automatable under the same names, in this order.

| # | Control | Range | Default | Notes |
|---|---|---|---|---|
| 1 | Time | 1-2000 ms | 375 | Greyed while Sync is on, then shows the synced time |
| 2 | Sync | Off, 1/1 ... 1/32 | Off | Follows tempo changes within one block |
| 3 | Sync type | Straight, Dotted, Triplet | Straight | Synced times stop at 4 s |
| 4 | R offset | -50 to +50 % | 0 | Moves the right channel's time |
| 5 | Stereo mode | Stereo, Ping-pong, Cross | Stereo | Ping-pong sums the input to mono |
| 6 | Cross amount | 0-100 % | 0 | Cross mode only |
| 7 | Feedback | 0-110 % | 40 | Above 100 % saturates into a wash |
| 8 | Loop HPF | 20 Hz-5 kHz | 100 | Exactly off at 20 Hz |
| 9 | Loop LPF | 200 Hz-20 kHz | 6 kHz | Exactly off at 20 kHz |
| 10 | Drive | 0-100 % | 20 | Soft clip in the loop; 0 is clean |
| 11 | Smear | 0-4 stages | 0 | Short all-passes, continuous (2.5 = two and a half) |
| 12 | Mod rate | 0.05-10 Hz | 0.6 | |
| 13 | Mod depth | 0-10 ms | 1.5 | Panel header shows peak cents |
| 14 | Mod shape | Sine, Triangle, Random | Sine | |
| 15 | Depth scaling | Fixed, Relative | Fixed | Relative: depth x time / 250 ms |
| 16 | Stereo phase | 0-180 deg | 90 | Between the L and R LFOs |
| 17 | Wow | 0-100 % | 0 | Tape only |
| 18 | Flutter | 0-100 % | 0 | Tape only |
| 19 | Character | Digital, BBD, Tape | BBD | Changing it clears the delay |
| 20 | Time change | Glide, Crossfade | Glide | The panel sets it with Character; never locked |
| 21 | Glide time | 20-500 ms | 120 | Glide only |
| 22 | Duck amount | 0-24 dB | 0 | |
| 23 | Duck threshold | -60 to 0 dB | -24 | Detector listens to the dry input |
| 24 | Duck release | 50-1000 ms | 250 | Attack fixed at 10 ms |
| 25 | Width | 0-150 % | 100 | M/S, wet only |
| 26 | Mix | 0-100 % | 30 | Equal-power |
| 27 | Wet only | Off, On | Off | 100 % wet without touching Mix |
| 28 | Freeze | Off, On | Off | fb 100 %, input muted, loop filters bypassed |
| 29 | Output | -12 to +12 dB | 0 | |
| 30 | Loop HPF slope | 6, 12 dB/oct | 6 | Appended after the brief's 29 |
| 31 | Loop LPF slope | 6, 12 dB/oct | 6 | |
| 32 | Decay curve | -100 to +100 % | 0 | Shape of the fall; Feedback sets the repeat count |

The **CLEAR** button (not a parameter) empties the delay.

## Characters

| | Interpolation | Time change | Extra |
|---|---|---|---|
| Digital | Cubic | Crossfade | None, a clean reference |
| BBD | Linear | Glide | Loop LPF tracks the delay time (corner = 1200 Hz.s / time, so darker at long times); gentle 4:3 companding; hiss at -70 dBFS at full level, about -86 in silence |
| Tape | Cubic | Glide | Wow (0.3-2 Hz, drifting) and flutter (6-20 Hz); +2.5 dB head bump at 110 Hz; saturation biased for even harmonics, removed by the DC blocker |

The BBD clock tracking is an approximation, not a model of any chip. The noise,
companding, wow and flutter depths are judgement calls to tune by ear:
`K_BBD_NZ`, `K_CA`, `K_BBD_FC`, `K_WOW_S`, `K_FLT_S` at the top of `@init`.

## How the behaviour rules are met

| Rule | How |
|---|---|
| Tempo tracking | The synced time is recomputed every `@block`; the Time slider is rewritten and the host told with `sliderchange` |
| Immediate response | Glide slews from the next sample; Crossfade starts a second head within the block (a change mid-fade waits at most 30 ms) |
| No stale audio | `age` counts samples written since the last clear; any read reaching back past it is silence, so a clear is O(1). It runs on Clear, Character change, transport start, and a break in the play position (seek, loop wrap, host bypass), with a 5 ms fade when a tail is audible |
| No zipper | Every continuous control is a 20 ms one-pole; filter corners are smoothed in the log domain and refreshed every 16 samples |
| No DC | No floor quantisation in the loop; DC blocker after the saturation |
| Sample rate | Everything derives from `srate` in `@init`; the rings are sized from it |
| Host state | Sync rewrites Time and calls `sliderchange` |
| No dead weight | Ring size is the next power of two above `srate x 4.06 s`, not a 192 kHz worst case |
| Denormals | Loop values, filter states and smoothers snap to zero; REAPER itself adds ~1e-16 to every track, so true digital silence reads 1e-16 |

Limits worth knowing: a loop-region wrap clears the tail at the loop point; the
read never gets closer than 4 samples to the write; free time stops at 2 s,
synced time at 4 s; feedback above 100 % is held at about +6 dBFS by the loop's
soft-clip ceiling.

## Tests

```bash
python3 tools/render_test.py            # 32 headless render tests
python3 tools/render_test.py delay sync # just those
python3 tools/gfx_test.py               # drives @gfx in a throwaway REAPER
python3 ~/.claude/skills/jsfx-gui-kit/scripts/check_jsfx.py Magnolius_ModulationDelay.jsfx
```

Renders go through the real plugin in an isolated REAPER (`-newinst`), so they
are safe while your own REAPER is open. Work files live in
`~/.cache/moddelay-rendertest`. The GUI test proves `@gfx` runs, that no image
failed to load, and that a drag and a click reach both the slider and the host;
how it looks needs a screenshot.

## Quick sanity checks by ear

1. Digital, Mix 100 %, Feedback 0: a clap returns exactly once, `Time` later.
2. Feedback 60 %: each repeat is 4 dB quieter. Turn Curve up: the first repeats hold, then drop; down: the first drop is large and a tail follows.
3. Feedback 110 %, Drive 0: the repeats build to a steady wash and stay there.
4. Time automation in Glide: the echo bends like tape. Crossfade: it does not.
5. Sync 1/4 with a tempo ramp: the repeats follow it.
6. Freeze while the tail rings: it holds at one level and tone.
7. Change Character during a long tail: the tail stops instead of replaying.
