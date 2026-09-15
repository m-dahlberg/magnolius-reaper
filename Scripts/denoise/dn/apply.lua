-- @noindex
-- Spectral DeNoise -- stage 5: put the rendered file back in the project.
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

local M = {}

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

function M.run(item, take, result, cfg)
  local src = reaper.PCM_Source_CreateFromFile(result.path)
  if not src then return nil, "REAPER could not open " .. result.path end
  -- Before the undo block: this is not a project edit, and it must not sit
  -- inside PreventUIRefresh.
  build_peaks(src)

  local _, oldname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  local label = cfg.residual and " [residual]" or " [denoised]"

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local nt
  if cfg.new_take then
    nt = reaper.AddTakeToMediaItem(item)
    copy_props(take, nt)
  else
    nt = take
  end
  reaper.SetMediaItemTake_Source(nt, src)
  reaper.SetMediaItemTakeInfo_Value(nt, "D_STARTOFFS", 0)
  neutralize(nt)
  reaper.GetSetMediaItemTakeInfo_String(nt, "P_NAME", oldname .. label, true)
  reaper.GetSetMediaItemTakeInfo_String(nt, "P_EXT:denoise_profile",
    string.format("%.1f..%.1f dB, %.0f frames", cfg._band_lo or 0,
                  cfg._band_hi or 0, cfg._band_frames or 0), true)

  if cfg.new_take and cfg.select_take then
    reaper.SetActiveTake(nt)
  end

  reaper.UpdateItemInProject(item)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Spectral denoise", -1)
  return nt
end

return M
