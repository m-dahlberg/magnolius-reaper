-- @noindex
-- Loudness Envelope -- energy frames in, target curve out. Pure Lua.
--
-- The job: a curve that says how loud the source is singing PHRASE BY PHRASE,
-- for a rider on a different take (another language, the same melody) to aim
-- at. The thing it must not do is follow syllables -- the destination's
-- syllables fall in different places, so a curve that dips for a source
-- consonant tells the rider to pull down a destination vowel.
--
-- That rules out a follower of any time constant: one slow enough to ignore
-- syllables lags every phrase by its own time constant, and one fast enough to
-- land on the phrase follows the syllables. Offline, there is a better tool.
-- The stages, each one answering one way a naive curve goes wrong:
--
--   1. detector   the rider's own one-pole, so the curve is in the units the
--                 rider will compare it against
--   2. gate       breaths, tails and room tone get no vote at all -- otherwise
--                 every pause between phrases drags the curve down
--   3. outline    a sliding MEDIAN of the voted frames. A median does not move
--                 for a burst or a dip that occupies less than half its window,
--                 which is exactly the definition of "not a phrase change"
--   4. smooth     a zero-phase Gaussian, as normalised convolution weighted by
--                 how much of each window was singing. Rounds the median's
--                 steps without lag, and without pulling toward silence
--   5. fill       what is still empty -- long gaps -- is a straight line from
--                 one phrase's level to the next; the ends hold. The curve
--                 never dips between phrases (the rider is gated there anyway)
--   6. shape      depth, range and offset around the curve's own median
--   7. simplify   Ramer-Douglas-Peucker, so a three-minute take writes tens of
--                 points rather than thousands
--
-- Every stage is a plain function over plain arrays so the headless suite can
-- assert each one on its own.

local Config = require "le.config"

local M = {}

M.FLOOR_DB = -150
-- Below this share of singing frames, an outline window has nothing to say.
M.MIN_COVERAGE = 0.2

local LOG10 = math.log(10)

function M.db10(x)
  if x and x > 1e-15 then return 10 * math.log(x) / LOG10 end
  return M.FLOOR_DB
end

