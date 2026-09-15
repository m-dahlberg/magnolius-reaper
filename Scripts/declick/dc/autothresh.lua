-- @noindex
-- Adaptive De-Click -- the sensitivity threshold, derived from the material.
--
-- Pure Lua, no reaper dependency, so it is directly unit-testable -- which
-- matters more here than anywhere else in the script, because this is the one
-- stage that decides how much damage gets done.
--
-- The input is a histogram of every candidate event's OVERSHOOT: how far, in
-- dB, the click stood above its own local background, measured as
-- min(fg/bg_before, fg/bg_after). Real musical transients form a smooth,
-- tapering distribution; clicks sit past where that taper ends. The job is to
-- put the threshold in the gap, which is in a different place for every file.
--
-- Two independent estimators, and the HIGHER of the two wins when they
-- disagree: over-conservative is the correct failure direction, since a missed
-- click is recoverable by ear and a chewed consonant is not. Both values are
-- kept, because their disagreement is more informative than either number.

local M = {}

local MIN_EVENTS = 50      -- below this the distribution says nothing
local SMOOTH = 5           -- bins; 1.25 dB at the default bin width
local MIN_CLUSTER = 3      -- events that must remain above a candidate threshold
-- A knee has to actually bend. On a distribution with no shelf the curve is a
-- straight line in log space and every bin ties at a rounding error; without a
-- floor the argmax of that noise gets reported as a knee, which is worse than
-- reporting none, because "no gap here" is the answer the caller needs.
local MIN_KNEE_GAP = 0.35

function M.db_of(h, b) return h.lo + (b + 0.5) * h.bin end
function M.bin_of(h, db)
  return math.max(0, math.min(h.n - 1, math.floor((db - h.lo) / h.bin)))
end

local function smoothed(h)
  local s, r = {}, math.floor(SMOOTH / 2)
  for b = 0, h.n - 1 do
    local acc, cnt = 0, 0
    for j = math.max(0, b - r), math.min(h.n - 1, b + r) do
      acc, cnt = acc + (h.counts[j] or 0), cnt + 1
    end
    s[b] = acc / cnt
  end
  return s
end

-- Events at or above each bin. This *is* the detections-versus-threshold curve
-- the spec's knee search sweeps for, so the sweep costs nothing.
local function reverse_cumulative(h)
  local rc, acc = {}, 0
  for b = h.n - 1, 0, -1 do
    acc = acc + (h.counts[b] or 0)
    rc[b] = acc
  end
  return rc
end

local function percentile_bin(h, rc, total, p)
  local want = total * (1 - p)
  for b = 0, h.n - 1 do
    if (rc[b] or 0) <= want then return b end
  end
  return h.n - 1
end

-- A. Tail departure. Fit the bulk in log-count space, extrapolate it outward,
-- and walk up until the empirical count stands `factor` clear of the fit. That
-- crossover is where the click population takes over from the musical taper.
local function tail_departure(h, sm, rc, total, factor)
  local b50 = percentile_bin(h, rc, total, 0.50)
  local b95 = percentile_bin(h, rc, total, 0.95)
  if b95 - b50 < 4 then return nil, nil end

  local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
  for b = b50, b95 do
    if sm[b] > 0 then
      local x, y = M.db_of(h, b), math.log(sm[b])
      n, sx, sy = n + 1, sx + x, sy + y
      sxx, sxy = sxx + x * x, sxy + x * y
    end
  end
  if n < 4 then return nil, nil end
  local den = n * sxx - sx * sx
  if math.abs(den) < 1e-12 then return nil, nil end
  local slope = (n * sxy - sx * sy) / den
  local icept = (sy - slope * sx) / n
  -- A taper must decay. A flat or rising bulk means there is no taper to
  -- depart from, and extrapolating it would put the threshold anywhere.
  if slope >= -0.01 then return nil, { slope = slope, icept = icept } end
  local fit = { slope = slope, icept = icept,
                lo_db = M.db_of(h, b50), hi_db = M.db_of(h, b95) }

  for b = b95 + 1, h.n - 1 do
    local db = M.db_of(h, b)
    local expected = math.exp(slope * db + icept)
    if sm[b] > expected * factor and sm[b] >= 0.5
       and (rc[b] or 0) >= MIN_CLUSTER then
      return db, fit
    end
  end
  return nil, fit
