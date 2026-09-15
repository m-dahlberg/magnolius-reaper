-- @noindex
-- AutoTilt -- which of the selected clips is the reference and which the target.
--
-- The brief asked for "the item on the lowest-numbered track is the reference
-- and the item on the highest-numbered track is the target". The second half
-- is implementable as written; the first half is generalised slightly, for a
-- reason worth recording rather than working around silently:
--
--   REAPER does not expose item SELECTION ORDER. GetSelectedMediaItem walks
--   the project's items in track-then-position order and hands them back in
--   that order however they were clicked. There is no "last selected item" to
--   ask for -- GetLastTouchedTrack exists, its item equivalent does not.
--
-- So the rule is positional: **the target is the selected audio on the
-- highest-numbered track, and everything above it is reference.** With the two
-- clips the script is designed for, that is exactly the brief. With three it
-- does the sensible thing instead of refusing. It survives being re-selected
-- in any order, and -- the reason it is the rule rather than a heuristic -- it
-- is deterministic from project state alone, which is what a headless run
-- needs. cfg.target_track overrides it with an explicit 1-based track number.
--
-- All selected audio on the target track is the target, not just one clip: a
-- comped vocal is normally a row of clips, and tilting one of them differently
-- from its neighbours would be a strange thing to offer.

local M = {}

local function audio_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
  return nil
end

-- Returns a table:
--   { target = { {item, take}, ... }, refs = { {item, take}, ... },
--     track = <MediaTrack>, track_num = <1-based>, ref_tracks = <n>,
--     err = <string or nil> }
-- `err` is set rather than raised, because every caller of this -- the panel
-- every frame, a headless action once -- wants to report it, not to stop.
function M.resolve(cfg)
  local by_num, nums = {}, {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = audio_take(item)
    if take then
      local tr = reaper.GetMediaItemTrack(item)
      local num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
      if not by_num[num] then
        by_num[num] = { track = tr, items = {} }
        nums[#nums + 1] = num
      end
      local t = by_num[num].items
      t[#t + 1] = { item = item, take = take }
    end
  end

  local out = { target = {}, refs = {}, nsel = n, ref_tracks = 0 }
  if #nums == 0 then
    out.err = "Select a reference clip and a target clip."
    return out
  end
  table.sort(nums)

  local want = math.floor(cfg.target_track or 0)
  local tnum
  if want > 0 then
    if not by_num[want] then
      out.err = string.format(
        "No selected audio on track %d, which is set as the target track.", want)
      return out
    end
    tnum = want
  else
    tnum = nums[#nums]
  end

  out.track, out.track_num = by_num[tnum].track, tnum
  out.target = by_num[tnum].items
  for _, num in ipairs(nums) do
    if num ~= tnum then
      for _, e in ipairs(by_num[num].items) do out.refs[#out.refs + 1] = e end
    end
  end

  -- No reference is not an error: it is the one-clip case the fixed reference
  -- ratio exists for. Saying so is more useful than refusing, and the panel
  -- reports which of the two it is about to do.
  out.ref_tracks = #nums - 1
  return out
end

local function track_label(tr)
  local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  if nm ~= "" then return nm end
  return "track " .. num
end

-- One line for the panel and for a headless log, so what the script decided is
-- always visible rather than inferred from the result.
function M.describe(sel, cfg)
  if sel.err then return sel.err end

  local tname = track_label(sel.track)
  if #sel.refs == 0 then
    if cfg and cfg.use_fixed_ref then
      return string.format("%d clip%s on %s -- against the fixed ratio.",
        #sel.target, #sel.target == 1 and "" or "s", tname)
    end
    return string.format(
      "%d clip%s on %s, and no reference. Select one, or turn on the fixed ratio.",
      #sel.target, #sel.target == 1 and "" or "s", tname)
  end

  local seen, names = {}, {}
  for _, e in ipairs(sel.refs) do
    local tr = reaper.GetMediaItemTrack(e.item)
    local num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    if not seen[num] then
      seen[num] = true
      names[#names + 1] = { num, track_label(tr) }
    end
  end
  table.sort(names, function(a, b) return a[1] < b[1] end)
  local list = {}
  for _, e in ipairs(names) do list[#list + 1] = e[2] end

  return string.format("%d clip%s from %s  ->  %d on %s",
    #sel.refs, #sel.refs == 1 and "" or "s", table.concat(list, ", "),
    #sel.target, tname)
end

return M
