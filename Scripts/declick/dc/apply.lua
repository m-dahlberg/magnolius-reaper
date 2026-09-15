-- @noindex
-- Adaptive De-Click -- stage 4: put the result back in the project.
--
-- The only module that touches the project.
--
-- The rendered file covers exactly the item's own span at the source rate, and
-- it already contains everything the accessor applied on the way in. Measured
-- on REAPER 7.75, the take accessor applies the playrate, the pitch shift and
-- the channel mode, and does NOT apply take volume, item volume or pan.
--
-- So the new take takes a zero start offset and NEUTRAL stretch settings --
-- copying the original's playrate onto it would apply the stretch a second
-- time, to audio that is already stretched -- while volume and pan, which the
-- render never saw, are copied across so it plays back at the same level.
--
-- Adding it as a take rather than replacing the source is what makes A/B a
-- keypress: the original stays under it.
--
-- Take markers are the audit trail the spec asks for: with dry_run on, nothing
-- is written at all and the markers alone say where the script wanted to cut,
-- which is the intended way to tune by ear before trusting a batch.

local Analyze = require "dc.analyze"

local M = {}

-- Beyond a few hundred, markers stop being an audit and start being a wall.
-- The CSV log is where an exhaustive record belongs.
M.MAX_MARKERS = 500

-- Properties the accessor did NOT apply, so the rendered audio still needs them.
local COPY_NUM = { "D_VOL", "D_PAN" }

-- Properties the accessor DID apply, already baked into the rendered file.
-- Applying them again would stretch stretched audio and re-fold folded
-- channels, which desyncs the take against the original by exactly the
-- playrate -- invisible until you A/B it.
local NEUTRAL = { D_PLAYRATE = 1, D_PITCH = 0, B_PPITCH = 0, I_CHANMODE = 0 }

local function copy_props(from, to)
  for _, k in ipairs(COPY_NUM) do
    reaper.SetMediaItemTakeInfo_Value(to, k,
      reaper.GetMediaItemTakeInfo_Value(from, k))
  end
end

-- Applied to WHICHEVER take ends up holding the rendered file, including the
-- original when the result replaces it in place. Doing this inside copy_props
-- would only cover the new-take path, and leave the replace-in-place path
-- silently double-applying the stretch it was meant to prevent.
local function neutralize(t)
  for k, v in pairs(NEUTRAL) do
    reaper.SetMediaItemTakeInfo_Value(t, k, v)
  end
end

-- Events carry positions in source samples; a take marker wants source time.
local function place_markers(take, events, rate, severity_floor)
  local n = math.min(#events, M.MAX_MARKERS)
  for i = 1, n do
    local e = events[i]
    -- Redder with severity, on the same scale the panel draws: 0 at the
    -- threshold, saturated at +30 dB over it.
    local s = math.max(0, math.min(1, (e.over_db - severity_floor) / 30))
    local col = reaper.ColorToNative(255,
                  math.floor(217 - 191 * s), 38) | 0x1000000
    reaper.SetTakeMarker(take, -1,
      string.format("click %.1f dB", e.over_db), e.pos / rate, col)
  end
  return n
end

local function clear_markers(take)
  for i = reaper.GetNumTakeMarkers(take) - 1, 0, -1 do
    local _, name = reaper.GetTakeMarker(take, i)
    if name:match("^click ") then reaper.DeleteTakeMarker(take, i) end
  end
end

-- REAPER builds peaks when a file arrives through an import path -- the media
-- explorer, a drag-drop, Insert media. A source created here with
-- PCM_Source_CreateFromFile has none, and nothing ever goes looking: the take
-- plays back correctly and draws an empty lane, because audio is decoded on
-- demand and peaks are not.
--
-- Measured on 7.75: PCM_Source_GetPeaks returns 0 samples for a freshly
-- written file and the full request after this runs. mode 0 starts and reports
-- whether there is anything to do, mode 1 runs a slice and returns non-zero
-- while more remains, mode 2 finishes. A 10 s file takes two slices, which is
-- nothing next to the render that just produced it, and the result is cached
-- to disk so a later source over the same file gets peaks immediately.
--
-- The cap is there so a source that refuses to finish cannot spin the loop
-- forever; a missing waveform is worth far less than a hung REAPER.
local function build_peaks(src)
  if reaper.PCM_Source_BuildPeaks(src, 0) == 0 then return true end
  local slices = 0
  while reaper.PCM_Source_BuildPeaks(src, 1) ~= 0 do
    slices = slices + 1
    if slices > 100000 then break end
  end
  reaper.PCM_Source_BuildPeaks(src, 2)
  return slices <= 100000
end

-- result is nil for a dry run: markers are placed on the existing take and no
-- audio is written or attached.
function M.run(item, take, result, cfg, events, th)
  local src
  if result then
    src = reaper.PCM_Source_CreateFromFile(result.path)
    if not src then return nil, "REAPER could not open " .. result.path end
    -- Before the undo block: this is not a project edit, and it must not sit
    -- inside PreventUIRefresh.
    build_peaks(src)
  end

  local _, oldname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  local label = cfg.isolate and " [clicks]" or " [declicked]"
  -- Dry run has no render to take the rate from, and the take's own source can
  -- report 0 for it (see analyze.lua's source_format). Marker positions are
  -- pos/rate, so a 0 here puts every marker at infinity.
  local rate = (result and result.rate) or Analyze.geometry(take).rate

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local nt = take
  if result then
    if cfg.new_take then
      nt = reaper.AddTakeToMediaItem(item)
      copy_props(take, nt)
    end
    reaper.SetMediaItemTake_Source(nt, src)
    reaper.SetMediaItemTakeInfo_Value(nt, "D_STARTOFFS", 0)
    neutralize(nt)
    reaper.GetSetMediaItemTakeInfo_String(nt, "P_NAME", oldname .. label, true)
  end

  reaper.GetSetMediaItemTakeInfo_String(nt, "P_EXT:declick",
    string.format("%.2f dB (%s), %d events, %.3f%% repaired",
      th.sens_used or 0, th.manual and "manual" or "auto",
      (th.stats and th.stats.events) or 0,
      ((th.stats and th.stats.repaired) or 0) * 100), true)

  local marked = 0
  if cfg.place_take_markers then
    clear_markers(nt)
    marked = place_markers(nt, events, rate, th.sens_used or 0)
  end

  if result and cfg.new_take and cfg.select_take then
    reaper.SetActiveTake(nt)
  end

  reaper.UpdateItemInProject(item)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(result and "Adaptive de-click" or "De-click (dry run)", -1)
  return nt, marked
end

return M
