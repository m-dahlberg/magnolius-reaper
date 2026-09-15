-- The whole pipeline, end to end, on a fixture track this suite creates and
-- removes.
--
-- It never looks at the user's selected item. That is a deliberate departure
-- from the sibling scripts: running this suite repeatedly against a real
-- session destroyed one during development, and a test that can eat your work
-- is not a test worth having. See test/fixture.lua for why a throwaway project
-- tab, which looks like the better answer, cannot be closed silently.
--
-- Two fixtures every run: playrate 1.0 and playrate 1.25. At playrate 1 every
-- quantity in the take geometry is the same number, so every scaling mistake
-- passes; the stretched case is the one that can fail.
--
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/verify_edit_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;"
            .. (reaper.ImGui_GetBuiltinPath() and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "")
            .. package.path

local pass, fail = 0, 0
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function near(a,b,tol,name)
  local g = a and b and math.abs(a-b) <= tol
  ok(g, name, g and nil or string.format("%s vs %s tol %s", tostring(a), tostring(b), tostring(tol)))
end
local function report()
  print(string.format("\nverify: %d passed, %d failed", pass, fail))
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function bail(m) fail = fail + 1; print("  FAIL " .. m); report() end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui") end
local ImGui   = require "imgui" "0.9"
local Config  = require "dr.config"
local Kernel  = require "dr.kernel"
local Analyze = require "dr.analyze"
local Render  = require "dr.render"
local Apply   = require "dr.apply"
local Fixture = require "fixture"

local ctx = ImGui.CreateContext("DeResonate verify")

local FIXTURE = root .. "Room reverb example.wav"
do
  local fh = io.open(FIXTURE, "r")
  if not fh then bail("fixture wav missing: " .. FIXTURE) end
  fh:close()
end

local function read_all(take)
  local geo = Analyze.geometry(take)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local span = math.min(reaper.GetAudioAccessorEndTime(aa)
                        - reaper.GetAudioAccessorStartTime(aa), geo.item_len)
  local total = math.floor(span * geo.rate)
  local buf = reaper.new_array(8192 * geo.nchan)
  local out, done = {}, 0
  while done < total do
    local n = math.min(8192, total - done)
    buf.clear(0)
    reaper.GetAudioAccessorSamples(aa, geo.rate, geo.nchan, done / geo.rate, n, buf)
    local t = buf.table(1, n * geo.nchan)
    for i = 1, n * geo.nchan do out[done * geo.nchan + i] = t[i] end
    done = done + n
  end
  reaper.DestroyAudioAccessor(aa)
  return out
end

local function null_db(a, b, shift)
  local num, den, n = 0, 0, 0
  for i = 2000, math.min(#a, #b - shift) do
    local d = b[i + shift] - a[i]
    num = num + d * d; den = den + a[i] * a[i]; n = n + 1
  end
  if n == 0 or den == 0 then return 0 end
  return 10 * math.log(num / den + 1e-30, 10)
end

local function verify(track, playrate, pos)
  local label = string.format("playrate %.2f", playrate)
  print("\n-- " .. label)
  local item, take = Fixture.add_item(track, FIXTURE, pos, 6.0, playrate)
  if not item then ok(false, label .. ": could not build the fixture"); return end
  reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 0.5)

  local geo = Analyze.geometry(take)
  print(string.format("     %.2f s, %d ch, %d Hz, playrate %.3f",
    geo.item_len, geo.nchan, geo.rate, geo.playrate))
  local before = read_all(take)
  if not before then ok(false, label .. ": could not read the fixture"); return end

  local cfg = Config.new()
  cfg.dereverb_on = false                      -- zero bands, no dereverb:
  local k = Kernel.new(ImGui, ctx, root, geo.nchan, cfg)  -- must be a null
  if not k then ok(false, label .. ": kernel would not build"); return end

  local path = Render.output_path(take, cfg, {})
  local res, err = Analyze.drive(Render.run(take, cfg, k, {}, nil, path))
  if not res then ok(false, label .. ": render failed: " .. tostring(err)); return end
  ok(res.samples > 0, label .. ": render produced samples", res.samples)
  near(res.rate, geo.rate, 0, label .. ": written at the SOURCE rate")

  local n, aerr = Apply.run({ { item = item, take = take, render = res,
                               stamp = "verify" } }, cfg)
  ok(n == 1, label .. ": applied as a new take", aerr)

  local nt = reaper.GetActiveTake(item)
  ok(nt ~= take, label .. ": the active take is the new one")
  near(reaper.GetMediaItemTakeInfo_Value(nt, "D_PLAYRATE"), 1.0, 0,
       label .. ": new take playrate is NEUTRAL (copying it desyncs by the playrate)")
  near(reaper.GetMediaItemTakeInfo_Value(nt, "D_STARTOFFS"), 0.0, 0,
       label .. ": new take start offset is 0")
  near(reaper.GetMediaItemTakeInfo_Value(nt, "D_VOL"), 0.5, 1e-9,
       label .. ": take volume carried over (the accessor never applied it)")

  local pbuf = reaper.new_array(64 * 2)
  pbuf.clear(0)
  local pret = reaper.PCM_Source_GetPeaks(reaper.GetMediaItemTake_Source(nt),
                                          8, 0, 1, 64, 0, pbuf)
  local pt = pbuf.table(1, 64)
  local nonzero = false
  for i = 1, 64 do if pt[i] ~= 0 then nonzero = true break end end
  ok((pret & 0xFFFFF) > 0, label .. ": peaks were built", pret & 0xFFFFF)
  ok(nonzero, label .. ": and they are not all zeros")

  local after = read_all(nt)
  if after then
    local e0, em = null_db(before, after, 0), null_db(before, after, 1)
    ok(e0 <= -80, label .. ": nulls against the source at <= -80 dB",
       string.format("%.1f dB", e0))
    ok(em > e0 + 20, label .. ": and one sample off is clearly worse",
       string.format("0: %.1f, +1: %.1f", e0, em))
  end
  os.remove(res.path)
end

local user_tracks = reaper.CountTracks(0)
local user_items  = reaper.CountMediaItems(0)
local user_sel    = reaper.CountSelectedMediaItems(0)

local _, err, clean = Fixture.run(function(track)
  verify(track, 1.00, 37.5)
  verify(track, 1.25, 120.0)
end)
if err then ok(false, "the fixture run raised: " .. tostring(err)) end

ok(clean, "the fixture track was removed")
ok(reaper.CountTracks(0) == user_tracks and reaper.CountMediaItems(0) == user_items,
   "and the project has exactly the tracks and items it started with",
   string.format("%d/%d tracks, %d/%d items", reaper.CountTracks(0), user_tracks,
                 reaper.CountMediaItems(0), user_items))
ok(reaper.CountSelectedMediaItems(0) == user_sel,
   "and the item selection is restored", reaper.CountSelectedMediaItems(0))
report()
