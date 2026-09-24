-- @noindex
-- Note Leveling -- which track is the source, and which are the arrangement.
--
-- The source (the vocal being levelled and ridden) and up to three background tracks are each
-- chosen explicitly, from a dropdown or by typing a track name (see nl/trackpick.lua). EVERY
-- audio clip on a chosen track is used; nothing needs selecting, and the time selection is not
-- consulted.
--
-- Three background tracks because that is what a loudness reference usually is -- drums, bass,
-- guitars -- and because `reference.mix` already sums them correctly: it mixes in POWER, not in
-- dB, which is the right model for sources that are not correlated with each other. Slots may
-- be left empty; an empty slot contributes nothing rather than silence, and "no reference clip
-- reaches here" stays distinguishable from "the arrangement is quiet here".
--
-- This replaced a positional rule -- "the target is the selected audio on the highest-numbered
-- track, everything above it is reference" -- which existed because REAPER does not expose item
-- SELECTION ORDER: GetSelectedMediaItem walks track-then-position and hands items back in that
-- order however they were clicked, and there is no item equivalent of GetLastTouchedTrack. That
-- constraint is real and still worth knowing; the rule it forced was the problem. It tied the
-- roles to where tracks happened to sit, re-selecting clips could change what the script did,
-- and a backing track below the vocal could not be used at all. Naming the tracks says what is
-- meant, survives reordering, and reads the same in a headless run.

local Trackpick = require "nl.trackpick"

local M = {}

M.SOURCE = "source"
M.BACKGROUND = { "bg1", "bg2", "bg3" }

-- Returns a table:
--   { target = { {item, take}, ... }, refs = { {item, take}, ... },
--     track = <MediaTrack>, track_num = <1-based>, ref_tracks = <n>,
--     tracks = <every track, for the panel's dropdowns>, err = <string or nil> }
-- `err` is set rather than raised, because every caller of this -- the panel every frame, the
-- headless action once -- wants to report it, not to stop.
function M.resolve(cfg)
  local out = { target = {}, refs = {}, ref_tracks = 0, bg = {}, bg_err = {} }
  if not reaper then out.err = "no REAPER"; return out end

  out.tracks = Trackpick.tracks()
  out.source_track, out.source_err = Trackpick.resolve(out.tracks, cfg, M.SOURCE)

  if not out.source_track then
    out.err = out.source_err
      or (Trackpick.is_set(cfg, M.SOURCE)
            and "The source track is set but could not be found."
            or "Pick the source track -- the vocal to level.")
    return out
  end

  out.target = Trackpick.items(out.source_track.track)
  if #out.target == 0 then
    out.err = string.format("%s holds no audio.", out.source_track.name)
    return out
  end

  out.track = out.source_track.track
  out.track_num = out.source_track.num

  -- Background slots. A slot pointing at the source is refused rather than quietly dropped:
  -- riding a vocal against its own loudness is a fixed point, not a mix decision, and a silent
  -- drop would look like the slot simply had no effect.
  local seen = {}
  for i, prefix in ipairs(M.BACKGROUND) do
    local t, err = Trackpick.resolve(out.tracks, cfg, prefix)
    out.bg[i], out.bg_err[i] = t, err
    if t then
      if t.guid == out.source_track.guid then
        out.bg_err[i] = "that is the source track"
      elseif seen[t.guid] then
        out.bg_err[i] = "already used by another slot"
      else
        seen[t.guid] = true
        local items = Trackpick.items(t.track)
        if #items == 0 then
          out.bg_err[i] = "holds no audio"
        else
          out.ref_tracks = out.ref_tracks + 1
          for _, e in ipairs(items) do out.refs[#out.refs + 1] = e end
        end
      end
    end
  end

  -- No background is not an error. The target-levelling term still works on its own -- it is a
  -- note-stepped level rider against the take's own median -- and saying so is more useful than
  -- refusing.
  return out
end

-- One line for the panel and the headless log, so what the script decided is always visible
-- rather than inferred from the result.
function M.describe(sel)
  if sel.err then return sel.err end

  local tname = sel.source_track and sel.source_track.name or "?"
  local names = {}
  for i, t in ipairs(sel.bg) do
    if t and not sel.bg_err[i] then names[#names + 1] = t.name end
  end

  if #names == 0 then
    return string.format("No background -- riding %s against itself.", tname)
  end
  return string.format("%d clip%s from %s  ->  %d on %s",
    #sel.refs, #sel.refs == 1 and "" or "s", table.concat(names, ", "),
    #sel.target, tname)
end

return M
