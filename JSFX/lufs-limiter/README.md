# LUFS Limiter

Two stages in series: a slow **LUFS-S leveler** that rides the programme so
short-term loudness sits at or below a target, followed by a **true peak
limiter** that guarantees the sample ceiling.

Loudness normalisation and peak limiting are different problems, and a single
limiter asked to do both does neither well. Push a fast limiter hard enough to
hit a LUFS target and it works on the wrong timescale — it flattens transients
to fix a loudness reading that is averaged over three seconds. Split the job
and each stage can run at the timescale it belongs on: the leveler moves over
seconds and is inaudible, and the limiter only ever has the last dB or two of
peak control left to do.

## Install

Symlink — never copy. A plain copy goes stale silently the next time the repo
changes, and there is no warning anywhere in REAPER when it happens:

```
ln -s "$PWD/Magnolius_LUFSLimiter.jsfx" \
      ~/.config/REAPER/Effects/Magnolius/"Magnolius_LUFSLimiter.jsfx"
```

(macOS: `~/Library/Application Support/REAPER/Effects/`.) Then add
**JS: LUFS Limiter** to a track — normally last in the master chain.

Or install it from ReaPack, which is the same file and saves the bookkeeping.

## How it works

**Stage 1 — LUFS-S leveler.** A BS.1770 K-weighted power measurement over a
3-second sliding window, with 1–3 s of lookahead. Gain is ridden down smoothly
so short-term loudness stays at or below **LUFS-S Ceiling**. Because it sees
the loudness before it arrives, the ride is already in place when a loud
section starts rather than chasing it.

**Stage 2 — true peak limiter.** Turquoise Limiter S2 topology: 1 ms
lookahead, instant-attack envelope, a threshold/envelope transfer function and
a one-pole release. With **True Peak Detection** on, an 8× oversampled
polyphase FIR measures inter-sample peaks, so the ceiling holds after
conversion to lossy formats rather than only in the sample domain.

**Output trim** is last, after both stages.

> The **Lookahead** slider changes plugin latency and therefore PDC. Set it
> once and leave it — changing it mid-session shifts the whole master chain's
> latency.

## Controls

| Slider | Default | What it does |
| --- | --- | --- |
| LUFS-S Ceiling (LUFS) | −14 | The short-term loudness the leveler rides towards. −14 suits most streaming targets; −16 for podcast/spoken word. |
| Leveler Speed (ms) | 500 | How fast the leveler's gain is allowed to move. Slower is more transparent and less able to catch fast loudness changes. |
| Leveler Amount (%) | 100 | How much of the computed ride is applied. **0% bypasses stage 1** and leaves a plain true peak limiter. |
| Lookahead (s) | 1.5 | Stage-1 lookahead. More lookahead means a smoother ride into loud sections. **Changes latency.** |
| Limit Ceiling (dB) | −1 | Stage-2 output ceiling. −1 dBTP is the usual safe value for lossy encoding. |
| Limiter Release (ms) | 100 | Stage-2 recovery. Short values are louder and more audible; long values are cleaner and can duck. |
| True Peak Detection (TPL) | On | 8× oversampled inter-sample peak detection. Costs CPU; turn it off only if you know the output stays in the sample domain. |
| Output Trim (dB) | 0 | Final gain, after both stages. |

## Setting it up

Set **Limit Ceiling** first — it is a delivery spec, not a taste control.
Then set **LUFS-S Ceiling** to your loudness target and play the loudest
section: the leveler should be doing most of the work and the limiter should
be catching only occasional peaks. If the limiter is working constantly, the
leveler is set too slow or too weak.

The gain-reduction history display covers 8 seconds, which is deliberately
longer than the 3-second measurement window — it is there so you can see the
leveler's ride as a shape rather than a flickering number.

## Files

| File | What it is |
| --- | --- |
| `Magnolius_LUFSLimiter.jsfx` | The plugin. |
| `README.md` | This file. |
