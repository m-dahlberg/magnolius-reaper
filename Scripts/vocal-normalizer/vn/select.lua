-- @noindex
-- Vocal Normalizer -- which clips the pass operates on.
--
-- The rule is the simple one and it is stated rather than left to be
-- discovered: **every selected media item with an audio take**, in REAPER's
-- own order, which is track then position. MIDI takes and empty items are
-- skipped rather than refused, so selecting a whole track's worth of mixed
-- content does the obvious thing.
--
-- There is no "first selected" or "last selected" anywhere in this script, and
-- that is not an oversight: REAPER does not expose item selection ORDER.
-- GetSelectedMediaItem walks the project in track-then-position order however
-- the items were clicked, so any rule that depended on click order could not
-- be implemented, and -- more to the point -- could not be reproduced by a
-- headless run.

local M = {}

local function audio_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
  return nil
end

-- Returns { clips = { { item, take, name }, ... }, nsel, nskipped, err }.
-- `err` is set rather than raised: every caller of this -- the panel on every
-- frame, a headless run once -- wants to report it, not to stop.
function M.resolve()
  local out = { clips = {}, nsel = reaper.CountSelectedMediaItems(0),
                nskipped = 0 }
  for i = 0, out.nsel - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = audio_take(item)
    if take then
      local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      if name == "" then name = string.format("item %d", #out.clips + 1) end
      out.clips[#out.clips + 1] = { item = item, take = take, name = name }
    else
      out.nskipped = out.nskipped + 1
    end
  end
  if #out.clips == 0 then
    out.err = "Select one or more audio items."
  end
  return out
end

function M.describe(sel)
  if sel.err then return sel.err end
  local s = string.format("%d clip%s selected", #sel.clips,
                          #sel.clips == 1 and "" or "s")
  if sel.nskipped > 0 then
    s = s .. string.format(" (%d non-audio item%s skipped)",
                           sel.nskipped, sel.nskipped == 1 and "" or "s")
  end
  return s
end

return M
