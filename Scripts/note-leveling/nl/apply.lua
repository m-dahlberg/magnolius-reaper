-- @noindex
-- Note Leveling -- stage 4: write the gains as Pre-FX volume automation.
--
-- The only module that touches the project.
--
-- Part 1's target is the track's "Volume (Pre-FX)" envelope, chunk name
-- "<VOLENV" -- the leading angle bracket is part of the name the API wants.
-- Not VOLENV2, which is the post-fader volume envelope, and not VOLENV3,
-- which is trim. Pre-FX is the point of the exercise: the correction happens
-- before the vocal chain, so the compressor downstream sees an already
-- balanced signal.
--
-- Part 2, the rider, writes "<VOLENV2" -- the fader -- for the mirror-image
-- reason. A macro ride against the arrangement is a mix move, and a mix move
-- belongs after the vocal chain: put it in front and the compressor undoes
-- most of it, which is precisely the fight the two-envelope split avoids. The
-- two stack cleanly because they are different envelopes on the same track.
--
-- Three facts shape everything here:
--
--   * GetTrackEnvelopeByChunkName hands back the built-in envelope whether or
--     not the track has one yet -- a track that has never seen automation
--     returns a real envelope with zero points, ACT 0 and VIS 0. So there is
--     nothing to create; there is only something to fill in and switch on.
--   * An envelope cannot be activated while it is empty. Setting ACT 1 through
--     the state chunk silently does nothing on a point-less envelope, so the
--     order has to be wipe, write, THEN activate -- and the activation carries
--     the points with it, because they are in the same chunk.
--   * An envelope belongs to a TRACK, not an item. So the work is grouped by
--     track and the wipe happens once per track, before any of that track's
--     items are written. Wiping per item would erase the previous item's work.
--
-- Point times arrive in take seconds -- the audio accessor's own timeline,
-- which already has the playrate applied -- so project time is item_pos + t,
-- with no playrate factor. Ramp lengths are therefore real time, the same
-- number of milliseconds however the item is stretched.
--
-- Take markers are the exception, and the only place a third coordinate system
-- appears: SetTakeMarker stores a SOURCE position, which is
-- D_STARTOFFS + take_time * playrate. Verified on 7.75 across playrates 1.0
-- and 1.5 with and without a start offset.

local M = {}

-- Two differences in how the two envelopes are cleared, and both are
-- deliberate. Part 1 wipes the whole Pre-FX envelope, because a note-leveling
-- pass owns that envelope entirely. The rider clears only the SPAN of the
-- items it is riding, because the fader is where everything else in a mix
-- lives -- a rider that erased the automation on the rest of the song would be
-- unusable, and a vocal is rarely the only thing on its track's fader.

-- Native colours, so the pair reads as a bracket at a glance. The high bit is
-- what tells REAPER these are real colours rather than "use the default".
local MARKER_START = reaper.ColorToNative(80, 200, 120) | 0x1000000
local MARKER_END   = reaper.ColorToNative(64, 96, 112) | 0x1000000

-- Switch the envelope on and show it, once it has points. Empty envelopes
-- refuse to activate, so this is called after the points are written -- and
-- the chunk it round-trips already contains them.
-- Points arrive in take seconds; project time is item_pos + t, with no
-- playrate factor, because the accessor already applied it. Shape is linear
-- because the dB curve is carried by the point density, not by the shape.
function M.write_points(env, mode, pos, points)
  for _, p in ipairs(points) do
    reaper.InsertEnvelopePointEx(env, -1,
      pos + p.t,
      reaper.ScaleToEnvelopeMode(mode, 10 ^ (p.db / 20)),
      0,       -- shape: linear
      0,       -- tension
      false,   -- selected
      true)    -- noSort: one sort at the end instead of per point
  end
  return #points
end

local function activate(env)
  local ok, ec = reaper.GetEnvelopeStateChunk(env, "", false)
  if not ok then return end
  local nact, nvis
  ec, nact = ec:gsub("\nACT %d+", "\nACT 1", 1)
  ec, nvis = ec:gsub("\nVIS %d+", "\nVIS 1", 1)
  if nact > 0 or nvis > 0 then reaper.SetEnvelopeStateChunk(env, ec, false) end
end

-- Take markers bracketing every note, named for the note. Optional, because
-- they are a second opinion on the same detection the envelope already
-- encodes -- useful for reading and hand-editing the analysis in the arrange
-- view, noise if you only want the gain.
--
-- Existing take markers on the take are cleared first, for the same reason the
-- envelope is: a second pass with different settings must not leave the first
-- pass's markers interleaved with its own. Markers are deleted back to front,
-- since each delete renumbers the ones after it.
local function write_markers(take, notes, geo)
  for i = reaper.GetNumTakeMarkers(take) - 1, 0, -1 do
    reaper.DeleteTakeMarker(take, i)
  end
  local function srcpos(t) return geo.startoffs + t * geo.playrate end
  for _, n in ipairs(notes) do
    reaper.SetTakeMarker(take, -1, n.name, srcpos(n.t0), MARKER_START)
    reaper.SetTakeMarker(take, -1, n.name .. " end", srcpos(n.t1), MARKER_END)
  end
  return #notes * 2
end

