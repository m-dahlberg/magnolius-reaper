-- @noindex
-- AutoTilt -- stage 5: attach the rendered files to the project.
--
-- The only module that touches the project. Everything above it computes; this
-- is the one place an undo block is opened and an item is changed, which is
-- what makes the undo behaviour reviewable by reading one file.
--
-- All of the target's clips go in under one undo block, so a comped row is one
-- undo step rather than eleven.

local Timesel = require "at.timesel"

local M = {}

local function get(t, k) return reaper.GetMediaItemTakeInfo_Value(t, k) end
local function set(t, k, v) reaper.SetMediaItemTakeInfo_Value(t, k, v) end

-- Properties the accessor did NOT apply, so the rendered audio still needs them.
local COPY_NUM = { "D_VOL", "D_PAN" }

-- Properties the accessor DID apply, already baked into the rendered file.
-- Applying them again would stretch stretched audio and re-fold folded
-- channels, which desyncs the take against the original by exactly the
-- playrate -- invisible until you A/B it, and invisible at playrate 1 because
-- every quantity involved is then the same number.
local NEUTRAL = { D_PLAYRATE = 1, D_PITCH = 0, B_PPITCH = 0, I_CHANMODE = 0 }

local function copy_props(from, to)
  for _, k in ipairs(COPY_NUM) do set(to, k, get(from, k)) end
end

-- Applied to WHICHEVER take ends up holding the rendered file, including the
-- original when the result replaces it in place. Doing this inside copy_props
-- would only cover the new-take path, and leave the replace-in-place path
-- silently double-applying the stretch it was meant to prevent.
local function neutralize(t)
  for k, v in pairs(NEUTRAL) do set(t, k, v) end
end

-- A rendered file gets no waveform unless its peaks are built: REAPER builds
-- them for files that arrive through an import path, and a source made with
-- PCM_Source_CreateFromFile and hung on a take has none. Nothing ever goes
-- looking, so the take plays back perfectly and draws an empty lane.
--
-- Measured on 7.75: PCM_Source_GetPeaks returns 0 samples for a freshly
-- written file and the full request after this runs. mode 0 starts and reports
-- whether there is anything to do, mode 1 runs a slice and returns non-zero
-- while more remains, mode 2 finishes.
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

-- `results` is a list of { item, take, result }, one per rendered target clip.
-- Returns the number of takes added, or nil + message.
-- `range` narrows the edit to a time selection: each item is split at its edges and only the
-- middle piece is touched, so nothing outside the selection is re-rendered.
function M.run(results, cfg, gain_db, range)
  if #results == 0 then return nil, "Nothing to apply" end

  -- Before the undo block: opening a source and building its peaks is not a
  -- project edit, and it must not sit inside PreventUIRefresh.
  local srcs = {}
  for i, r in ipairs(results) do
    local src = reaper.PCM_Source_CreateFromFile(r.result.path)
    if not src then
      return nil, "REAPER could not open " .. r.result.path
    end
    build_peaks(src)
    srcs[i] = src
  end

  local stamp = string.format("gain=%.2f pivot=%.0f band=%.0f-%.0f slope=%.2f",
    gain_db, cfg.pivot_hz, cfg.band_lo_hz, cfg.band_hi_hz, cfg.shelf_slope)
  local label = string.format(" [tilt %+.1f dB]", gain_db)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- No early return between here and PreventUIRefresh(-1): an unbalanced call
  -- leaves REAPER's UI frozen for the rest of the session.
  local added, split_err = 0, nil
  for i, r in ipairs(results) do
    local item, take = r.item, r.take

    -- Narrow the item first, so the render lands on a piece whose length matches it.
    if range and not range.whole then
      local middle, serr = Timesel.split_to_range(item, range.t0, range.t1)
      if middle then
        item = middle
        take = reaper.GetActiveTake(middle) or take
      else
        split_err = split_err or serr
      end
    end

    local _, oldname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)

    local nt
    if cfg.new_take then
      nt = reaper.AddTakeToMediaItem(item)
      copy_props(take, nt)
    else
      nt = take
    end
    reaper.SetMediaItemTake_Source(nt, srcs[i])
    set(nt, "D_STARTOFFS", 0)
    neutralize(nt)
    reaper.GetSetMediaItemTakeInfo_String(nt, "P_NAME", oldname .. label, true)

    -- What this pass did, in the project file, so a take can answer for itself
    -- long after the panel is closed.
    reaper.GetSetMediaItemTakeInfo_String(nt, "P_EXT:autotilt", stamp, true)

    if cfg.select_take then reaper.SetActiveTake(nt) end
    reaper.UpdateItemInProject(item)
    added = added + 1
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(string.format("AutoTilt %+.1f dB", gain_db), -1)
  if split_err then return nil, split_err end
  return added
end

return M