end

-- B. Knee. The count-versus-threshold curve falls away steeply while it is
-- still eating musical transients and shelves once only outliers are left. In
-- log space that curve is convex, so the knee is the point furthest below the
-- chord joining its two ends.
local function knee(h, rc, lo_db, hi_db)
  local b0 = M.bin_of(h, lo_db)
  local b1 = M.bin_of(h, hi_db)
  while b1 > b0 and (rc[b1] or 0) < 1 do b1 = b1 - 1 end
  if b1 - b0 < 4 then return nil end

  local function y(b) return math.log(math.max(rc[b] or 0, 0.5)) end
  local x0, y0 = M.db_of(h, b0), y(b0)
  local x1, y1 = M.db_of(h, b1), y(b1)
  if x1 - x0 < 1e-9 then return nil end

  local best, best_db = 0, nil
  for b = b0 + 1, b1 - 1 do
    local x = M.db_of(h, b)
    local chord = y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    local gap = chord - y(b)
    if gap > best then best, best_db = gap, x end
  end
  if best < MIN_KNEE_GAP then return nil end
  return best_db
end

-- Returns everything the panel needs to draw its case, not just a number.
function M.derive(h, cfg)
  local out = {
    tail_db = nil, knee_db = nil, derived_db = nil,
    fit = nil, fallback = false, warning = nil,
  }
  if not h or not h.counts then
    out.fallback, out.final_db = true, cfg.sens_db
    return out
  end

  local rc = reverse_cumulative(h)
  local total = rc[0] or 0
  out.total, out.rc = total, rc

  if total < MIN_EVENTS then
    out.fallback = true
    out.warning = string.format(
      "Only %d candidate events -- too few to find a gap. Using the manual " ..
      "threshold; lower the analysis floor or check the item has audio.", total)
    out.final_db = cfg.sens_db
    return out
  end

  local sm = smoothed(h)
  out.tail_db, out.fit = tail_departure(h, sm, rc, total, cfg.tail_factor)
  out.knee_db = knee(h, rc, cfg.sweep_min_db, cfg.sweep_max_db)

  local d = nil
  if out.tail_db and out.knee_db then
    d = math.max(out.tail_db, out.knee_db)
    -- Wide disagreement means the two populations are not separable in this
    -- file. Per the spec that is worth saying out loud rather than papering
    -- over: it is more informative than any amount of tuning.
    if math.abs(out.tail_db - out.knee_db) > 8 then
      out.warning = string.format(
        "The two estimators disagree by %.1f dB (tail %.1f, knee %.1f). This " ..
        "file may have no clean gap between clicks and consonants -- audit " ..
        "the markers before applying.",
        math.abs(out.tail_db - out.knee_db), out.tail_db, out.knee_db)
    end
  elseif out.tail_db or out.knee_db then
    d = out.tail_db or out.knee_db
  end

  if not d then
    out.fallback = true
    out.warning = out.warning or
      "No gap found in the overshoot distribution: the click and transient " ..
      "populations run together. Falling back to the 98th percentile."
    d = M.db_of(h, percentile_bin(h, rc, total, 0.98))
  end

  out.derived_db = d

  -- A threshold is only meaningful if a population survives it. When the
  -- candidate set is squeezed -- a long quiet-zone requirement, a narrow band,
  -- a short max click length -- the taper can thin out until the fit departs
  -- from a handful of stray bins, and the derived value lands 15 dB above
  -- where the material actually sits. Observed on real vocal takes: at
  -- max_steps 1 with sep 7 the estimate jumped from 7.1 to 22.9 dB and kept
  -- four events out of four hundred. The number is not obviously wrong, which
  -- is what makes it worth saying out loud.
  local survivors = rc[M.bin_of(h, d)] or 0
  out.survivors = survivors
  if survivors < math.max(8, total * 0.002) then
    out.sparse = true
    out.warning = (out.warning and (out.warning .. "  ") or "") ..
      string.format(
        "Only %d of %d candidates clear %.1f dB. The estimate is resting on " ..
        "very little -- loosen the quiet zone, the band or the click length, " ..
        "or set the threshold by hand.", survivors, total, d)
  end

  out.final_db = math.max(0.5, math.min(42,
                          d + (cfg.sens_offset_db or 0)))
  return out
end

return M
