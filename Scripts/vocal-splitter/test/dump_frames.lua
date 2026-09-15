-- Regenerate test/vocalsplit_frames.tsv from the selected item.
--
-- Select the item that holds "VocalSplit test.wav" and run this from the
-- Actions list. Stage 1 is the only part of the pipeline the frame fixture
-- cannot cover, so this has to be re-run -- and test/detection.lua re-checked
-- -- whenever the kernel or the accessor path changes.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowConsoleMsg("FAIL  ReaImGui is missing.\n")
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Config  = require "vs.config"
local Analyze = require "vs.analyze"
local Frames  = require "test.frames"

local function say(s) reaper.ShowConsoleMsg(s .. "\n") end

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  say("FAIL  select the test item first.")
  if os.exit then os.exit(1) end
  return
end
local take = reaper.GetActiveTake(item)
if not take or reaper.TakeIsMIDI(take) then
  say("FAIL  the selected item has no audio take.")
  if os.exit then os.exit(1) end
  return
end

-- Refuse anything but the file the fixture is named for. Taking it from a
-- region of the take the WAV was exported from is a trap that has already been
-- fallen into: the two null at -113 dB RMS and still differ by up to 7 dB in
-- the room tone, because -64 dB of truncation noise is loud next to a -85 dB
-- floor. The fixture should describe the file the tests name.
local name = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(take), "")
if not name:find("VocalSplit test", 1, true) then
  say("FAIL  the selected item is " .. name)
  say("      select the item holding \"VocalSplit test.wav\" instead.")
  if os.exit then os.exit(1) end
  return
end

-- And refuse a stretched take. The accessor returns audio with the playrate
-- already applied, so a fixture dumped from one describes stretched, pitch-
-- shifted material -- while the ground truth in test/detection.lua is a list of
-- timestamps taken off the file at playrate 1.
local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
if math.abs(playrate - 1) > 1e-9 then
  say(("FAIL  the selected item is at playrate %.4f."):format(playrate))
  say("      The fixture must be dumped at playrate 1: the accessor applies")
  say("      the stretch, and detection.lua's timestamps are of the unstretched")
  say("      file.")
  if os.exit then os.exit(1) end
  return
end

-- Defaults, not ExtState: the fixture must not depend on whatever the panel
-- was last left set to.
local cfg = Config.new()
local ctx = ImGui.CreateContext("vs dump")
local F, err = Analyze.run(take, cfg, ImGui, ctx, script_dir)
if not F then
  say("FAIL  analysis failed: " .. tostring(err))
  if os.exit then os.exit(1) end
  return
end

local out = script_dir .. "test/vocalsplit_frames.tsv"
Frames.save(F, out)
say(("wrote %d frames to %s"):format(F.n, out))
say("Now re-run test/detection.lua and check the ground truth still holds.")
if os.exit then os.exit(0) end