-- results: { { item, take, geo, points, notes }, ... }
-- Every point in `points` is { t = source seconds, db = number }.
function M.run(results, cfg)
  if #results == 0 then return nil, "Nothing to apply" end

  -- Group by track, keeping each track's items in the order they were given.
  local order, by_track = {}, {}
  for _, r in ipairs(results) do
    local tr = reaper.GetMediaItemTrack(r.item)
    if not by_track[tr] then by_track[tr] = {}; order[#order + 1] = tr end
    local t = by_track[tr]
    t[#t + 1] = r
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- No early return between here and PreventUIRefresh(-1): an unbalanced call
  -- leaves REAPER's UI frozen for the rest of the session. Failures are
  -- collected and reported after the block closes.
  local err, npoints, nmarkers = nil, 0, 0

  for _, track in ipairs(order) do
    local env = reaper.GetTrackEnvelopeByChunkName(track, "<VOLENV")
    if not env then
      err = err or "This track has no Volume (Pre-FX) envelope"
    else
      local mode = reaper.GetEnvelopeScalingMode(env)
      reaper.DeleteEnvelopePointRangeEx(env, -1, -1, math.huge)

      for _, r in ipairs(by_track[track]) do
        npoints = npoints + M.write_points(env, mode, r.geo.item_pos, r.points)

        if cfg.write_markers then
          nmarkers = nmarkers + write_markers(r.take, r.notes, r.geo)
        end

        reaper.GetSetMediaItemInfo_String(r.item, "P_EXT:notelevel",
          string.format("%d notes, floor %.1f, ceiling %.1f, amount %.0f%%",
            #r.notes, cfg.floor_db, cfg.ceiling_db, cfg.amount), true)
      end

      reaper.Envelope_SortPointsEx(env, -1)
      activate(env)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Note leveling", -1)

  if err then return nil, err end
  return npoints, nmarkers
end

-- The rider ------------------------------------------------------------------
--
-- results: { { item, take, geo, points, prefx_points, segs }, ... }
--   points        the ride, in take seconds -> "<VOLENV2" (the fader)
--   prefx_points  part 1's envelope        -> "<VOLENV"  (Pre-FX), optional
--
-- Both are written inside one undo block, because the rider MEASURED the
-- target as though the Pre-FX correction were already applied. Writing the
-- ride without it would leave the take a few dB away from what the ride was
-- planned for, note by note, so cfg.rider_after_notes couples the two writes
-- rather than leaving the pairing to be remembered.
function M.ride(results, cfg)
  if #results == 0 then return nil, "Nothing to apply" end

  local order, by_track = {}, {}
  for _, r in ipairs(results) do
    local tr = reaper.GetMediaItemTrack(r.item)
    if not by_track[tr] then by_track[tr] = {}; order[#order + 1] = tr end
    local t = by_track[tr]
    t[#t + 1] = r
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local err, nride, npre = nil, 0, 0

  for _, track in ipairs(order) do
    local rs = by_track[track]
    local env = reaper.GetTrackEnvelopeByChunkName(track, "<VOLENV2")
    if not env then
      err = err or "This track has no Volume envelope"
    else
      local mode = reaper.GetEnvelopeScalingMode(env)
      -- Clear only what these items cover, and pad by a point spacing so the
      -- curve's own first and last points do not land on top of a survivor.
      local pad = math.max(cfg.rider_point_ms, 1) / 1000
      for _, r in ipairs(rs) do
        local a = r.geo.item_pos + (r.points[1] and r.points[1].t or 0) - pad
        local b = r.geo.item_pos + r.geo.item_len + pad
        reaper.DeleteEnvelopePointRangeEx(env, -1, a, b)
      end
      for _, r in ipairs(rs) do
        nride = nride + M.write_points(env, mode, r.geo.item_pos, r.points)
      end
      reaper.Envelope_SortPointsEx(env, -1)
      activate(env)
    end

    if cfg.rider_after_notes then
      local pre = reaper.GetTrackEnvelopeByChunkName(track, "<VOLENV")
      if not pre then
        err = err or "This track has no Volume (Pre-FX) envelope"
      else
        -- Part 1's rule, unchanged: it owns the Pre-FX envelope outright.
        local mode = reaper.GetEnvelopeScalingMode(pre)
        reaper.DeleteEnvelopePointRangeEx(pre, -1, -1, math.huge)
        for _, r in ipairs(rs) do
          npre = npre + M.write_points(pre, mode, r.geo.item_pos,
                                       r.prefx_points or {})
        end
        reaper.Envelope_SortPointsEx(pre, -1)
        activate(pre)
      end
    end

    for _, r in ipairs(rs) do
      local ridden, gated = 0, 0
      for _, s in ipairs(r.segs or {}) do
        if s.gain_db then ridden = ridden + 1 else gated = gated + 1 end
      end
      reaper.GetSetMediaItemInfo_String(r.item, "P_EXT:noteride",
        string.format("%d ridden, %d held, offset %.1f, follow %.0f%%, level %.0f%%",
          ridden, gated, cfg.rider_offset_db,
          cfg.rider_ref_follow, cfg.rider_tgt_level), true)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Note leveling -- vocal ride", -1)

  if err then return nil, err end
  return nride, npre
end

return M
