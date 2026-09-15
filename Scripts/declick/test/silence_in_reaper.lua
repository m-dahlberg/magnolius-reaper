-- Does the derived threshold survive edited-in silence? Run from the Actions
-- list, or through reascript_test.py. Needs no selection.
--
-- The threshold is read off the shape of the OVERSHOOT distribution, and
-- overshoot is a ratio against a candidate's own local background. That is the
-- detector's great strength -- a click in a loud passage and one in a quiet
-- passage land in the same place -- and it is exactly why a passage holding no
-- audio at all still produces candidates: the dither fluctuating against
-- itself. They never survive a threshold, so nothing is repaired that should
-- not be, and every existing test in this repo is blind to them.
--
-- What they do is dilute the distribution the threshold is READ off.
-- `tail_departure` anchors its fit on p50..p95, so a thousand junk candidates
-- at the bottom drag those anchors down and the threshold with them -- in the
-- AGGRESSIVE direction, which is the wrong one for a de-clicker.
--
-- Measured before dc/silence.lua existed, on a take with the silence trimmed
-- off for comparison:
--
--     27 % silence   8.88 dB  vs  9.12 dB
--     67 % silence   6.12 dB  vs  9.12 dB
--     80 % silence   6.12 dB  vs  8.12 dB
--
-- Two fixtures, because one cannot do both jobs.
--
--   `De-click test 02.wav` is a 16-bit master whose pauses have been stripped:
--   its first twenty seconds are noise-shaped DITHER over digital silence,
--   27 % of the file. That is what reproduces the bug, and it has to be dither
--   rather than zeros -- an item run out past its source appends pure silence,
--   which has nothing to fluctuate and so produces almost no candidates at
--   all. An earlier version of this file did exactly that, and its "the guard
--   is doing something" assertion passed with both sides equal.
--
--   `De-click test 01.wav` is true 24-bit with a continuous -73 dB floor and
--   no edited silence anywhere. It is the control: a rule that found silence
--   in everything would satisfy every other assertion here.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir   = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function report()
  reaper.ShowConsoleMsg("\n=== De-Click: edited-in silence ===\n"
                        .. table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fails == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then say("  ok    " .. name)
  else fails = fails + 1
       say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function bail(s) fails = fails + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then bail("Requires ReaImGui.") return end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui      = require "imgui" "0.9"
local Kernel     = require "dc.kernel"
local Config     = require "dc.config"
local Analyze    = require "dc.analyze"
local Detect     = require "dc.detect"
local AutoThresh = require "dc.autothresh"

-- Test 01 and not test 02: 02 is a 16-bit master whose pauses have ALL been
-- stripped, so it has edited silence throughout and cannot serve as the
-- control. 01 is true 24-bit with a continuous -73 dB floor and no silence in
-- it at all, which is what makes "no floor is found here" a real assertion.
local DITHERED   = script_dir .. "De-click test 02.wav"
local CONTINUOUS = script_dir .. "De-click test 01.wav"

local ctx = ImGui.CreateContext("DeClick silence")

local function measure(track, wav, startoffs, len, skip, label)
  local psrc = reaper.PCM_Source_CreateFromFile(wav)
  if not psrc then error("could not open " .. wav, 0) end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, psrc)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  if len <= 0 then len = reaper.GetMediaSourceLength(psrc) - startoffs end
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", startoffs)

  local cfg = Config.new()
  cfg.skip_silence = skip
  local geo = Analyze.geometry(take)
  local k, kerr = Kernel.new(ImGui, ctx, script_dir, geo, cfg)
  if not k then error("kernel: " .. tostring(kerr), 0) end
  local res, aerr = Analyze.drive(function() return Analyze.run(take, cfg, k) end)
  if not res then error("analysis: " .. tostring(aerr), 0) end

  local hist = Detect.survey(k, cfg)
  local th = AutoThresh.derive(hist, cfg)
  local sil = hist.silence
  say(string.format("  %-38s skip=%-5s %6d cands  floor %8s  "
                    .. "derived %5.2f dB  survivors %3d",
      label, tostring(skip), th.total or -1,
      sil and sil.floor_db and string.format("%.0f dB", sil.floor_db) or "--",
      th.derived_db or -99, th.survivors or -1))
  reaper.DeleteTrackMediaItem(track, item)
  return { derived = th.derived_db, total = th.total,
           survivors = th.survivors, sil = sil }
end

-- The fixture track: added at the END of whatever project is open and deleted
-- on the way out, so nothing the user selected is touched.
local tracks0, items0 = reaper.CountTracks(0), reaper.CountMediaItems(0)
local sel = {}
for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
  sel[#sel + 1] = reaper.GetSelectedMediaItem(0, i)
end
reaper.InsertTrackAtIndex(tracks0, true)
local tr = reaper.GetTrack(0, tracks0)

local runok, err = pcall(function()
  -- 1. The bug: 20 s of dithered silence at the head of a 74 s take, against
  --    the same take with that head trimmed off.
  local trimmed = measure(tr, DITHERED, 20.5, 53.5, true,  "dithered: lead-in trimmed off")
  local whole   = measure(tr, DITHERED, 0.0,  74.0, true,  "dithered: 27% silence, guard on")
  local raw     = measure(tr, DITHERED, 0.0,  74.0, false, "dithered: 27% silence, guard OFF")

  ok(trimmed.derived and whole.derived and raw.derived,
     "a threshold is derived in every case")
  -- The assertion the file exists for: the threshold may not depend on how
  -- much edited silence the take happens to carry.
  ok(whole.derived and trimmed.derived
     and math.abs(whole.derived - trimmed.derived) <= 0.25,
     "the threshold matches the take with the silence trimmed off",
     string.format("%.2f with silence vs %.2f without",
                   whole.derived or -99, trimmed.derived or -99))
  -- And the guard is doing the work. Without this the test above would pass
  -- just as well if the whole mechanism did nothing.
  ok(raw.derived and whole.derived and whole.derived > raw.derived + 0.1,
     "with the guard off the threshold reads lower, as it used to",
     string.format("%.2f off vs %.2f on", raw.derived or -99, whole.derived or -99))
  ok(whole.sil and whole.sil.floor_db ~= nil,
     "the silence is found and reported",
     whole.sil and tostring(whole.sil.floor_db) or "no record")
  ok(whole.sil and whole.sil.skipped > 0.2 * whole.sil.total,
     "and its size is reported roughly correctly",
     whole.sil and string.format("%.0f%% of the file",
       100 * whole.sil.skipped / math.max(whole.sil.total, 1)) or "no record")

  -- 2. The control. A rule that found silence in everything would satisfy
  --    every assertion above; this is the one that says it does not.
  say("")
  local clean = measure(tr, CONTINUOUS, 0.0, 0.0, true, "continuous 24-bit take")
  ok(clean.sil and clean.sil.floor_db == nil,
     "no floor is found in a take that has no edited silence",
     clean.sil and tostring(clean.sil.floor_db) or "no record")
end)

pcall(reaper.DeleteTrack, tr)
reaper.SelectAllMediaItems(0, false)
for _, it in ipairs(sel) do
  if reaper.ValidatePtr(it, "MediaItem*") then
    reaper.SetMediaItemSelected(it, true)
  end
end

if not runok then fails = fails + 1 say("  FAIL  " .. tostring(err)) end
if reaper.CountTracks(0) ~= tracks0 or reaper.CountMediaItems(0) ~= items0 then
  fails = fails + 1
  say("  FAIL  the fixture track was not cleaned up")
end
say("")
say(fails == 0 and "all checks passed" or (fails .. " failed"))
report()
