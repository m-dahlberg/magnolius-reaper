-- Track Manager -- the panel against the REAL ReaImGui.
--
-- test/ui_frame.lua drives frame() against a stub, which catches every Lua
-- error in the panel and cannot catch a single ImGui mistake: the stub answers
-- any call with any arguments, so a wrong argument count or a renamed symbol
-- sails through it and then kills the panel the first time a user opens it.
-- This suite is the other half, and here it carries more weight than usual:
-- the panel is pinned to ReaImGui 0.9 and leans on symbols none of its
-- siblings use -- Key_Keypad1..9, Key_KeypadAdd, WindowFlags_TopMost -- and
-- whether those exist at 0.9 is exactly the kind of thing that cannot be
-- reasoned out, only asked.
--
-- It has to run as a deferred script -- ImGui refuses to draw outside the
-- defer cycle -- so it cannot be driven by reascript_test.py, which reports
-- success as soon as the FILE finishes loading, before a single frame has been
-- drawn. tools/run_panel_test.py launches it and waits for the result file.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

local sep = package.config:sub(1, 1)
local RESULT = (os.getenv("TMPDIR") or "/tmp") .. sep
             .. "trackmanager-panel-result.txt"

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
  if fh then
    fh:write(text)
    fh:write(fail == 0 and "RESULT OK\n" or "RESULT FAIL\n")
    fh:close()
  end
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

local ImGui  = require "imgui" "0.9"
local Config = require "tm.config"
local Apply  = require "tm.apply"
local UI     = require "tm.ui"

-- Nothing this suite does may reach the user's settings or their project.
Config.save = function() end
Config.preset_save = function() return {} end
Config.preset_delete = function() return {} end
Apply.set_selected = function() end
Apply.set_visible = function() end
Apply.all_selected = function() end
Apply.all_visible = function() end

--------------------------------------------------- every symbol the panel names
-- Scanned out of the source rather than listed here, so a symbol added to the
-- panel later is covered without anyone remembering to add it.

do
  local fh = io.open(script_dir .. "tm/ui.lua", "r")
  if not fh then
    ok(false, "could not read tm/ui.lua for the symbol scan")
  else
    local text = fh:read("a")
    fh:close()
    -- Comments first, or the file-top note explaining why `ImGui.A or ImGui.B`
    -- does not work asks the real library for symbols called A and B.
    text = text:gsub("%-%-[^\n]*", "")
    local names = {}
    for n in text:gmatch("ImGui%.([%w_]+)") do names[n] = true end
    -- The closing paren is part of the pattern: opt("Key_Keypad" .. i) builds
    -- its name and would otherwise be scanned as a symbol called Key_Keypad.
    for n in text:gmatch('opt%("([%w_]+)"%)') do names[n] = true end
    for i = 0, 9 do names["Key_Keypad" .. i] = true end
    local list = {}
    for n in pairs(names) do list[#list + 1] = n end
    table.sort(list)
    local missing = {}
    for _, n in ipairs(list) do
      -- The shim RAISES on an unknown field rather than returning nil, which
      -- is the whole reason opt() exists; the same pcall is the probe here.
      local got, v = pcall(function() return ImGui[n] end)
      if not got or v == nil then missing[#missing + 1] = n end
    end
    ok(#missing == 0,
       string.format("all %d ImGui symbols the panel names exist at 0.9", #list),
       "missing: " .. table.concat(missing, ", "))
  end
end

local ST, cfg = UI._init(ImGui, script_dir)
local ctx = ImGui.CreateContext("Track Manager panel test")

local function filled()
  for _, m in ipairs(Config.MODES) do
    cfg.slots[m][1] = "drums*"
    cfg.slots[m][2] = "gtr*, -gtr ref"
    cfg.slots[m][3] = "vox"
    cfg.slots[m][9] = "*bus"
  end
end

local states = {
  { "empty", function()
      for _, m in ipairs(Config.MODES) do
        for i = 1, Config.NSLOTS do cfg.slots[m][i] = "" end
        cfg.preset[m] = ""
      end
      cfg.mode, cfg.scope = "select", "both"
      ST.confirm_del = false
    end },
  { "slots filled", filled },
  { "hide mode", function() filled() cfg.mode = "hide" end },
  { "hide, tcp only", function() filled() cfg.scope = "tcp" end },
  { "hide, mcp only", function() cfg.scope = "mcp" end },
  { "folders off", function() cfg.mode = "hide" cfg.include_folders = false end },
  { "one folder level", function()
      cfg.mode, cfg.folder_levels = "hide", 1
      ST.max_level = 4
    end },
  { "solo/mute", function()
      filled()
      cfg.mode, cfg.include_folders = "solo", true
    end },
  { "a preset loaded", function()
      cfg.mode, cfg.scope, cfg.include_folders = "select", "both", true
      cfg.preset[cfg.mode], ST.pname = "Mix", "Mix"
      ST.presets = { { name = "Mix", slots = cfg.slots[cfg.mode] } }
    end },
  { "delete confirm", function() ST.confirm_del = true end },
}

local idx, frames_per, drawn, done = 1, 3, 0, false

local function loop()
  if done then return end

  if drawn == 0 then
    local okp, perr = pcall(states[idx][2])
    if not okp then ok(false, "prepare: " .. states[idx][1], tostring(perr)) end
  end

  -- Cond_Always, or ImGui's persisted collapsed state can leave the window
  -- shut and every frame trivially "passing" without drawing anything.
  ImGui.SetNextWindowSize(ctx, 260, 500, ImGui.Cond_Always)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, "Track Manager panel test", true)
  local ran, err = true, nil
  if visible then
    ran, err = UI._frame()          -- unwinds its own stacks, never throws
    ImGui.End(ctx)
  end

  if drawn == frames_per - 1 then
    local dis, style = UI._depth()
    ok(visible, "the window actually drew: " .. states[idx][1])
    ok(ran, "renders against the real ReaImGui: " .. states[idx][1], tostring(err))
    ok(dis == 0 and style == 0,
       "both stacks balance: " .. states[idx][1],
       string.format("disabled %d, style %d", dis, style))
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
