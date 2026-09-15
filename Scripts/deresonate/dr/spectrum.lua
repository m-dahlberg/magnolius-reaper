-- @noindex
-- The statistic cube -> percentile curves and the smoothed references the
-- detectors measure against.
--
-- The fact that makes this design work: the kernel reduces the whole file to
-- one per-bin level histogram, and every curve below is derived from that in
-- under a millisecond. Moving a percentile or a smoothing width therefore
-- redraws the panel without re-reading a sample.
--
-- Three smoothing scales matter, and they detect different defects:
--   1/3 octave  vs its own envelope  -> narrow modes and hum
--   1/1 octave  vs a 2-octave trend  -> broad colouration
--   p20 - p90                        -> what the room adds on top of the source
-- Measured on real takes: a 1/3-octave curve divided by a 1/3-octave envelope
-- cancels any feature that wide, so the narrow detector is structurally blind
-- to broad humps. That is why `broad.lua` exists as a separate stage.
--
-- Pure Lua: imports no `reaper`.

local M = {}

M.FLOOR_DB = -140.0

-- Silence islands -----------------------------------------------------------
--
-- The percentile below is taken over every frame of the file, and that is only
-- the right statistic if every frame is a frame of the recording. Edited-in
-- silence is not: strip-silence, a hard noise gate, or the noise-shaped dither
-- a 16-bit master carries in its pauses all put a population at the very
-- bottom of every bin's histogram that the microphone never produced.
--
-- If that population is larger than the percentile being asked for, the
-- percentile lands inside it -- at every frequency at once. Measured on a
-- 74 s voice take whose pauses had been stripped (27 % of its frames): the p20
-- curve came back as a PERFECTLY FLAT LINE at the bottom of the level axis,
-- 0.0 dB of spread across the whole spectrum. Every detector here measures a
-- curve against a smoothed version of itself, and a constant minus its own
-- envelope is zero, so nothing could be detected and nothing said so. The
-- script's own reference takes sit at 0.4-4.3 %, five times under the
-- threshold where this bites, so no test in the repo could reach it.
--
-- What separates edited silence from a real noise floor is not its level --
-- that is set by the master's bit depth and moves from file to file -- but
-- that nothing lies between it and the material. A recording's own floor is
-- continuous with what sits above it, because every note decays through it.
-- So: step over a population that has a wide DEAD run above it.
--
-- Calibrated against real per-bin histograms. Within the programme material
-- the widest empty run measured was 6 buckets (on this repo's own
-- `Room resonance example.wav`), and the gap over an island was 27-30, so the
-- threshold sits at 8 with room either side.
local DEAD_FRAC     = 0.002   -- a bucket holding less of the bin than this is
                              -- empty for this purpose
local GAP_DB        = 8       -- empty buckets that mark a population as an island
local MAX_SKIP_FRAC = 0.5     -- never step over more than half the frames
local MIN_KEPT      = 30      -- nor leave fewer than this behind

