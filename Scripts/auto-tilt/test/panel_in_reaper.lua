-- AutoTilt -- the panel against the REAL ReaImGui.
--
-- test/ui_frame.lua drives frame() against a stub, which catches every Lua
-- error in the panel and cannot catch a single ImGui mistake: the stub answers
-- any call with any arguments, so a wrong argument count, a renamed symbol or
-- an unbalanced Begin/End all sail through it and then kill the panel the
-- first time a user opens it. This suite is the other half.
--
-- It has to run as a deferred script -- ImGui refuses to draw outside the
-- defer cycle, and forcing a frame from the main thread blocks REAPER on a
-- modal task dialog -- so it cannot be driven by reascript_test.py, which
-- reports success as soon as the FILE finishes loading, before a single frame
-- has been drawn. tools/run_panel_test.py launches it and waits for the result
-- file this writes instead.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

local sep = package.config:sub(1, 1)
local RESULT = (os.getenv("TMPDIR") or "/tmp") .. sep .. "autotilt-panel-result.txt"

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end

local function finish()
  say(string.format("\npanel: %d passed, %d failed", pass, fail))
  local text = table.concat(out, "\n") .. "\n"
  local fh = io.open(RESULT, "wb")
  if fh then fh:write(text) fh:write(fail == 0 and "RESULT OK\n" or "RESULT FAIL\n") fh:close() end
  reaper.ShowConsoleMsg(text)
end

local function bail(msg)
  fail = fail + 1
  say("  FAIL  " .. msg)
  finish()
end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") return end
package.path = script_dir .. "?.lua;" .. script_dir .. "test/?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui = require "imgui" "0.9"
local Config = require "at.config"
local UI     = require "at.ui"
local Frame  = require "ui_frame"

-- Config.save would write this suite's cfg over the user's stored settings.
Config.save = function() end

local ST, cfg = UI._init(ImGui, script_dir)
local ctx = ImGui.CreateContext("AutoTilt panel test")

local function populated()
  cfg.fft_size, cfg.ana_hop = 256, 64
  ST.k = { fft_size = 256, nbins = 129 }
  ST.ana = {
    geo = { rate = 48000, nchan = 1, item_len = 4, rate_known = true },
    target = Frame.stub_ana(256, 48000, -5, 200, 90),
    ref    = Frame.stub_ana(256, 48000, -1, 180, 92),
  }
  ST.cache_key, ST.msig, ST.ssig = "x", nil, nil
end

local states = {
  { "empty", function()
      ST.ana, ST.k, ST.mt, ST.mr, ST.err, ST.note, ST.manual = nil end },
  { "populated", populated },
  { "populated, no reference", function() populated() ST.ana.ref = nil end },
  { "busy", function()
      populated()
      ST.job = coroutine.create(function() end)
      ST.jobkind, ST.progress = "Analysing", 0.42 end },
  { "error and note", function()
      populated() ST.job = nil
      ST.err = "a reported failure" ST.note = "a note" end },
  { "manual gain", function()
      populated() ST.job, ST.err, ST.note = nil, nil, nil
      ST.manual = 3.25 end },
  { "pivot outside the band", function()
      populated() ST.manual = nil
      cfg.pivot_hz, ST.msig, ST.ssig = 80, nil, nil end },
}

local idx, frames_per, drawn, done = 1, 3, 0, false

local function loop()
  if done then return end

  if drawn == 0 then
    local prep = states[idx][2]
    local okp, perr = pcall(prep)
    if not okp then ok(false, "prepare: " .. states[idx][1], tostring(perr)) end
  end

  -- Cond_Always, or ImGui's persisted collapsed state can leave the window
  -- shut and every frame trivially "passing" without drawing anything.
  ImGui.SetNextWindowSize(ctx, 620, 900, ImGui.Cond_Always)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, "AutoTilt panel test", true)
  local ran, err = true, nil
  if visible then
    ran, err = pcall(UI._frame)
    if not ran then
      while UI._disabled_depth() > 0 do pcall(ImGui.EndDisabled, ctx) end
    end
    ImGui.End(ctx)
  end

  if drawn == frames_per - 1 then
    ok(visible, "the window actually drew: " .. states[idx][1])
    ok(ran, "renders against the real ReaImGui: " .. states[idx][1], tostring(err))
    ok(UI._disabled_depth() == 0,
       "disabled stack balances: " .. states[idx][1],
       tostring(UI._disabled_depth()))
  end

  drawn = drawn + 1
  if drawn >= frames_per then
    drawn = 0
    idx = idx + 1
  end

  if idx > #states or not open then
    done = true
    finish()
    return
  end
  reaper.defer(loop)
end

os.remove(RESULT)
reaper.defer(loop)
