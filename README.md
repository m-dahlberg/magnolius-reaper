# Magnolius

JSFX plugins and ReaScripts for REAPER, mostly built around vocal production:
levelling, de-noising, de-clicking, de-resonating, spectral matching and
dynamics.

## Install

Add this repository to ReaPack:

**Extensions → ReaPack → Import repositories…**

```
https://github.com/m-dahlberg/magnolius-reaper/raw/master/index.xml
```

Then **Extensions → ReaPack → Browse packages…** and install what you want.
JSFX land in `Effects/Magnolius/`, scripts in `Scripts/Magnolius/`.

Several scripts need [ReaImGui](https://github.com/cfillion/reaimgui), which
ReaPack will not pull in automatically — install it from the **ReaTeam
Extensions** repository first.

## What's here

### JSFX

| Plugin | What it does |
| --- | --- |
| Adaptive Compressor | Compressor whose threshold follows programme loudness, so one setting fits any input level. |
| Auto Tilt | Tilt EQ that measures the incoming spectral slope and corrects it continuously. |
| Convolution Reverb | True-stereo partitioned-FFT convolution from 4-channel IRs. |
| DeClick | Multiband click and mouth-noise repair, with lookahead as PDC. |
| DeNoise | Spectral noise reduction, ported from libspecbleach. |
| Loudness Simulator | Makes quiet monitoring sound like loud monitoring. Monitoring only. |
| LUFS Limiter | LUFS-S leveler into a true peak limiter. |
| Match EQ | Pulls the input spectrum toward a pink-noise reference. |
| Mix Reference | Six reference slots, tonal and per-band dynamics comparison. |
| Upward Compressor | Lifts what is below the threshold and leaves the peaks alone. |
| Vari-Mu Compressor | F670-style variable-mu compressor/limiter. |
| Variable Ratio Compressor | Solves for the ratio each passage needs. Single-band and 4-band. |
| Vocal Rider | Automatic gain riding with sidechain ducking. |

### Scripts

| Script | What it does |
| --- | --- |
| Auto Tilt | Matches one clip's spectral balance to another and renders a new take. |
| DeClick | Click repair with the threshold derived from each file's own distribution. |
| DeNoise | Offline denoising with the profile derived from the whole file. |
| DeResonate | Finds room resonances using the singer's pitch to separate them from harmonics. |
| Note Leveling | Levels a vocal per sung note, written as Pre-FX volume automation. |
| Track Manager | Nine named track groups on a numpad-driven panel. |
| Vocal Normalizer | Normalises through the melody's fundamental range, not K-weighted. |
| Vocal Splitter | Segments a take into phrases, breaths, consonants and sibilance. |

Four of these exist as both a plugin and a script — **Auto Tilt**, **DeClick**,
**DeNoise** and **Vocal Splitter**. The plugin is real-time; the script is
offline and can analyse the whole file before deciding anything, which usually
means less tuning. ReaPack's Type column tells them apart.

## Licensing

GPL-3.0-or-later, except where an upstream work requires otherwise:

- **DeNoise** — LGPL-2.1-or-later, matching libspecbleach by Luciano Dato.
- **Vari-Mu Compressor** — 3-clause BSD, derived from "Fairly Childish" by
  Thomas Scott Stillwell.

Those two carry their own `LICENSE` files.

## Development

Each package folder holds its own README. Most carry a `test/` or `tools/`
tree: headless render harnesses for the JSFX and in-REAPER test scripts for the
ReaScripts. Those trees ship in the repo but are excluded from the ReaPack
index.

Test and demo audio is **not** in git — it is regenerable from the fixture
generators in those same folders.
