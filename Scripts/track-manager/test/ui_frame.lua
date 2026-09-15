-- Track Manager -- one panel frame against a stub ImGui.
--
-- The panel needs a real context and a defer loop to run for real, so no suite
-- can drive it properly. What it does not need is a real ImGui to *fail*:
-- every way a panel like this has broken is a Lua error inside frame() -- a
-- config key renamed out from under a control, a state field that moved, an
-- unbalanced stack -- and all of those raise against a stub just as well.
--
-- The one thing that makes it worth having is the `changed` flag. A stub whose
-- controls always return false never executes the code behind them, which is
-- exactly where the worst bug these panels have had lived. Every state is
-- rendered twice: once quiet, once with every control reporting "just moved".
--
-- Both the config writes and the project writes are stubbed for the duration.
-- This suite runs inside a live REAPER, so an unstubbed frame with `changed`
-- set would rewrite the user's real settings and reselect their real tracks.

local Config = require "tm.config"
local Apply  = require "tm.apply"

local M = {}

local function make_stub(log, clicks, changed)
  local stub = {}
  for k, v in pairs({
    Cond_FirstUseEver = 1, Col_Text = 0,
    Col_Button = 21, Col_ButtonHovered = 22, Col_ButtonActive = 23,
    WindowFlags_TopMost = 0, WindowFlags_NoDocking = 0,
    Mod_Ctrl = 4096, InputTextWithHint = function() end,
  }) do stub[k] = v end
  for i = 0, 9 do stub["Key_Keypad" .. i] = 600 + i end
  stub.Key_KeypadAdd, stub.Key_KeypadSubtract = 620, 621
  stub.Key_KeypadDivide = 622

  local returns = {
    Begin            = function() return true, true end,
    Button           = function(_, label) return clicks[label] == true end,
    SmallButton      = function(_, label) return clicks[label] == true end,
    RadioButton      = function(_, label) return clicks[label] == true end,
    Checkbox         = function(_, _, v) return changed, v end,
    Combo            = function(_, _, v) return changed, v end,
    InputText        = function(_, _, v) return changed, v end,
    InputInt         = function(_, _, v) return changed, v end,
    InputTextWithHint = function(_, _, _, v) return changed, v end,
    IsItemDeactivatedAfterEdit = function() return changed end,
    IsItemHovered         = function() return changed end,
    IsAnyItemActive       = function() return false end,
    IsKeyDown             = function() return false end,
    -- Keys are the one input the stub must NOT simulate: a pressed key runs a
    -- project write, and the suite has those stubbed to no-ops, so a `true`
    -- here would assert nothing and hide the arity of the real call instead.
    IsKeyPressed          = function() return false end,
    GetContentRegionAvail = function() return 244, 400 end,
    GetCursorScreenPos    = function() return 0, 0 end,
    GetWindowDrawList     = function() return {} end,
    CreateContext         = function() return {} end,
    GetBuiltinPath        = function() return "." end,
  }

  return setmetatable(stub, {
    __index = function(_, key)
      local fn = returns[key]
      if fn then return fn end
      return function(...)
        if key == "PushStyleColor" then log.push = log.push + 1 end
        if key == "PopStyleColor"  then log.push = log.push - (select(2, ...) or 1) end
        if key == "BeginDisabled"  then log.dis  = log.dis  + 1 end
        if key == "EndDisabled"    then log.dis  = log.dis  - 1 end
        return nil
      end
    end,
  })
end

-- A project of five tracks with a drum folder over two of them, so folder
-- expansion, exclusion and the three lit states all have something to bite on
-- without the suite touching the real project.
function M.stub_snapshot()
  local names = { "DRUMS", "Kick", "Snare", "GTR 1", "VOX" }
  local depths = { 1, 0, -1, 0, 0 }
  local snap = { n = #names }
  for i = 1, #names do
    snap[i] = { track = {}, name = names[i], depth = depths[i],
                selected = (i == 4), tcp = true, mcp = true,
                -- One muted and one soloed, so the Solo/Mute row has a lit
                -- square, a dark one and a half-lit one to draw.
                mute = (i == 2), solo = (i == 5) }
  end
  return snap
end

-- Renders one frame with every write stubbed out, and reports whether it
-- raised. Config.load and presets_load are stubbed too: this suite runs inside
-- a live REAPER, and a frame that read the user's real settings would pass or
-- fail depending on what they happen to have in slot 4.
function M.run(UI, dir, prepare, clicks, changed)
  local log = { push = 0, dis = 0 }
  local stub = make_stub(log, clicks or {}, changed and true or false)

  local saved = {}
  local function stub_out(tbl, key, fn)
    saved[#saved + 1] = { tbl, key, tbl[key] }
    tbl[key] = fn
  end

  stub_out(Config, "save", function() end)
  stub_out(Config, "load", function() return Config.new() end)
  stub_out(Config, "load_proj", function() return false end)
  stub_out(Config, "presets_load", function()
    return { { name = "Mix",  slots = { "drums*", "gtr*", "vox*" } },
             { name = "Edit", slots = { "*bus" } } }
  end)
  stub_out(Config, "preset_save", function() return {} end)
  stub_out(Config, "preset_delete", function() return {} end)
  stub_out(Apply, "snapshot", M.stub_snapshot)
  stub_out(Apply, "set_selected", function() end)
  stub_out(Apply, "set_visible", function() end)
  stub_out(Apply, "all_selected", function() end)
  stub_out(Apply, "all_visible", function() end)
  stub_out(Apply, "set_flag", function() end)

  local ok, err = pcall(function()
    local ST, cfg = UI._init(stub, dir)
    if prepare then prepare(ST, cfg) end
  end)
  local ST, cfg = nil, nil
  if ok then
    ST, cfg = UI._state(), UI._cfg()
    ok, err = UI._frame()
  end

  for i = #saved, 1, -1 do
    local s = saved[i]
    s[1][s[2]] = s[3]
  end

  return ok, err, log, ST, cfg
end

return M
