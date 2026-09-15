-- @noindex
-- Setting the dereverb's T60 and reduction from the measurement instead of by
-- hand.
--
-- The band ring figure is NOT a T60 and the README is emphatic about it: it is
-- the fastest decay a band achieves, and on the reference takes it reads
-- 0.14-0.18 s where the true T60 is nearer 0.44 s. That is why `t60_of` used
-- its SHAPE and took the level from a hand-set control.
--
-- What was never measured is the relationship between the two. It is not a
-- constant factor. `test/t60_calib_in_reaper.lua` drives a dry signal plus
-- combs of exactly known T60 through the same ring pass and sweeps the decay
-- from 0.15 s to 1.6 s:
--
--   true T60  0.15  0.20  0.30  0.40  0.55  0.70  0.90  1.10  1.60
--   ring p50  .108  .133  .164  .176  .202  .202  .216  .232  .248
--   ratio     1.4   1.5   1.8   2.3   2.7   3.5   4.2   4.8   6.4
--
-- The statistic compresses badly -- a 10.7x range of real decay arrives as a
-- 2.3x range of ring figure -- so ANY single factor is wrong nearly
-- everywhere, and the factor read off two takes at 0.44 s only ever fitted
-- rooms near 0.44 s. A power law fits the whole span to within 27 %:
--
--   T60 = 67.2 * ring^2.86
--
-- Two properties of that measurement are what make an auto mode defensible,
-- and neither was known before it was taken:
--
--   * it does not move with the wet/dry mix. Swept at 0.15, 0.35 and 0.70 the
--     readings differ by at most one histogram bucket, so the statistic is
--     measuring the room's decay and not the direct-to-reverberant ratio, and
--     no DRR term is needed.
--   * it does not move with the source. Noise bursts and a 12-harmonic stack
--     -- a flat spectrum and a voice's sparse one -- return the SAME figure at
--     both T60s where they were compared.
--
-- Cross-check: the law puts `Room resonance example.wav` at 0.46 s, against
-- the 0.44 s the README quotes from an independently calibrated estimator, and
-- 0.39 s once the safety factor below is applied -- which is where the hand-set
-- default of 0.40 s had already landed by ear. The auto mode reproduces the
-- by-ear answer on the take it was tuned on, and moves off it on other
-- material, which is the whole point.
--
-- Pure Lua: imports no `reaper`.

local M = {}

-- Measured in test/t60_calib_in_reaper.lua. Changing either of these without
-- re-running that suite is how a calibration silently becomes a guess.
M.RING_A = 67.2
M.RING_B = 2.86

-- The error is ASYMMETRIC. Under-estimating T60 makes the dereverb do less,
-- which is audible as "not enough" and costs nothing; over-estimating makes it
-- subtract the singer's own sustain, which is audible as warble and costs the
-- take. The fit's residuals run +27 % in the 0.30-0.55 s band where most vocal
-- rooms actually sit, so it is biased down to land that band slightly low
-- rather than a quarter high.
M.SAFETY = 0.85

-- Below this the ring figure is not reporting a room at all. Measured: with no
-- reverberation whatever, every band reports 0.041 s -- the burst's own release
-- seen through the 64 ms ring window -- and that floor does not move with T60
-- because there is nothing there to move it. A take reading near it gets an
-- auto T60 at the bottom of the range, so the dereverb does nothing, which is
-- the right answer for dry material.
M.DRY_FLOOR = 0.05

M.T60_MIN, M.T60_MAX = 0.10, 2.00
M.RED_MIN, M.RED_MAX = 6.0, 18.0

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- The calibrated law. `ring` is a ring figure in seconds -- the median across
-- bands, or one band's own.
function M.t60_from_ring(ring)
  if not ring or ring <= 0 then return nil end
  return M.SAFETY * M.RING_A * ring ^ M.RING_B
end

-- How far any one bin may be pulled down. This is a limit rather than a
-- target: the Wiener chain asks for whatever attenuation it asks for and this
-- only clips the extreme, so the job here is to stop a dry take being offered
-- 18 dB of reduction it can only spend on artifacts. There is no ground truth
-- for it the way there is for T60 -- it is a taste boundary -- so it is a
-- gentle function of the estimated decay, clamped hard at both ends.
function M.reduction_from_t60(t60)
  if not t60 or t60 <= 0 then return M.RED_MIN end
  return clamp(12.0 + 8.0 * math.log(t60 / 0.40, 10), M.RED_MIN, M.RED_MAX)
end

-- The estimate from the DECAY CUBE, which measures T60 directly instead of
-- calibrating the ring proxy. Preferred whenever the take has enough pauses;
-- `estimate` below falls back to the ring law when it does not. No safety
-- factor is applied here: the 0.85 exists to absorb the ring law's +27 %
-- residual in the 0.30-0.55 s band, and a direct measurement good to 7 % has
-- no such bias to absorb.
function M.from_decay(t60_med, nbands, pinned)
  if pinned then
    return nil, "the level statistic is pinned; the pause gate cannot be trusted"
  end
  if not t60_med or (nbands or 0) < 3 then
    return nil, "too few bands measured a decay in the pauses"
  end
  local t60 = clamp(t60_med, M.T60_MIN, M.T60_MAX)
  return { t60 = t60, reduction = M.reduction_from_t60(t60), dry = false,
           measured = true, ring = nil, raw = t60_med,
           clamped = (t60 ~= t60_med) }
end

-- The estimate the panel shows and the render uses, or nil when the
-- measurement cannot support one. Returning nil rather than a default matters:
-- the panel must be able to say "this file could not be measured" instead of
-- quietly applying a number nothing backs.
--
-- `ring_p50` is the median band ring figure; `nbands` how many bands produced
-- one at all. `pinned` is set when the level statistic is resting on edited-in
-- silence, in which case the ring floors -- and so the gate that produced
-- these figures -- are not trustworthy either.
function M.estimate(ring_p50, nbands, pinned)
  if pinned then
    return nil, "the level statistic is pinned; the ring gate cannot be trusted"
  end
  if not ring_p50 or (nbands or 0) < 4 then
    return nil, "too few bands produced a ring figure to take a median"
  end
  if ring_p50 <= M.DRY_FLOOR then
    return { t60 = M.T60_MIN, reduction = M.RED_MIN, dry = true,
             ring = ring_p50, raw = M.t60_from_ring(ring_p50) },
           "at the dry floor: nothing here decays slowly enough to measure"
  end
  local raw = M.t60_from_ring(ring_p50)
  local t60 = clamp(raw, M.T60_MIN, M.T60_MAX)
  return { t60 = t60, reduction = M.reduction_from_t60(t60), dry = false,
           ring = ring_p50, raw = raw, clamped = (t60 ~= raw) }
end

-- Per-band T60 for `t60_of`.
--
-- In manual mode the shape comes from `times[b] / median` -- a LINEAR tilt on
-- a hand-set level, which is the only thing available when the level is a
-- guess. With the law calibrated there is no need to approximate: it is
-- monotone, so applying it band by band gives exactly the same median it gives
-- the median, and it gets the spread right instead of understating it by the
-- 2.86th power.
--
-- `trim` is the T60 scale control, which stays live in auto mode: the analysis
-- supplies the absolute level and the ear supplies the last word on it.
function M.band_t60(ring_b, trim)
  local t = M.t60_from_ring(ring_b)
  if not t then return nil end
  return clamp(t * (trim or 1.0), 0.05, 4.0)
end

return M
