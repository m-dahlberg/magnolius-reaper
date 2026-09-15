-- Vocal Normalizer -- panel frame check. Runs inside REAPER.
--
-- The panel is the one file no other suite executes, and it is where a renamed
-- config key or a helper used above its own definition lands -- as a nil read
-- that errors the frame and takes the whole window below it with it. This
-- renders it, against a stub ImGui (test/ui_frame.lua), in every state the
-- panel actually has:
--
--   * empty, with nothing analysed;
--   * populated, with results and plots to draw;
--   * with EVERY control reporting that it was just moved, which is the only
--     way to execute the code behind a slider rather than the drawing of it;
--   * with the optional ImGui symbols missing, which is the build somebody
--     else is running.
--
-- It never clicks Apply or Reset volume: those write to the project, and a
-- test that quietly re-gains the user's selected items would be worse than no
-- test. The buttons it does click are the ones that only touch settings, and
-- the whole ExtState section is snapshotted and put back afterwards, because
-- rendering with `changed` set makes every control save itself.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local restore = {}
local function say(s) out[#out + 1] = s end
local function report()
  for i = #restore, 1, -1 do pcall(restore[i]) end
  say(string.format("panel: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then
  say("  FAIL  ReaImGui is not installed") fail = 1 report() return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local Frame    = require "ui_frame"
local UI       = require "vn.ui"
local Config   = require "vn.config"
local Loudness = require "vn.loudness"

-- Snapshot the saved settings. _init loads from ExtState and the `changed`
-- cases save to it, so without this a test run would leave the user's panel
-- set to whatever the last stub slider happened to report.
do
  local saved = {}
  for k in pairs(Config.defaults) do
    if reaper.HasExtState(Config.EXT_SECTION, k) then
      saved[k] = reaper.GetExtState(Config.EXT_SECTION, k)
    end
  end
  restore[#restore + 1] = function()
    for k in pairs(Config.defaults) do
      if saved[k] then reaper.SetExtState(Config.EXT_SECTION, k, saved[k], true)
      else reaper.DeleteExtState(Config.EXT_SECTION, k, true) end
    end
  end
end

------------------------------------------------------------------ fixtures

-- A frame table with the shape vn.analyze produces, so the panel's plots and
-- table have something real-looking to draw without an accessor anywhere.
local function frames(db_segs)
  local F = { hop_s = 0.1, n = 0, zb = {}, zk = {}, cnt = {}, peak = 0.4,
              rate = 48000, nchan = 1, span = 0, item_len = 0,
              playrate = 1, item_pos = 0 }
  for _, s in ipairs(db_segs) do
    for _ = 1, s.n do
      local i = F.n + 1
      F.n = i
      local ms = 10 ^ ((s.db - Loudness.OFFSET) / 10)
      F.zb[i], F.zk[i], F.cnt[i] = ms * 4800, ms * 4800 * 2, 4800
    end
  end
  F.span = F.n * F.hop_s
  F.item_len = F.span
  return F
end

local function populate(ST, cfg)
  local geo = { rate = 48000, nchan = 1, take_vol = 1, item_vol = 1,
                rate_known = true, item_len = 12, item_pos = 0, playrate = 1 }
  ST.clips = {
    { item = nil, take = nil, name = "lead vox", geo = geo,
      F = frames({ { db = -18, n = 60 }, { db = -55, n = 30 },
                   { db = -15, n = 60 } }) },
    { item = nil, take = nil, name = "double", geo = geo,
      F = frames({ { db = -24, n = 90 } }) },
  }
  ST.analysed_key = "fixture"
  ST.clip_idx = 1
  ST.priced = nil          -- forces the frame to re-price, exercising that path
  ST.status = "fixture"
end

-- A clip whose source reported no sample rate, and one with nothing above the
-- absolute gate: the two states the readout has a special line for, and the
-- two the plots have to survive.
local function populate_odd(ST, cfg)
  local geo = { rate = 44100, nchan = 2, take_vol = 1, item_vol = 1,
                rate_known = false, item_len = 1, item_pos = 0, playrate = 1.25 }
  ST.clips = {
    { name = "guessed rate", geo = geo, F = frames({ { db = -140, n = 40 } }) },
    { name = "too short", geo = geo, F = frames({ { db = -20, n = 2 } }) },
  }
  ST.analysed_key = "fixture"
  ST.clip_idx = 1
  ST.priced = nil
end

--------------------------------------------------------------------- cases

local function case(name, prepare, clicks, changed, drop)
  local ran, err, log = Frame.run(UI, script_dir, prepare, clicks, changed, drop)
  ok(ran, name, tostring(err))
  ok(log.push == log.pop, name .. ": style colours balance",
     string.format("%d pushed, %d popped", log.push, log.pop))
  ok(log.dis == 0, name .. ": disabled scopes balance", tostring(log.dis))
  ok(log.child == 0, name .. ": child windows balance", tostring(log.child))
  return log
end

case("an empty panel renders")
case("a populated panel renders", populate)
case("the odd states render", populate_odd)

-- Every control reporting "just moved". This is the case that executes the
-- code BEHIND each slider and checkbox, which is where a panel's worst bugs
-- live -- a stub whose controls always report false never runs those branches.
case("every control moved", populate, nil, true)
case("every control moved, empty", nil, nil, true)

-- The branches that only appear under a setting.
case("percentile controls render", function(ST, cfg)
  populate(ST, cfg)
  cfg.reduce = "percentile"
end, nil, true)
case("linked mode renders", function(ST, cfg)
  populate(ST, cfg)
  cfg.link_items = true
end, nil, true)
case("the peak ceiling is off", function(ST, cfg)
  populate(ST, cfg)
  cfg.limit_peak = false
end)
case("the controls column is hidden", function(ST, cfg)
  populate(ST, cfg)
  ST.show_controls = false
end)
case("a job in flight renders", function(ST, cfg)
  populate(ST, cfg)
  ST.job = coroutine.create(function() coroutine.yield(0.5) end)
  ST.jobkind, ST.progress = "Analysing", 0.5
end)
case("an error line renders", function(ST, cfg)
  populate(ST, cfg)
  ST.err = "something went wrong"
end)

-- The safe buttons. Apply and Reset volume are deliberately absent: they write
-- to the project.
case("band presets click", populate, { ["Male lead"] = true,
                                       ["Full band"] = true })
case("target from this clip clicks", populate,
     { ["Target from this clip"] = true })
case("reset settings clicks", populate, { ["Reset settings"] = true })
case("a table row selects", populate, { ["double##row2"] = true })

-- Somebody else's ReaImGui: the optional symbols the panel reads through pcall
-- have to actually work when they are not there.
case("without the optional symbols", populate, nil, false,
     { SeparatorText = true, ChildFlags_ResizeX = true,
       ChildFlags_Borders = true })

report()
