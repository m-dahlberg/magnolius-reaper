-- @noindex
-- Resolve the project selection into clips to analyse.
--
-- REAPER does not expose item selection ORDER -- GetSelectedMediaItem walks
-- track then position, and there is no item equivalent of GetLastTouchedTrack
-- -- so any rule that depends on "the one you clicked first" is unreliable.
-- DeResonate does not need one: it analyses every selected item that carries
-- an audio take.
--
-- Never raises. `out.err` is set instead, because every caller -- the panel
-- every frame, a headless action once -- wants to report it, not to stop.

local M = {}

function M.resolve(cfg)
  local out = { clips = {}, nsel = 0, err = nil }
  if not reaper then out.err = "no REAPER"; return out end
  local n = reaper.CountSelectedMediaItems(0)
  out.nsel = n
  if n == 0 then out.err = "Select an item with audio."; return out end
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      out.clips[#out.clips + 1] = { item = item, take = take }
    end
  end
  if #out.clips == 0 then out.err = "The selection holds no audio takes." end
  return out
end

function M.describe(sel)
  if sel.err then return sel.err end
  local first = sel.clips[1]
  local name = first and select(2, reaper.GetSetMediaItemTakeInfo_String(
    first.take, "P_NAME", "", false)) or "?"
  if #sel.clips == 1 then return string.format("1 clip: %s", name) end
  return string.format("%d clips, first: %s", #sel.clips, name)
end

return M
