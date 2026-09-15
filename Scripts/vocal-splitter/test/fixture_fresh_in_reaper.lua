-- Is test/vocalsplit_frames.tsv still what stage 1 produces?
--
-- Select the item holding "VocalSplit test.wav" and run from the Actions list.
--
-- This is the seam the frame fixture leaves open. test/detection.lua starts
-- from the fixture, so it cannot see a change to the EEL kernel, to the
-- accessor path, or to analyze.lua's reduction of the kernel's accumulators --
-- all of which would break the real pipeline while the suite stayed green.
-- This one closes it, by running stage 1 for real and comparing.
--
-- It is also sensitive enough to notice which *file* it was given: the fixture
-- was first taken from an item pointing at the 259 s source at offset 33.749,
-- which nulls against the exported test WAV at -113 dB RMS -- and still moved
-- frames in the room tone by up to 7 dB, because -64 dB of truncation noise is
-- loud next to a -85 dB floor. Take the fixture from the WAV the repo ships.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

local fails, checks = 0, 0
local function say(s) reaper.ShowConsoleMsg(s .. "\n") end
local function check(ok, msg, extra)
  checks = checks + 1
  if not ok then fails = fails + 1 end
  say(("  %s  %s%s"):format(ok and "ok  " or "FAIL", msg,
      extra and ("   (" .. extra .. ")") or ""))
end
local function bail(msg)
  check(false, msg)
  say(("\n%d/%d checks passed"):format(checks - fails, checks))
  if os.exit then os.exit(1) end
end

reaper.ShowConsoleMsg("")
say("Vocal Splitter -- is the frame fixture current?\n")

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is missing") return end
package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Config  = require "vs.config"
local Analyze = require "vs.analyze"
local Frames  = require "test.frames"

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then bail("no item selected -- nothing was checked") return end
local take = reaper.GetActiveTake(item)
if not take or reaper.TakeIsMIDI(take) then
  bail("the selected item has no audio take") return
end

-- Refuse the wrong file rather than compare against it. A region of the take
-- that the test WAV was exported from nulls against the WAV at -113 dB RMS and
-- still moves room-tone frames by 7 dB, so comparing produces a large,
-- convincing difference that points at stage 1 and means nothing of the kind.
local name = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(take), "")
say("source: " .. name)
if not name:find("VocalSplit test", 1, true) then
  bail("that is not the file the fixture describes -- select the item " ..
       "holding \"VocalSplit test.wav\"")
  return
end

-- Same reasoning for the playrate. The accessor applies it, so a stretched item
-- produces a completely different frame table and the comparison below would
-- report a large, convincing difference that points at stage 1 and means
-- nothing of the kind.
local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
if math.abs(playrate - 1) > 1e-9 then
  bail(("that item is at playrate %.4f -- the fixture describes the file at 1")
       :format(playrate))
  return
end

-- Defaults, not ExtState, exactly as dump_frames.lua writes it.
local cfg = Config.new()
local ctx = ImGui.CreateContext("vs fixture check")
local F, err = Analyze.run(take, cfg, ImGui, ctx, script_dir)
if not F then bail("analysis failed: " .. tostring(err)) return end

local ok, G = pcall(Frames.load, script_dir .. "test/vocalsplit_frames.tsv")
if not ok then bail("cannot read the fixture: " .. tostring(G)) return end

check(F.n == G.n, "frame count matches", ("%d vs %d"):format(F.n, G.n))
if F.n ~= G.n then
  say("\nRun test/dump_frames.lua to regenerate it.")
  say(("\n%d/%d checks passed"):format(checks - fails, checks))
  if os.exit then os.exit(1) end
  return
end

-- Tolerances are the fixture's own stored precision: %.2f on dB and %.4f on
-- the ratios. Anything larger is a real change in stage 1, not rounding.
local wd, ws, wv = 0, 0, 0
for i = 1, F.n do
  wd = math.max(wd, math.abs(F.level_db[i]    - G.level_db[i]))
  ws = math.max(ws, math.abs(F.sib_ratio[i]   - G.sib_ratio[i]))
  wv = math.max(wv, math.abs(F.voice_ratio[i] - G.voice_ratio[i]))
end
check(wd <= 0.005, "level_db matches", ("worst %.4f dB"):format(wd))
check(ws <= 0.00005, "sib_ratio matches", ("worst %.6f"):format(ws))
check(wv <= 0.00005, "voice_ratio matches", ("worst %.6f"):format(wv))

if fails > 0 then
  say("\nStage 1 has changed. Run test/dump_frames.lua to regenerate the")
  say("fixture, then re-run test/detection.lua and check the ground truth")
  say("still holds -- if it does not, that is the finding, not the fixture.")
end
say(("\n%d/%d checks passed"):format(checks - fails, checks))
if os.exit then os.exit(fails == 0 and 0 or 1) end
