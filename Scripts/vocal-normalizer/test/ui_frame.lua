-- Drive one panel frame against a stub ImGui.
--
-- The panel needs a real ReaImGui context and a defer loop, so no suite can
-- run it for real. What it does not need is a real ImGui to *fail*: every way
-- this file has broken is a Lua error inside frame() -- a config key renamed
-- out from under a slider, a state field that moved, an unbalanced
-- BeginDisabled, a helper used above its own definition -- and all of those
-- raise against a stub just as well.
--
-- The stub returns the shape each call site expects and counts what was pushed
-- and popped, so imbalance is caught too. It cannot tell you the panel *looks*
-- right. It can tell you it does not throw, which is the difference between a
-- working panel and one red line where the panel used to be.

local M = {}

-- `clicks` is a set of button labels that should report as pressed this frame,
-- so a test can reach the code behind a button and not just the drawing of it.
-- `changed` flips every control to "the user just moved this".
local function make_stub(log, clicks, changed)
  local stub = {}

  -- Enums this stub knows about, matching what the real library exposes at the
  -- version the panel pins. ChildFlags_Border is singular at 0.9 and was
  -- renamed ChildFlags_Borders at 0.10, so the singular is what belongs here.
  local consts = {
    Cond_FirstUseEver = 1, Col_Button = 21, Col_Text = 0,
    ChildFlags_None = 0, ChildFlags_Border = 1, ChildFlags_ResizeX = 4,
    WindowFlags_None = 0,
    TableFlags_Borders = 1, TableFlags_RowBg = 2,
    TableFlags_SizingStretchProp = 4,
  }
  for k, v in pairs(consts) do stub[k] = v end

  -- A key that looks like an enum but is not listed must RAISE, which is what
  -- the real shim does for any unknown field. Returning the catch-all function
  -- would make `ImGui.Maybe_Missing or ImGui.Fallback` pick up the function,
  -- and returning nil would make the `or` work here and throw in REAPER --
  -- both hide the bug this stub exists to catch.
  local function is_enum(key)
    return key:match("^%a+Flags_") or key:match("^Cond_") or key:match("^Col_")
        or key:match("^Dir_") or key:match("^MouseButton_")
  end

  local returns = {
    Begin            = function() return true, true end,
    CollapsingHeader = function() return true end,
    Button           = function(_, label) return clicks[label] == true end,
    SmallButton      = function(_, label) return clicks[label] == true end,
    Selectable       = function(_, label) return clicks[label] == true end,
    Checkbox         = function(_, _, v) return changed, v end,
    SliderDouble     = function(_, _, v) return changed, v end,
    SliderInt        = function(_, _, v) return changed, v end,
    InputDouble      = function(_, _, v) return false, v end,
    Combo            = function(_, _, v) return changed, v end,
    BeginTable       = function() return true end,
    BeginTabBar      = function() return true end,
    BeginTabItem     = function() return true end,
    IsItemDeactivatedAfterEdit = function() return changed end,
    IsItemHovered         = function() return false end,
    GetContentRegionAvail = function() return 800, 600 end,
    GetCursorScreenPos    = function() return 0, 0 end,
    GetMousePos           = function() return 100, 100 end,
    GetWindowDrawList     = function() return {} end,
    CreateContext         = function() return {} end,
    CreateFunctionFromEEL = function() return {} end,
    GetBuiltinPath        = function() return "." end,
    ValidatePtr           = function() return true end,
    -- SeparatorText is optional in the panel and reached through pcall, so it
    -- must be PRESENT here: the version where it is missing is covered by
    -- make_stub_without below.
    SeparatorText         = function() end,
  }

  return setmetatable(stub, {
    __index = function(_, key)
      local fn = returns[key]
      if fn then return fn end
      if is_enum(key) then
        local v = consts[key]
        if v == nil then
          error("ImGui." .. key .. " does not exist at this version", 2)
        end
        return v
      end
      return function(...)
        if key == "PushStyleColor" then log.push = log.push + 1 end
        if key == "PopStyleColor"  then log.pop  = log.pop  + 1 end
        if key == "BeginDisabled"  then log.dis  = log.dis  + 1 end
        if key == "EndDisabled"    then log.dis  = log.dis  - 1 end
        if key == "BeginChild"     then log.child = log.child + 1 end
        if key == "EndChild"       then log.child = log.child - 1 end
        if key == "EndTable"       then log.table_ = log.table_ - 1 end
        return nil
      end
    end,
  })
end

-- Renders one frame and returns ok, err, log, ST, cfg. `prepare` is handed the
-- panel's own ST and cfg, so a case can set up both the state and the settings
-- the frame will be drawn under.
--
-- `drop` is a set of symbol names the stub should pretend not to have, so the
-- optional-symbol paths (SeparatorText, ChildFlags_ResizeX) get walked too --
-- those are exactly the lines that only run on somebody else's ReaImGui build.
function M.run(UI, dir, prepare, clicks, changed, drop)
  local log = { push = 0, pop = 0, dis = 0, child = 0, table_ = 0 }
  local stub = make_stub(log, clicks or {}, changed or false)
  if drop then
    local inner = getmetatable(stub).__index
    setmetatable(stub, { __index = function(t, key)
      if drop[key] then error("ImGui." .. key .. " does not exist", 2) end
      return inner(t, key)
    end })
    for k in pairs(drop) do rawset(stub, k, nil) end
  end
  local ST, _, cfg = UI._init(stub, dir)
  if prepare then prepare(ST, cfg) end
  -- _frame catches and unwinds its own errors, but a fault in _frame itself
  -- would still escape, so it is pcalled too.
  local ran, ok, err = pcall(UI._frame)
  if not ran then return false, ok, log, ST, cfg end
  return ok, err, log, ST, cfg
end

return M
