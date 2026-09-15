-- @noindex
-- Note Leveling -- which of the selected clips is the target.
--
-- The rider takes several clips at once: the references it measures the
-- arrangement from, and the one target it rides. The brief asked for "the
-- first selected clips are the reference, the last is the target", and that
-- rule cannot be implemented as written, for a reason worth recording rather
-- than working around silently:
--
--   REAPER does not expose item SELECTION ORDER. GetSelectedMediaItem walks
--   the project's items in track-then-position order and hands them back in
--   that order however they were clicked. There is no "last selected item" to
--   ask for -- GetLastTouchedTrack exists, its item equivalent does not.
--
-- So the rule here is positional instead, and chosen to mean the same thing in
-- the session the feature was designed against: **the target is the selected
-- audio on the highest-numbered track, and everything above it is reference.**
-- References on 1 and 2, target on 3 resolves exactly as intended, it survives
-- being re-selected in any order, and -- the reason it is the rule rather than
-- a heuristic -- it is deterministic from project state alone, which is what a
-- headless run needs. cfg.rider_target_track overrides it with an explicit
-- 1-based track number for the case where the layout says otherwise.
--
-- All selected audio on the target track is ridden, not just one clip: a
-- comped lead vocal is normally a row of clips, and riding one of them would
-- be a strange thing to offer.

local M = {}

local function audio_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
  return nil
end

-- Returns a table:
--   { target = { {item, take}, ... }, refs = { {item, take}, ... },
--     track = <MediaTrack>, track_num = <1-based>, err = <string or nil> }
-- `err` is set rather than raised, because every caller of this -- the panel
-- every frame, the headless action once -- wants to report it, not to stop.
function M.resolve(cfg)
  local by_num, nums = {}, {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = audio_take(item)
    if take then
      local tr = reaper.GetMediaItemTrack(item)
      local num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
      if not by_num[num] then by_num[num] = { track = tr, items = {} }
                              nums[#nums + 1] = num end
      local t = by_num[num].items
      t[#t + 1] = { item = item, take = take }
    end
  end

  local out = { target = {}, refs = {}, nsel = n }
  if #nums == 0 then
    out.err = "Select the reference clips and the target clip."
    return out
  end
  table.sort(nums)

  local want = math.floor(cfg.rider_target_track or 0)
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

  -- No reference is not an error. The target-leveling term still works on its
  -- own -- it is a note-stepped level rider against the take's own median --
  -- and saying so is more useful than refusing.
  out.ref_tracks = #nums - 1
  return out
end

-- One line for the panel and the headless log, so what the script decided is
-- always visible rather than inferred from the result.
function M.describe(sel)
  if sel.err then return sel.err end
  local tracks = {}
  for _, e in ipairs(sel.refs) do
    local tr = reaper.GetMediaItemTrack(e.item)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
    tracks[num] = nm ~= "" and nm or ("track " .. num)
  end
  local names = {}
  for num, nm in pairs(tracks) do names[#names + 1] = { num, nm } end
  table.sort(names, function(a, b) return a[1] < b[1] end)
  local list = {}
  for _, e in ipairs(names) do list[#list + 1] = e[2] end

  local _, tname = reaper.GetSetMediaTrackInfo_String(sel.track, "P_NAME", "", false)
  if tname == "" then tname = "track " .. sel.track_num end
  if #list == 0 then
    return string.format("No reference -- riding %s against itself.", tname)
  end
  return string.format("%d clip%s from %s  ->  %d on %s",
    #sel.refs, #sel.refs == 1 and "" or "s", table.concat(list, ", "),
    #sel.target, tname)
end

return M
