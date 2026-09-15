-- @noindex
-- Note Leveling -- rider stage A: several reference clips into one level track.
--
-- Pure Lua. Takes the band-passed frame tables that analyze.run_ref produced
-- for each reference clip and lays them onto the TARGET's frame grid, so that
-- everything downstream can say "the arrangement at frame i" and mean the same
-- instant the target's frame i covers.
--
-- Two things make this more than a loop.
--
-- Mixing is done in POWER, not in dB. Two guitars at -18 dB each are -15 dB
-- together, not -18 and not -36, and only summing the mean squares gets that
-- right. It is also the correct model for the case that matters: sources that
-- are not correlated with each other, which is what separate tracks of an
-- arrangement are.
--
-- Alignment is done in PROJECT time. Each clip's frames start at its own item
-- position, and the target's start at the target's, so the two grids are
-- offset by a number of frames that is generally fractional. It is rounded to
-- the nearest whole frame: the sub-hop remainder is at most half of 5 ms, and
-- nothing downstream resolves a level envelope that finely. Rounding rather
-- than truncating matters more than it looks -- truncation would bias every
-- reference late by an average of half a frame, and the rider's whole premise
-- is that its decisions land on the right side of an onset.
--
-- Coverage is tracked separately from level, because "no reference clip
-- reaches here" and "the arrangement is silent here" are different facts and
-- want different behaviour. Silence should pull the vocal down; an uncovered
-- stretch should not be allowed to say anything at all.

local M = {}

local FLOOR_DB = -120

local function db(ms)
  if ms <= 0 then return FLOOR_DB end
  local v = 10 * math.log(ms, 10)
  return v < FLOOR_DB and FLOOR_DB or v
end

-- refs: { { n, hop_s, item_pos, bp_ms = {...} }, ... }  (analyze.run_ref output)
-- target: anything carrying n, hop_s and item_pos (a frame table, or a stub)
--
-- Returns { n, hop_s, db = {}, ms = {}, covered = {}, n_covered, median_db }
-- indexed 1..n on the target's grid.
function M.mix(refs, target)
  local n, hop = target.n, target.hop_s
  local R = { n = n, hop_s = hop, db = {}, ms = {}, covered = {},
              n_covered = 0, nrefs = 0 }

  for i = 1, n do R.ms[i] = 0 R.covered[i] = false end

  for _, r in ipairs(refs or {}) do
    if r and r.n and r.n > 0 then
      R.nrefs = R.nrefs + 1
      -- Frame j of this reference sits at project time
      --   r.item_pos + (j - 1) * hop
      -- and target frame i at target.item_pos + (i - 1) * hop, so
      --   i = j + (r.item_pos - target.item_pos) / hop.
      local shift = (r.item_pos - target.item_pos) / hop
      local off = math.floor(shift + 0.5)
      for j = 1, r.n do
        local i = j + off
        if i >= 1 and i <= n then
          R.ms[i] = R.ms[i] + (r.bp_ms[j] or 0)
          R.covered[i] = true
        end
      end
    end
  end

  local vals = {}
  for i = 1, n do
    R.db[i] = db(R.ms[i])
    if R.covered[i] then
      R.n_covered = R.n_covered + 1
      vals[#vals + 1] = R.db[i]
    end
  end

  -- A median over the covered frames, used only as a diagnostic and as the
  -- last-resort stand-in when a segment's own window is uncovered. The rider
  -- computes its own reference median over the frames the VOCAL occupies,
  -- which is a different and better-chosen population -- see rider.lua.
  table.sort(vals)
  R.median_db = #vals > 0 and vals[(#vals + 1) // 2] or FLOOR_DB
  return R
end

-- Percentile of the band level over frames [i0, i1], counting only covered
-- frames. Returns nil when the window has less than `min_cover` of its frames
-- covered -- the caller must decide what an uncovered window means rather than
-- being handed a plausible-looking number derived from nothing.
function M.window_db(R, i0, i1, pct, min_cover)
  i0 = math.max(1, math.floor(i0))
  i1 = math.min(R.n, math.floor(i1))
  if i1 < i0 then return nil, 0 end

  local vals, total = {}, i1 - i0 + 1
  for i = i0, i1 do
    if R.covered[i] then vals[#vals + 1] = R.db[i] end
  end
  local frac = #vals / total
  if #vals == 0 or frac < (min_cover or 0.5) then return nil, frac end

  table.sort(vals)
  local idx = math.ceil(#vals * (pct or 90) / 100)
  if idx < 1 then idx = 1 end
  if idx > #vals then idx = #vals end
  return vals[idx], frac
end

M.FLOOR_DB = FLOOR_DB
M.db = db
return M
