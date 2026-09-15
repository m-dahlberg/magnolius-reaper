# Vocal Rider (JSFX)

A vocal rider for Reaper: continuously measures the vocal's loudness and smoothly
rides its gain toward a target level — gentler and more transparent than a
compressor. Optionally listens to a sidechain (the instrumental) and pushes the
vocal target up when the music gets loud.

## Install

```bash
ln -s "$(pwd)/Magnolius_VocalRider.jsfx" ~/.config/REAPER/Effects/Magnolius_VocalRider.jsfx
```

Then in Reaper: add FX on the vocal track → search **vocal rider** (listed under JS).
After editing the file, reopen the FX (or press Ctrl+S in Reaper's JS editor) to reload.

## Sliders

| Slider | What it does |
|---|---|
| Target level | The loudness the rider steers the vocal toward. Set it near your vocal's average level (watch the IN meter). |
| Ride range | Maximum boost/cut the rider is allowed to apply (± dB). |
| Ride speed | How quickly the gain moves. Lower = word-by-word, higher = phrase-level. Cuts react slightly faster than boosts to avoid pumping. |
| Noise floor | Below this input level the rider stops chasing and glides back to 0 dB, so silence and breaths never get boosted. |
| Sidechain influence | How many dB the target is raised when the sidechain is loud (full amount when the music is 12 dB above the target). 0 = off. |
| Vocal loudness window | RMS measurement window for the vocal. Shorter = snappier detection, longer = smoother. |
| Sidechain loudness window | RMS measurement window for the sidechain. |
| Output trim | Static make-up gain after the rider. |

## Sidechain hookup

1. On the vocal track: FX button → click the **2 in 2 out** button (pin connector) on the plugin → set track channels to 4.
2. On the instrumental track/bus: add a **send** to the vocal track, destination channels **3/4**.
3. In the plugin's pin connector, make sure input pins *Sidechain L/R* map to channels 3/4.
4. Raise **Sidechain influence** above 0.

The sidechain is analysis-only; it is never mixed into the output.

## Meter

- **IN** — vocal input level (blue), with the target (yellow tick) and noise floor (grey tick).
- **RIDE** — current gain: green right of center = boosting, orange left = cutting, dimmed grey while gated (input below noise floor).
