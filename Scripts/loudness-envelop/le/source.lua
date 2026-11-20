-- @noindex
-- Loudness Envelope -- what gets read.
--
-- The source is the FIRST SELECTED TRACK, and every audio item on it -- or,
-- with "Limit to time selection" on, the parts of those items inside the time
-- selection. Stated rather than discovered: a track rather than items because
-- the curve is a lane on another track, and a lane wants the whole song.
--
-- Each clip comes back with the window to read in TAKE time. The take
-- accessor's timeline is take time, 0 .. item length, with playrate already
-- applied -- so a window is a pair of offsets from the item start with no
-- playrate factor anywhere, and adding the item position gives project time.

local Trackpick = require "le.trackpick"

local M = {}

function M.timesel()
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if e - s > 1e-6 then return s, e end
  return nil
end

-- Returns { track, name, guid, clips = { { item, take, pos, toff, dur } },
--           t0, t1 } or { err = ... }. Nothing here raises: the panel asks
-- every frame and wants to report, not stop.
function M.resolve(cfg, track)
  track = track or reaper.GetSelectedTrack(0, 0)
  if not track then return { err = "Select the source track." } end
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  local num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
  if name == "" then name = "Track " .. num end

  local out = { track = track, name = name, num = num,
                guid = reaper.GetTrackGUID(track), clips = {} }

  local ts0, ts1
  if cfg.use_timesel then
    ts0, ts1 = M.timesel()
    if not ts0 then
      out.err = "Limit to time selection is on, and there is no time selection."
      return out
    end
  end

  local t0, t1 = math.huge, -math.huge
  for _, it in ipairs(Trackpick.items(track)) do
    local pos = reaper.GetMediaItemInfo_Value(it.item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(it.item, "D_LENGTH")
    local a, b = 0, len
    if ts0 then
      a = math.max(0, ts0 - pos)
      b = math.min(len, ts1 - pos)
    end
    if b - a > 1e-3 then
      out.clips[#out.clips + 1] = { item = it.item, take = it.take,
                                    pos = pos, toff = a, dur = b - a }
      t0 = math.min(t0, pos + a)
      t1 = math.max(t1, pos + b)
    end
  end

  if #out.clips == 0 then
    out.err = ts0 and string.format("No audio on %s inside the time selection.", name)
                   or string.format("No audio items on %s.", name)
    return out
  end
  out.t0, out.t1 = t0, t1
  return out
end

-- Everything that changes which samples would be read, or what they are
-- scaled by. The curve controls are deliberately absent: they never re-read.
function M.cache_key(src, cfg)
  if src.err then return nil end
  local parts = { src.guid, tostring(cfg.use_timesel) }
  for _, c in ipairs(src.clips) do
    local s = reaper.GetMediaItemTake_Source(c.take)
    parts[#parts + 1] = table.concat({
      reaper.GetMediaSourceFileName(s, ""),
      reaper.GetMediaItemTakeInfo_Value(c.take, "D_STARTOFFS"),
      reaper.GetMediaItemTakeInfo_Value(c.take, "D_PLAYRATE"),
      reaper.GetMediaItemTakeInfo_Value(c.take, "D_VOL"),
      reaper.GetMediaItemInfo_Value(c.item, "D_VOL"),
      c.pos, c.toff, c.dur,
    }, ",")
  end
  return table.concat(parts, "|")
end

function M.describe(src)
  if src.err then return src.err end
  return string.format("Source: %d: %s -- %d clip%s, %.1f s", src.num, src.name,
                       #src.clips, #src.clips == 1 and "" or "s", src.t1 - src.t0)
end

return M