-- The first bucket of `hist` that can hold programme material.
--
-- Returns from, kept, refused:
--   from     1-based bucket to start the percentile at
--   kept     frames at or above it
--   refused  true if an island was found but stepping over it would have
--            breached one of the two guards, so nothing was skipped
--
-- The guards are what stop this eating the signal. A bin whose content is
-- itself bimodal -- loud whenever a harmonic sweeps through it, at the floor
-- otherwise -- looks like an island from below, and stepping over its lower
-- mode would RAISE the percentile into the signal and manufacture a peak
-- exactly where there is none. Refusing is the safe failure: the curve stays
-- pinned, which is visible, rather than moving somewhere plausible and wrong.
function M.floor_bin(hist, total)
  local n = #hist
  total = total or 0
  if total == 0 then
    for i = 1, n do total = total + hist[i] end
  end
  if total == 0 then return 1, 0, false end

  local dead = total * DEAD_FRAC
  local from, skipped, refused = 1, 0, false

  for _ = 1, 8 do                      -- a file may hold more than one island
    -- the first bucket at or above `from` that holds anything real
    local b = from
    while b <= n and hist[b] < dead do b = b + 1 end
    if b > n then break end
    from = b

    -- walk up until a dead run long enough to be a gap, or the top
    local gap, j = 0, b
    while j <= n and gap < GAP_DB do
      gap = (hist[j] >= dead) and 0 or (gap + 1)
      j = j + 1
    end
    if gap < GAP_DB then break end                   -- no gap: b is the floor

    -- Every histogram ends in empty buckets -- the level axis reaches above
    -- full scale, so there is always a long dead run over the loudest frame.
    -- That is the end of the distribution, not a gap in it. A gap needs
    -- something on the far side of it.
    local nxt = j
    while nxt <= n and hist[nxt] < dead do nxt = nxt + 1 end
    if nxt > n then break end

    -- everything below the far side of the gap, counted from the bottom: this
    -- already includes anything skipped on an earlier turn of the loop
    local below = 0
    for i = 1, nxt - 1 do below = below + hist[i] end
    if below > total * MAX_SKIP_FRAC or total - below <= MIN_KEPT then
      refused = true
      break                                          -- `from` stays at b
    end
    from, skipped = nxt, below
  end

  if from > n then from = n end
  local kept = 0
  for i = from, n do kept = kept + hist[i] end
  return from, kept, refused
end

-- Per-bin floors for a whole cube, plus what they add up to. Computed once
-- per analysis rather than per curve: the floors depend on the cube alone, so
-- moving the percentile slider must not pay for them again.
function M.floor_bins(cube, enabled)
  local from, kept = {}, {}
  local worst_frac, refused_bins = 0.0, 0
  for k = 1, #cube do
    if enabled == false then
      local t = 0
      for i = 1, #cube[k] do t = t + cube[k][i] end
      from[k], kept[k] = 1, t
    else
      local f, kp, ref = M.floor_bin(cube[k])
      from[k], kept[k] = f, kp
      if ref then refused_bins = refused_bins + 1 end
      local t = kp
      for i = 1, f - 1 do t = t + cube[k][i] end
      if t > 0 then
        local frac = (t - kp) / t
        if frac > worst_frac then worst_frac = frac end
      end
    end
  end
  return { from = from, kept = kept,
           skipped_frac = worst_frac, refused_bins = refused_bins }
end

-- Interpolated percentile of one 1 dB-bucketed histogram.
-- `hist` is 1-based, bucket i covering [lev0+i-1, lev0+i).
-- `from` starts the walk above any edited-in silence; see M.floor_bin.
function M.percentile(hist, p, lev0, total, from)
  from = from or 1
  total = total or 0
  if total == 0 then
    for i = from, #hist do total = total + hist[i] end
  end
  if total == 0 then return nil end
  local want = p * total
  local run = 0
  for i = from, #hist do
    local c = hist[i]
    if c > 0 then
      if run + c >= want then
        -- linear inside the bucket, so a slider does not step
        -- bucket i is centred on lev0+(i-1) and spans half a dB either side,
        -- so a single occupied bucket returns its centre, not its top edge
        local frac = (want - run) / c
        return lev0 + (i - 1) - 0.5 + frac
      end
      run = run + c
    end
  end
  return lev0 + #hist - 1
end

-- Frequency of each cube point. Linear FFT grid; bin 0 is never included --
-- DC is an offset, not a tone, and 0 Hz has no place on a log axis.
function M.hz_axis(nbins, bin_hz)
  local hz = {}
  for k = 1, nbins do hz[k] = k * bin_hz end
  return hz
end

