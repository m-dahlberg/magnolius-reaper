-- @noindex
-- Vocal Normalizer -- stage 3: what to do to each clip.
--
-- Pure Lua. Takes the frame tables stage 1 produced and turns them into one
-- priced row per clip: the band measurement, the take's ordinary LUFS for
-- comparison, its loudness range, its peak, the gain it needs and which
-- constraint -- if any -- decided that gain.
--
-- This is the whole of what a parameter change re-runs. Nothing here reads
-- audio, so moving the target, the gate or a limit re-prices every selected
-- clip in well under a frame.

local Loudness = require "vn.loudness"

local M = {}

-- The reference LUFS readout is measured with BS.1770's OWN gate, never with
-- the panel's. The panel's gate belongs to the band measurement, where it is
-- a tuning control; the number sitting next to it is only worth showing if it
-- is the number every other meter in the world would show, and a user who
-- tightened the relative gate to -6 to judge a take by its loud syllables has
-- not thereby redefined LUFS.
local STD_GATE = { gate_abs_lu = -70, gate_rel_lu = -10, reduce = "gated" }

-- clips: { { item, take, geo, F, name }, ... }  -- F from vn.analyze
--
-- Returns rows in the same order, plus a summary. Each row carries:
--   blocks     band blocks in time order, marked .abs and .gated in place
--   own        this clip measured on its own            (nil if unmeasurable)
--   band       the measurement the gain came from        -- same as `own`
--              unless link_items is on, when it is the pooled one
--   kw         the clip's LUFS, BS.1770 gate
--   lra        loudness range in LU, or nil if too short to have one
--   peak_db    sample peak
--   gain_db, limit
--   err        why this clip could not be measured
function M.run(clips, cfg)
  local rows = {}

  for i, c in ipairs(clips) do
    -- Everything is measured AS HEARD out of the item: the accessor applies
    -- neither take volume nor item volume, so both are folded in here. That is
    -- what makes the gain a move rather than an absolute setting, and it is
    -- what makes normalising an already-normalised clip ask for 0.0 dB.
    local vol_lin = math.abs((c.geo.take_vol or 1) * (c.geo.item_vol or 1))
    local r = {
      item = c.item, take = c.take, geo = c.geo, F = c.F, name = c.name,
      vol_lin = vol_lin,
      vol_db  = Loudness.db_from_amp(vol_lin),
      peak_db = Loudness.db_from_amp(c.F.peak * vol_lin),
    }
    rows[i] = r
    if vol_lin <= 1e-9 then
      -- A clip already turned all the way down has no level to normalise and
      -- no gain that would give it one. Saying so beats reporting the boost
      -- limit, which is what a -inf measurement would otherwise produce.
      r.blocks, r.kblocks = {}, {}
      r.err = "take or item volume is at -inf"
    else
      r.blocks  = Loudness.blocks(c.F, "zb", cfg, vol_lin)
      r.kblocks = Loudness.blocks(c.F, "zk", cfg, vol_lin)
      r.own, r.err = Loudness.integrate(r.blocks, cfg)
      r.kw = Loudness.integrate(r.kblocks, STD_GATE)
      r.lra = Loudness.lra(c.F, "zb", cfg)
      r.band = r.own
    end
  end

  local summary = { linked = cfg.link_items == true, nclips = #rows }

  if cfg.link_items then
    -- One programme, one gain. The blocks are pooled rather than the frames:
    -- a gating window that straddled the gap between two clips would average a
    -- phrase against whatever silence follows it, and pooling blocks means no
    -- such window is ever formed.
    --
    -- Integrating the pool re-marks every block's .abs and .gated against the
    -- POOLED gate, deliberately overwriting the per-clip marks set above. That
    -- is what the plots should show in linked mode -- the decision that was
    -- actually made -- while r.own keeps each clip's own number for the table.
    local pool, kpool, peak = {}, {}, Loudness.FLOOR_DB
    for _, r in ipairs(rows) do
      for _, b in ipairs(r.blocks)  do pool[#pool + 1]   = b end
      for _, b in ipairs(r.kblocks) do kpool[#kpool + 1] = b end
      if r.peak_db > peak then peak = r.peak_db end
    end
    local band, err = Loudness.integrate(pool, cfg)
    local kw = Loudness.integrate(kpool, STD_GATE)
    summary.band, summary.kw, summary.peak_db, summary.err = band, kw, peak, err
    if band then
      summary.gain_db, summary.limit = Loudness.gain(band.db, peak, cfg)
    end
    for _, r in ipairs(rows) do
      r.band, r.err = band, err
      r.gain_db, r.limit = summary.gain_db, summary.limit
    end
  else
    local nlim = 0
    for _, r in ipairs(rows) do
      if r.band then
        r.gain_db, r.limit = Loudness.gain(r.band.db, r.peak_db, cfg)
        if r.limit then nlim = nlim + 1 end
      end
    end
    summary.nlimited = nlim
  end

  return rows, summary
end

-- One line describing what the plan will do, for the panel's status and for a
-- headless run's log. Stated rather than inferred, because "8 clips, +3.2 dB"
-- and "8 clips, +0.4 to +7.9 dB" are very different situations and the second
-- one is usually a sign that link should have been on.
function M.describe(rows, summary, cfg)
  local n, lo, hi, bad = 0, math.huge, -math.huge, 0
  for _, r in ipairs(rows) do
    if r.gain_db then
      n = n + 1
      if r.gain_db < lo then lo = r.gain_db end
      if r.gain_db > hi then hi = r.gain_db end
    else
      bad = bad + 1
    end
  end
  if n == 0 then
    return string.format("Nothing measurable in %d clip%s.",
                         #rows, #rows == 1 and "" or "s")
  end

  local what
  if summary.linked then
    what = string.format("%d clips as one programme, %+.2f dB", n, lo)
  elseif n == 1 then
    what = string.format("1 clip, %+.2f dB", lo)
  elseif math.abs(hi - lo) < 0.005 then
    what = string.format("%d clips, %+.2f dB each", n, lo)
  else
    what = string.format("%d clips, %+.2f to %+.2f dB", n, lo, hi)
  end

  local tail = {}
  local nlim = 0
  for _, r in ipairs(rows) do if r.limit then nlim = nlim + 1 end end
  if nlim > 0 then
    tail[#tail + 1] = string.format("%d limited", nlim)
  end
  if bad > 0 then tail[#tail + 1] = string.format("%d unmeasurable", bad) end
  if #tail > 0 then what = what .. "  (" .. table.concat(tail, ", ") .. ")" end
  return what
end

M.STD_GATE = STD_GATE
return M
