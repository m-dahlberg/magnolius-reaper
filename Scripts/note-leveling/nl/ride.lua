-- @noindex
-- Note Leveling -- the rider's orchestration.
--
-- One coroutine body that reads everything the ride needs: the target, twice
-- over as usual, and each reference clip once. Shared by the panel and by the
-- headless action, which is the whole reason it is not written inside ui.lua
-- -- a rider that can only be driven by a window is not a rider you can run
-- over forty takes.
--
-- Reading is all this does. Everything downstream of the frames is pure and
-- lives in rider.lua, so moving a slider re-derives the ride without touching
-- a sample -- the same bargain the note leveling makes, extended to cover the
-- reference clips, which are by far the most expensive thing here when a
-- reference is a full-length instrumental.

local Analyze   = require "nl.analyze"
local Cluster   = require "nl.cluster"
local Level     = require "nl.level"
local Reference = require "nl.reference"
local Rider     = require "nl.rider"
local Config    = require "nl.config"

local M = {}

-- What the whole read depends on: every clip on both sides, and the frame
-- grid. Deliberately NOT the rider parameters -- the band is fixed (see
-- kernel.lua) and everything else in the rider derives from frames already in
-- memory, which is what lets its dozen sliders redraw without a re-read.
--
-- The item POSITION is in here where the note leveling's key has no need of
-- it: moving a reference clip along the timeline changes which part of the
-- arrangement sits under the vocal, so it changes the answer.
function M.cache_key(sel, cfg)
  local parts = { Config.analysis_sig(cfg) }
  local function add(e, role)
    local src = reaper.GetMediaItemTake_Source(e.take)
    parts[#parts + 1] = table.concat({
      role,
      reaper.GetMediaSourceFileName(src, ""),
      reaper.GetMediaItemTakeInfo_Value(e.take, "D_STARTOFFS"),
      reaper.GetMediaItemInfo_Value(e.item, "D_LENGTH"),
      reaper.GetMediaItemInfo_Value(e.item, "D_POSITION"),
      reaper.GetMediaItemTakeInfo_Value(e.take, "D_PLAYRATE"),
    }, ",")
  end
  for _, e in ipairs(sel.refs) do add(e, "r") end
  for _, e in ipairs(sel.target) do add(e, "t") end
  return table.concat(parts, "|")
end

-- Coroutine body. `ensure_kernel(nchan, rate)` returns a kernel or nil+err --
-- a callback because the panel caches one kernel across jobs and a headless
-- run builds whatever each clip needs. `cache(take)` may return a frame table
-- already analysed for that take, or nil.
--
-- Returns { targets = { {F, geo, item, take, R}, ... }, refs = {...} }, where
-- each target's R is the mixed reference level track laid on that target's own
-- frame grid, so index i of R and index i of F are the same instant.
function M.analyse(sel, cfg, ensure_kernel, cache)
  return function()
    if #sel.target == 0 then return nil, "No target clip" end

    -- Every target clip defines its own frame grid -- its own item position,
    -- its own length -- so each gets its own laying-down of the references.
    -- The mix itself is pure and costs nothing to repeat; only the reads are
    -- expensive, and they happen once.
    local ntgt, nref = #sel.target, #sel.refs
    local tfrac = nref > 0 and 0.6 or 1.0

    local targets = {}
    for i, e in ipairs(sel.target) do
      local geo = Analyze.geometry(e.take)
      local k, kerr = ensure_kernel(geo.nchan, geo.rate)
      if not k then return nil, kerr end

      local F = cache and cache(e.take)
      if not F then
        local got, ferr = Analyze.run(e.take, cfg, k, geo,
                                      tfrac * (i - 1) / ntgt, tfrac * i / ntgt)
        if not got then return nil, ferr or "analysis failed" end
        F = got
      end
      targets[i] = { F = F, geo = geo, item = e.item, take = e.take }
    end

    local refs = {}
    for i, e in ipairs(sel.refs) do
      local rgeo = Analyze.geometry(e.take)
      local rk, rerr = ensure_kernel(rgeo.nchan, rgeo.rate)
      if not rk then return nil, rerr end
      local a = tfrac + (1 - tfrac) * (i - 1) / nref
      local b = tfrac + (1 - tfrac) * i / nref
      local R, err = Analyze.run_ref(e.take, cfg, rk, rgeo, a, b)
      if not R then return nil, err or "reference analysis failed" end
      R.item, R.take = e.item, e.take
      refs[#refs + 1] = R
    end

    for _, t in ipairs(targets) do t.R = Reference.mix(refs, t.F) end
    return { targets = targets, refs = refs }
  end
end

-- Part 1's derived half: notes, their gains, and the Pre-FX envelope, with no
-- reference and no ride. It lives here rather than in ui.lua so that BOTH tabs
-- read their audio through one path -- M.analyse with an empty reference list
-- is exactly what the note leveling needs, and the alternative was a second
-- copy of the read loop that drifted out of step with this one the moment the
-- selection rules changed.
function M.notes_only(data, cfg)
  local out = {}
  for i, t in ipairs(data.targets) do
    local notes = Level.gains(Cluster.run(t.F, cfg), cfg)
    out[i] = {
      item = t.item, take = t.take, geo = t.geo, F = t.F,
      notes = notes,
      points = Level.envelope(notes, cfg, t.F.span),
    }
  end
  return out
end

-- Everything after the audio: notes, their Pre-FX gains, segments, the ride.
-- Pure, cheap, and re-run whenever a slider moves.
function M.derive_one(t, cfg)
  local notes = Level.gains(Cluster.run(t.F, cfg), cfg)
  local segs, points, stats = Rider.run(t.F, notes, t.R, cfg)
  return {
    item = t.item, take = t.take, geo = t.geo, F = t.F, R = t.R,
    notes = notes,
    prefx_points = Level.envelope(notes, cfg, t.F.span),
    segs = segs, points = points, stats = stats,
  }
end

function M.sig(cfg)
  return Config.cluster_sig(cfg) .. "|" .. Config.level_sig(cfg)
      .. "|" .. Config.rider_sig(cfg)
end

function M.derive(data, cfg)
  local out = { sig = M.sig(cfg) }
  for i, t in ipairs(data.targets) do out[i] = M.derive_one(t, cfg) end
  return out
end

-- A one-line summary of what the ride does, for the panel's status line and
-- the headless run's log. The static term is the number worth surfacing: it is
-- the one the offset control is really setting, and if it sits at a cap the
-- ride is doing nothing but push against that cap.
function M.describe(d, cfg)
  local st = d.stats or {}
  local ridden, held, capped, lo, hi = 0, 0, 0, 0, 0
  for _, s in ipairs(d.segs) do
    if s.gain_db then
      ridden = ridden + 1
      if s.clamped then capped = capped + 1 end
      if s.gain_db < lo then lo = s.gain_db end
      if s.gain_db > hi then hi = s.gain_db end
    else
      held = held + 1
    end
  end
  local msg = string.format(
    "%d segments ridden, %d held, %.1f..%+.1f dB", ridden, held, lo, hi)
  if st.T_med and st.R_med then
    msg = msg .. string.format(
      "   vocal %.1f, reference %.1f, static %+.1f dB",
      st.T_med, st.R_med, st.static_db)
  end
  if capped > 0 then
    msg = msg .. string.format("   %d at a cap", capped)
  end
  return msg
end

return M