-- Percentile curve over every point of the cube. `floors` comes from
-- M.floor_bins and carries both the starting bucket and the frame count above
-- it, so the percentile is taken over the recording rather than over the
-- recording plus whatever silence was edited into it.
--
-- Omitting it computes them, rather than quietly reverting to the unguarded
-- statistic: the failure this guards against is silent, so a caller must not
-- be able to reach it by forgetting an argument. Pass the cached table when
-- the same cube is being re-curved, which is what the panel does on every
-- slider frame.
function M.curve(cube, p, lev0, floors)
  floors = floors or M.floor_bins(cube, true)
  local out = {}
  for k = 1, #cube do
    out[k] = M.percentile(cube[k], p, lev0,
                          floors and floors.kept[k] or nil,
                          floors and floors.from[k] or nil)
  end
  return out
end

local function span(hz, i, oct_w)
  local fc = hz[i]
  local lo, hi = fc * 2 ^ (-0.5 * oct_w), fc * 2 ^ (0.5 * oct_w)
  local a, b = i, i
  while a > 1 and hz[a - 1] >= lo do a = a - 1 end
  while b < #hz and hz[b + 1] <= hi do b = b + 1 end
  return a, b
end

-- Both smoothers weight each point by 1/f.
--
-- The cube sits on a LINEAR FFT grid, so the upper half of any octave holds
-- twice as many points as the lower half. Averaging with equal weight per point
-- therefore centres the window above the point it belongs to. Weighting by 1/f
-- makes the mean uniform in log-frequency, which is what "per octave" means.
--
-- Measured honestly: on a half-octave hump this shifts the deviation only from
-- 1.79 to 1.71 dB, so it is a correctness fix rather than a rescue -- the thing
-- that actually decides whether a broad hump is found is the choice of scales
-- in `broad.lua`, not the weighting within them.
local function weight(hz, j) return 1.0 / hz[j] end

-- Energy envelope: mean of POWER over the window. This is the right mean for
-- an envelope the prominence of a peak is measured against -- summing in dB
-- would let one deep null drag the envelope down and invent a peak beside it.
function M.smooth_power(curve, hz, oct_w)
  local out = {}
  for i = 1, #curve do
    local a, b = span(hz, i, oct_w)
    local acc, w = 0.0, 0.0
    for j = a, b do
      if curve[j] then
        local wj = weight(hz, j)
        acc = acc + wj * 10 ^ (curve[j] / 10.0); w = w + wj
      end
    end
    out[i] = (w > 0) and 10.0 * math.log(acc / w, 10) or curve[i]
  end
  return out
end

-- Trend line: arithmetic mean in dB. This is the right mean for a *baseline*
-- the broad detector measures a hump against -- a power mean is dominated by
-- the loudest point in the window, which is the hump itself, so the baseline
-- would ride up with it and hide what we are looking for.
function M.smooth_db(curve, hz, oct_w)
  local out = {}
  for i = 1, #curve do
    local a, b = span(hz, i, oct_w)
    local acc, w = 0.0, 0.0
    for j = a, b do
      if curve[j] then
        local wj = weight(hz, j)
        acc = acc + wj * curve[j]; w = w + wj
      end
    end
    out[i] = (w > 0) and (acc / w) or curve[i]
  end
  return out
end

function M.subtract(a, b)
  local out = {}
  for i = 1, #a do
    out[i] = (a[i] and b[i]) and (a[i] - b[i]) or nil
  end
  return out
end

-- Where the reverberant field is strong relative to the direct field.
-- p20 is tail-dominated, p90 direct-dominated; the difference, read against
-- its own broad trend, says what the ROOM adds rather than what the source
-- brought. Measured on a real take this is a smooth trend, not a peak, which
-- is why it sets a frequency-dependent dereverb strength rather than a filter.
function M.room_balance(p_lo, p_hi, hz, base_oct)
  local d = M.subtract(p_lo, p_hi)
  local base = M.smooth_db(d, hz, base_oct)
  return d, M.subtract(d, base)
end

-- Index of the point nearest a frequency, for probing a curve at a named Hz.
function M.index_of(hz, f)
  if #hz == 0 then return nil end
  local best, bd = 1, math.abs(hz[1] - f)
  for i = 2, #hz do
    local d = math.abs(hz[i] - f)
    if d < bd then best, bd = i, d end
  end
  return best
end

return M
