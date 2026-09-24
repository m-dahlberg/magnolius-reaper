-- @noindex
-- AutoTilt -- which track is the reference and which is the target.
--
-- Both are chosen explicitly, from a dropdown or by typing a track name (see at/trackpick.lua).
-- EVERY audio clip on a chosen track is used; nothing needs selecting, and the time selection is
-- not consulted.
--
-- This replaced a positional rule -- "the target is the selected audio on the highest-numbered
-- track, everything above it is reference" -- which existed because REAPER does not expose item
-- SELECTION ORDER: GetSelectedMediaItem walks track-then-position and hands items back in that
-- order however they were clicked, and there is no item equivalent of GetLastTouchedTrack. That
-- constraint is real and still worth knowing; the rule it forced was the problem. It meant the
-- roles depended on where tracks happened to sit in the project, re-selecting clips could change
-- what the script did, and a reference below the target could not be expressed at all. Naming the
-- two tracks says what is meant, survives reordering, and reads the same in a headless run.
--
-- A reference is optional: with none, the fixed ratio is what the target is matched against.
-- A target is not.

local Trackpick = require "at.trackpick"

local M = {}

M.ROLES = { "target", "ref" }

-- Returns a table:
--   { target = { {item, take}, ... }, refs = { {item, take}, ... },
--     track = <MediaTrack>, track_num = <1-based>, ref_tracks = <n>,
--     tracks = <every track, for the panel's dropdowns>, err = <string or nil> }
-- `err` is set rather than raised, because every caller of this -- the panel every frame, a
-- headless action once -- wants to report it, not to stop.
function M.resolve(cfg)
  local out = { target = {}, refs = {}, ref_tracks = 0 }
  if not reaper then out.err = "no REAPER"; return out end

  out.tracks = Trackpick.tracks()
  out.target_track, out.target_err = Trackpick.resolve(out.tracks, cfg, "target")
  out.ref_track, out.ref_err = Trackpick.resolve(out.tracks, cfg, "ref")

  if not out.target_track then
    out.err = out.target_err
      or (Trackpick.is_set(cfg, "target")
            and "The target track is set but could not be found."
            or "Pick the target track.")
    return out
  end

  out.target = Trackpick.items(out.target_track.track)
  if #out.target == 0 then
    out.err = string.format("%s holds no audio.", out.target_track.name)
    return out
  end

  out.track = out.target_track.track
  out.track_num = out.target_track.num

  if out.ref_track then
    if out.ref_track.guid == out.target_track.guid then
      out.err = "The reference and the target are the same track."
      return out
    end
    out.refs = Trackpick.items(out.ref_track.track)
    out.ref_tracks = #out.refs > 0 and 1 or 0
    if #out.refs == 0 then
      -- Not fatal: it is the same situation as no reference at all, which the fixed ratio
      -- covers. Saying which it is beats a silent fall-through.
      out.ref_empty = true
    end
  end

  return out
end

-- One line for the panel and for a headless log, so what the script decided is always visible
-- rather than inferred from the result.
function M.describe(sel, cfg)
  if sel.err then return sel.err end

  local tname = sel.target_track and sel.target_track.name or "?"
  if #sel.refs == 0 then
    local why = sel.ref_empty
      and string.format("%s holds no audio", sel.ref_track.name)
      or "no reference track"
    if cfg and cfg.use_fixed_ref then
      return string.format("%d clip%s on %s -- against the fixed ratio (%s).",
        #sel.target, #sel.target == 1 and "" or "s", tname, why)
    end
    return string.format(
      "%d clip%s on %s, and %s. Pick one, or turn on the fixed ratio.",
      #sel.target, #sel.target == 1 and "" or "s", tname, why)
  end

  return string.format("%d clip%s from %s  ->  %d on %s",
    #sel.refs, #sel.refs == 1 and "" or "s", sel.ref_track.name, #sel.target, tname)
end

return M
