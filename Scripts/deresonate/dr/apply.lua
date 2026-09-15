-- @noindex
-- The only file that touches the project.
--
-- The rendered audio goes back as a NEW TAKE on the same item, so A/B is a
-- take switch and the original is recoverable.
--
-- Three facts shape the take properties, and every one of them is invisible at
-- playrate 1:
--   * the accessor did NOT apply take volume or pan, so those are carried over;
--   * the accessor DID apply playrate, pitch, preserve-pitch and channel mode,
--     so copying them onto the new take applies all four a SECOND time -- the
--     take ends up the wrong length and drifts by exactly the playrate;
--   * D_STARTOFFS must be 0, because the render already starts at the item.
--
-- And a rendered file gets no waveform unless its peaks are built: REAPER
-- builds peaks for media that arrives through an import path, but a source made
-- with PCM_Source_CreateFromFile and hung on a take with SetMediaItemTake_Source
-- has none and nothing goes looking. It plays back perfectly and draws an empty
-- lane. Peak building is not a project edit, so it happens BEFORE the undo
-- block and outside PreventUIRefresh.

local M = {}

M.COPY_NUM = { "D_VOL", "D_PAN" }
M.NEUTRAL  = { D_PLAYRATE = 1, D_PITCH = 0, B_PPITCH = 0, I_CHANMODE = 0 }

local function build_peaks(src)
  if reaper.PCM_Source_BuildPeaks(src, 0) == 0 then return true end
  local slices = 0
  while reaper.PCM_Source_BuildPeaks(src, 1) ~= 0 do
    slices = slices + 1
    if slices > 100000 then break end       -- a missing waveform is worth far
  end                                       -- less than a hung REAPER
  reaper.PCM_Source_BuildPeaks(src, 2)
  return slices <= 100000
end

-- `results` is a list of { item, take, render, stamp }.
function M.run(results, cfg)
  local sources = {}
  for i, r in ipairs(results) do
    local src = reaper.PCM_Source_CreateFromFile(r.render.path)
    if not src then return nil, "could not open " .. r.render.path end
    build_peaks(src)
    sources[i] = src
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  -- no early return between here and PreventUIRefresh(-1): an unbalanced call
  -- freezes REAPER's UI for the session
  local err, n = nil, 0
  for i, r in ipairs(results) do
    local old, src = r.take, sources[i]
    local nt = cfg.new_take and reaper.AddTakeToMediaItem(r.item) or old
    if not nt then
      err = err or "could not add a take"
    else
      reaper.SetMediaItemTake_Source(nt, src)
      for _, key in ipairs(M.COPY_NUM) do
        reaper.SetMediaItemTakeInfo_Value(nt, key,
          reaper.GetMediaItemTakeInfo_Value(old, key))
      end
      for key, v in pairs(M.NEUTRAL) do
        reaper.SetMediaItemTakeInfo_Value(nt, key, v)
      end
      reaper.SetMediaItemTakeInfo_Value(nt, "D_STARTOFFS", 0)
      local _, nm = reaper.GetSetMediaItemTakeInfo_String(old, "P_NAME", "", false)
      reaper.GetSetMediaItemTakeInfo_String(nt, "P_NAME", (nm or "") .. " [deresonated]", true)
      reaper.GetSetMediaItemTakeInfo_String(nt, "P_EXT:deresonate", r.stamp or "", true)
      if cfg.select_take and cfg.new_take then
        reaper.SetMediaItemInfo_Value(r.item, "I_CURTAKE",
          reaper.CountTakes(r.item) - 1)
      end
      n = n + 1
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("DeResonate", -1)
  if err then return nil, err end
  return n
end

return M
