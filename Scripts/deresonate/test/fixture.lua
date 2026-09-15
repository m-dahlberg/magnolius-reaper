-- A fixture track the suite creates and removes, in whatever project is open.
--
-- This is the third approach tried, and the reasoning matters because the
-- other two look better than they are.
--
-- Editing the user's SELECTED item -- what the sibling scripts do -- destroyed
-- an unsaved session during development. A suite has no business touching
-- something the user chose.
--
-- A throwaway project TAB looks like the clean answer and cannot be made to
-- work. Measured on 7.75: `Undo_BeginBlock`/`Undo_EndBlock` sets the project
-- dirty flag, and NOTHING clears it -- not `Main_SaveProjectEx` (which returns
-- success), not `Main_SaveProject`, not the Save action, not deleting every
-- track and saving the empty result. `Main_openProject("noprompt:...")` does
-- yield a clean project but opens it in a NEW tab, leaving the dirty one
-- behind. So a tab that has run `Apply.run` -- which the suite exists to
-- exercise, and which must use an undo block -- can never be closed silently,
-- and the close raises a modal save prompt that hangs the run until somebody
-- clicks it. Measured: a 6.4 second close.
--
-- What is left is this: add a track at the end, work only inside it, delete it.
-- Existing items are never touched, the item selection is restored, and there
-- is nothing to close, so nothing can prompt and nothing can leak. The project
-- does end up dirty -- but every script that edits a project does that, and it
-- costs nothing because we are not trying to close it.

local M = {}

local function selection()
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    sel[#sel + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  return sel
end

local function restore(sel)
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(sel) do
    -- an item the body deleted must not resurrect an error here
    pcall(reaper.SetMediaItemSelected, it, true)
  end
end

-- Add a media item to `track`. Returns item, take.
function M.add_item(track, path, pos, len, playrate)
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil, "could not open " .. path end
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos or 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len or 6.0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playrate or 1.0)
  return item, take
end

-- fn(track) runs with a fresh empty track at the end of the project.
-- Returns fn's results, then whether the project was left as it was found.
function M.run(fn)
  local tracks0 = reaper.CountTracks(0)
  local items0  = reaper.CountMediaItems(0)
  local sel     = selection()

  -- at the END, so no existing track's index moves under the body's feet
  reaper.InsertTrackAtIndex(tracks0, true)
  local tr = reaper.GetTrack(0, tracks0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "DeResonate test fixture", true)

  local ok, a, b = pcall(fn, tr)

  -- delete the fixture track whatever happened; its items go with it
  pcall(reaper.DeleteTrack, tr)
  restore(sel)
  reaper.UpdateArrange()

  local clean = (reaper.CountTracks(0) == tracks0)
            and (reaper.CountMediaItems(0) == items0)
  if not ok then return nil, a, clean end
  return a, b, clean
end

return M