local function median_of(t, n)
  if n == 0 then return nil end
  table.sort(t, function(a, b) return a < b end)
  -- `t` may be longer than `n` (it is reused); sort only sees nils past n if
  -- they were cleared, so callers pass a table of exactly n entries.
  if n % 2 == 1 then return t[(n + 1) // 2] end
  return 0.5 * (t[n // 2] + t[n // 2 + 1])
end
M.median = function(t)
  local c = {}
  for i = 1, #t do c[i] = t[i] end
  return median_of(c, #c)
end

------------------------------------------------------------------- 0. merge

-- Several clips' frame tables onto one project-time grid starting at `t0`.
-- Each clip is { t = project time of its first frame, e = { energies } }.
-- Overlapping clips SUM, because overlapping items on one track play summed;
-- frames no clip reaches stay 0, which is what the track plays there.
--
-- A clip's offset onto the grid is ROUNDED to the nearest frame. Truncating
-- would put every clip up to a frame early or late depending on where it
-- happens to sit, and the error would differ from clip to clip.
function M.merge(clips, t0, t1, hop)
  local n = math.max(1, math.ceil((t1 - t0) / hop - 1e-9))
  local E = {}
  for i = 1, n do E[i] = 0 end
  for _, c in ipairs(clips) do
    local off = math.floor((c.t - t0) / hop + 0.5)
    for i = 1, #c.e do
      local g = off + i
      if g >= 1 and g <= n then E[g] = E[g] + c.e[i] end
    end
  end
  return { t0 = t0, hop = hop, n = n, E = E }
end

---------------------------------------------------------------- 1. detector

-- The rider's detector: a one-pole on the energy, in dB. The rider runs it per
-- sample; run per frame on frame means it is the same filter sampled at the
-- frame ends, exactly so for a signal steady within a frame. It starts from
-- zero, as the rider does.
function M.detector(E, hop, tau_s)
  local a = 1 - math.exp(-hop / math.max(tau_s, 1e-4))
  local L, d = {}, 0
  for i = 1, #E do
    d = d + a * (E[i] - d)
    L[i] = M.db10(d)
  end
  return L
end

-------------------------------------------------------------------- 2. gate

-- Returns the active flags, the median of the frames above the absolute gate
-- (the take's typical level while it is making any sound at all) and the
-- threshold actually applied. nil + message when nothing clears the gate.
function M.gate(L, gate_abs_db, gate_rel_db)
  local above, n = {}, 0
  for i = 1, #L do
    if L[i] > gate_abs_db then n = n + 1 above[n] = L[i] end
  end
  if n == 0 then
    return nil, string.format("Nothing on the source rises above the %.0f dB gate.",
                              gate_abs_db)
  end
  local med = median_of(above, n)
  local thresh = math.max(gate_abs_db, med - gate_rel_db)
  local active = {}
  for i = 1, #L do active[i] = L[i] > thresh end
  return active, med, thresh
end

----------------------------------------------------------- decimate to grid

-- The detector sampled on the output grid. Sampling (not averaging) is right
-- here: the detector is already a 50 ms average, and sampling it is what the
-- rider would read at that instant.
function M.decimate(L, active, step)
  local Ld, Ad = {}, {}
  local j = 0
  for i = 1, #L, step do
    j = j + 1
    Ld[j], Ad[j] = L[i], active[i]
  end
  return Ld, Ad
end

----------------------------------------------------------------- 3. outline

-- A sliding median over the ACTIVE points within `half` grid points either
-- side. Returns med[j] (false where the window held too little singing) and
-- cov[j], the share of the window that was singing.
function M.outline(Ld, Ad, half)
  local n = #Ld
  local med, cov = {}, {}
  local buf = {}
  for j = 1, n do
    local lo, hi = math.max(1, j - half), math.min(n, j + half)
    local cnt = 0
    for m = lo, hi do
      if Ad[m] then cnt = cnt + 1 buf[cnt] = Ld[m] end
    end
    local total = hi - lo + 1
    cov[j] = cnt / total
    if cnt > 0 and cov[j] >= M.MIN_COVERAGE then
      local t = {}
      for i = 1, cnt do t[i] = buf[i] end
      med[j] = median_of(t, cnt)
    else
      med[j] = false
    end
  end
  return med, cov
end

------------------------------------------------------------------ 4. smooth

-- Zero-phase Gaussian, as normalised convolution: each output is the weighted
-- mean of the valid outline points near it, weighted by the Gaussian AND by
-- how much singing their windows held. A gap therefore contributes nothing
-- rather than contributing silence, and a point at a phrase edge leans toward
-- the phrase. `sigma` in grid points; 0 leaves the outline alone.
function M.smooth(med, cov, sigma)
  local n = #med
  if sigma <= 0 then
    local out = {}
    for j = 1, n do out[j] = med[j] end
    return out
  end
  local reach = math.ceil(3 * sigma)
  local g = {}
  for k = 0, reach do g[k] = math.exp(-0.5 * (k / sigma) ^ 2) end
  local out = {}
  for j = 1, n do
    local num, den = 0, 0
    for m = math.max(1, j - reach), math.min(n, j + reach) do
      local v = med[m]
      if v then
        local w = g[math.abs(m - j)] * cov[m]
        num = num + w * v
        den = den + w
      end
    end
    out[j] = den > 1e-6 and (num / den) or false
  end
  return out
end

-------------------------------------------------------------------- 5. fill

-- Straight lines across the remaining gaps, holds at the ends. In place.
-- nil + message when there is nothing at all to fill from.
function M.fill(c)
  local n = #c
  local first, last
  for j = 1, n do if c[j] then first = first or j last = j end end
  if not first then return nil, "No phrase on the source was long enough to outline." end
  for j = 1, first - 1 do c[j] = c[first] end
  for j = last + 1, n do c[j] = c[last] end
  local j = first
  while j < last do
    if not c[j + 1] then
      local a = j
      local b = j + 1
      while not c[b] do b = b + 1 end
      for m = a + 1, b - 1 do
        c[m] = c[a] + (c[b] - c[a]) * (m - a) / (b - a)
      end
      j = b
    else
      j = j + 1
    end
  end
  return c
end

------------------------------------------------------------------- 6. shape

-- Depth, range and offset, around the median of the curve over the points
-- where the source was actually singing (`valid[j]` true). The median rather
-- than the mean so one very loud line cannot move the pivot.
function M.shape(c, valid, depth_pct, range_db, offset_db)
  local t, n = {}, 0
  for j = 1, #c do if valid[j] then n = n + 1 t[n] = c[j] end end
  if n == 0 then for j = 1, #c do n = n + 1 t[n] = c[j] end end
  local Mid = median_of(t, n)
  local depth = depth_pct / 100
  local out = {}
  for j = 1, #c do
    local d = depth * (c[j] - Mid)
    if d >  range_db then d =  range_db end
    if d < -range_db then d = -range_db end
    local v = Mid + d + offset_db
    if v < Config.TARGET_MIN then v = Config.TARGET_MIN end
    if v > Config.TARGET_MAX then v = Config.TARGET_MAX end
    out[j] = v
  end
  return out, Mid
end

---------------------------------------------------------------- 7. simplify

-- Ramer-Douglas-Peucker on (t, v), with the error measured VERTICALLY -- in
-- dB at the same instant -- because that is the error the rider would see.
-- Returns the kept indices in order; the ends are always kept.
function M.simplify(t, v, tol)
  local n = #v
  if n <= 2 then
    local k = {}
    for i = 1, n do k[i] = i end
    return k
  end
  local keep = { [1] = true, [n] = true }
  local stack = { { 1, n } }
  while #stack > 0 do
    local seg = table.remove(stack)
    local a, b = seg[1], seg[2]
    if b > a + 1 then
      local ta, va, tb, vb = t[a], v[a], t[b], v[b]
      local worst, wi = -1, nil
      for i = a + 1, b - 1 do
        local lin = va + (vb - va) * (t[i] - ta) / (tb - ta)
        local e = math.abs(v[i] - lin)
        if e > worst then worst, wi = e, i end
      end
      if worst > tol then
        keep[wi] = true
        stack[#stack + 1] = { a, wi }
        stack[#stack + 1] = { wi, b }
      end
    end
  end
  local out = {}
  for i = 1, n do if keep[i] then out[#out + 1] = i end end
  return out
end

------------------------------------------------------------------ the whole

-- F is a merged frame table { t0, hop, n, E }. Returns a result table, or nil
-- + message. Everything here is cheap enough to run on every slider frame.
function M.build(F, cfg)
  local hop = F.hop
  local L = M.detector(F.E, hop, cfg.detector_ms / 1000)
  local active, med_active, thresh = M.gate(L, cfg.gate_abs_db, cfg.gate_rel_db)
  if not active then return nil, med_active end

  local step = math.max(1, math.floor(Config.GRID_S / hop + 0.5))
  local grid = step * hop
  local Ld, Ad = M.decimate(L, active, step)
  local half = math.max(1, math.floor(cfg.outline_s / 2 / grid + 0.5))
  local med, cov = M.outline(Ld, Ad, half)

  local valid = {}
  for j = 1, #med do valid[j] = med[j] and true or false end

  local sm = M.smooth(med, cov, cfg.smooth_s / grid)
  local filled, ferr = M.fill(sm)
  if not filled then return nil, ferr end
  local curve, Mid = M.shape(filled, valid, cfg.depth_pct, cfg.range_db,
                             cfg.offset_db)

  local t = {}
  for j = 1, #curve do t[j] = F.t0 + (j - 1) * grid end
  local idx = M.simplify(t, curve, cfg.tolerance_db)
  local points = {}
  for i, j in ipairs(idx) do points[i] = { t = t[j], v = curve[j] } end

  local lo, hi = math.huge, -math.huge
  for j = 1, #curve do
    if curve[j] < lo then lo = curve[j] end
    if curve[j] > hi then hi = curve[j] end
  end

  return {
    t = t, grid = grid, level = Ld, active = Ad, outline = med,
    curve = curve, valid = valid,
    mid = Mid, med_active = med_active, thresh = thresh,
    points = points, lo = lo, hi = hi,
    t0 = F.t0, t1 = F.t0 + F.n * hop,
  }
end

-- Linear interpolation of the written points at time `x` -- what REAPER's
-- envelope will evaluate to, for the plot's hover readout and for tests.
function M.eval_points(points, x)
  local n = #points
  if n == 0 then return nil end
  if x <= points[1].t then return points[1].v end
  if x >= points[n].t then return points[n].v end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if points[mid].t <= x then lo = mid else hi = mid end
  end
  local a, b = points[lo], points[hi]
  return a.v + (b.v - a.v) * (x - a.t) / (b.t - a.t)
end

return M
