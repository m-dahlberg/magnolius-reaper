-- @noindex
-- The time selection as a processing range.
--
-- One module copied between the scripts rather than six versions of the same arithmetic.
-- Origin: the Quicktune script. Keep the copies identical; a fix belongs in all of them.
--
-- The rule, everywhere: a time selection narrows what is analysed and what is written; with no
-- selection, or with the override on, the whole item is used exactly as before.
--
-- Two coordinate traps live here, and both are silent when you get them wrong:
--
--   * `clip_range` works in PROJECT seconds, because that is the only frame a time selection
--     and several tracks can be compared in. A TAKE accessor is anchored at 0 at the start of
--     its ITEM, so reading a range from it starts at `range.t0 - item_pos`; a TRACK accessor is
--     already on project time and reads from `range.t0` unchanged. Put that subtraction on the
--     wrong side and one file sits out of step with the others by however far into the item the
--     selection starts -- while every file is still the right LENGTH, so nothing looks wrong.
--
--   * `split_to_range` cuts BACK TO FRONT. SplitMediaItem returns the right-hand piece and
--     invalidates positions ahead of the cut, so cutting the left edge first moves the right
--     edge out from under the second call.

local M = {}

-- Below this, a range is not worth analysing: an FFT window plus a minimum note length leaves
-- nothing to detect, and a confident answer derived from two frames is worse than a refusal.
M.MIN_RANGE_S = 0.25

--- The current time selection, or nil when there is none.
function M.selection()
  if not reaper then return nil end
  local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not ts1 or ts1 <= ts0 then return nil end
  return ts0, ts1
end

--- Intersect an item's span with the time selection. Pure, so the arithmetic is unit-testable
--- without a project: every caller passes numbers it already has.
---
--- Returns { t0, t1, whole, from_selection } in PROJECT seconds, or nil plus a message.
--- `whole` means the range covers the item end to end, so nothing needs splitting.
function M.clip_range(item_pos, item_len, ts0, ts1, ignore)
  local i0, i1 = item_pos, item_pos + item_len

  if ignore or not ts1 or ts1 <= ts0 then
    return { t0 = i0, t1 = i1, whole = true, from_selection = false }
  end

  local r0, r1 = math.max(i0, ts0), math.min(i1, ts1)
  if r1 <= r0 then
    return nil, "The time selection does not overlap the item."
  end
  if r1 - r0 < M.MIN_RANGE_S then
    return nil, string.format(
      "The time selection covers only %.0f ms of the item; %.0f ms is the minimum.",
      (r1 - r0) * 1000, M.MIN_RANGE_S * 1000)
  end

  -- A selection reaching past both ends IS the whole item, and must not cause a split:
  -- splitting at an item's own edges leaves zero-length debris behind.
  local eps = 1e-9
  local whole = (r0 <= i0 + eps) and (r1 >= i1 - eps)
  return { t0 = r0, t1 = r1, whole = whole, from_selection = true }
end

--- Resolve the range for one item straight from the project.
function M.for_item(item, ignore)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local ts0, ts1 = M.selection()
  return M.clip_range(pos, len, ts0, ts1, ignore)
end

--- Which range the PROCESSING side should use, given the analysis range.
---
--- A named function because the obvious inline form is a trap:
---
---   render_range = process_whole_item and nil or range   -- ALWAYS yields `range`
---
--- `nil` is falsy, so the `or` always takes the second branch and the flag does nothing. That
--- shipped in two scripts and looked exactly like "the checkbox is ignored", because it was.
function M.render_range(range, process_whole_item)
  if process_whole_item then return nil end
  return range
end

--- Does an item overlap the range at all?
function M.overlaps(item, t0, t1)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return math.min(pos + len, t1) > math.max(pos, t0)
end

--- Keep only the clips a range actually touches.
---
--- A track normally holds several clips, and a selection over one phrase touches one of them
--- and misses the rest. Those others are not an error and not something to read: they are
--- simply outside the work.
function M.clips_in_range(clips, range)
  if not range or not range.from_selection then return clips end
  local out = {}
  for _, e in ipairs(clips) do
    if M.overlaps(e.item, range.t0, range.t1) then out[#out + 1] = e end
  end
  return out
end

--- Which clip of a list a range should be derived from.
---
--- The first clip of a track is the wrong answer whenever the track holds more than one: a
--- selection over the third phrase has nothing to do with the first clip, and asking clip_range
--- about it answers "the time selection does not overlap the item" -- true of that clip, and
--- not what was meant. The panel's range display and the run itself must both use this, or the
--- panel reports a refusal for a run that would have worked.
function M.anchor_clip(clips, ignore)
  if not clips or #clips == 0 then return nil end
  local ts0, ts1 = M.selection()
  if ignore or not ts1 then return clips[1] end
  for _, e in ipairs(clips) do
    if M.overlaps(e.item, ts0, ts1) then return e end
  end
  return nil, string.format(
    "The time selection (%.2f..%.2f) does not overlap any of the %d clip(s) on that track.",
    ts0, ts1, #clips)
end

--- The selected audio item to work on.
---
--- NOT simply the first selected one. REAPER hands items back in track-then-position order, so
--- with three clips selected on a track and a time selection over the third, "the first
--- selected" is a clip the selection does not touch -- and the run then refuses with "the time
--- selection does not overlap the item", which is true of that clip and false of what the user
--- meant. When a selection exists, the item under it is the one that was meant.
function M.selected_item(ignore)
  local audio = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    local tk = it and reaper.GetActiveTake(it)
    if tk and not reaper.TakeIsMIDI(tk) then audio[#audio + 1] = it end
  end
  if #audio == 0 then return nil, "Select an item with audio." end

  local ts0, ts1 = M.selection()
  if ignore or not ts1 then return audio[1] end

  for _, it in ipairs(audio) do
    if M.overlaps(it, ts0, ts1) then return it end
  end
  return nil, string.format(
    "The time selection (%.2f..%.2f) does not overlap any of the %d selected item(s).",
    ts0, ts1, #audio)
end

--- Cut an item down to exactly the processed range and hand back the middle piece.
---
--- The pieces either side keep the original take untouched, which is the point of splitting
--- rather than blending: nothing outside the range is re-rendered, so nothing outside it can
--- have changed.
function M.split_to_range(item, t0, t1)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local eps = 1e-9
  local middle = item

  -- Back to front: see the header.
  if t1 < pos + len - eps then
    if not reaper.SplitMediaItem(middle, t1) then
      return nil, "could not split at the end of the time selection"
    end
  end
  if t0 > pos + eps then
    local right = reaper.SplitMediaItem(middle, t0)
    if not right then
      return nil, "could not split at the start of the time selection"
    end
    middle = right                      -- the piece we want is the one AFTER the first cut
  end
  return middle
end

--- One line describing what will be processed, for a panel or a headless log.
function M.describe(range, item_pos, item_len)
  if not range then return "" end
  if not range.from_selection then
    return string.format("whole item, %.2fs", item_len)
  end
  if range.whole then
    return string.format("whole item, %.2fs (the time selection covers all of it)", item_len)
  end
  return string.format("time selection only: %.2fs of %.2fs, from %.2fs",
    range.t1 - range.t0, item_len, range.t0 - item_pos)
end

return M
