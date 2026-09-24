-- Drive one panel frame against a stub ImGui.
--
-- The panel needs a ReaImGui context and a defer loop, so no suite can run it
-- for real. What it does not need is a real ImGui to *fail*: every way this
-- file breaks is a Lua error inside frame() -- a config key renamed out from
-- under a slider, a state field that no longer exists, an unbalanced
-- BeginDisabled -- and all of those raise against a stub just as well.
--
-- The stub returns the shape each call site expects and counts what was pushed
-- and popped, so imbalance is caught too. It cannot tell you the panel *looks*
-- right. It can tell you it does not throw, which is the difference between a
-- working panel and one red line where the panel used to be.

local M = {}

-- `clicks` is a set of button labels that should report as pressed this frame,
-- so a test can reach the code behind a button and not just the drawing of it.
local function make_stub(log, clicks, changed)
  local stub = {}
  -- Enums this stub knows about, matching what the REAL library exposes at
  -- the version the panel pins. ChildFlags_Border is singular at 0.9 and was
  -- renamed ChildFlags_Borders at 0.10, so the singular is what belongs here.
  local consts = {
    Cond_FirstUseEver = 1, Col_Button = 21, Col_Text = 0,
    ChildFlags_None = 0, ChildFlags_Border = 1, ChildFlags_ResizeX = 4,
    WindowFlags_None = 0,
  }

  -- A key that looks like an enum but is not listed must RAISE, which is what
  -- the real shim does for any unknown field. Returning the catch-all function
  -- would make `ImGui.Maybe_Missing or ImGui.Fallback` pick up the function,
  -- and returning nil would make the `or` work here and throw in REAPER --
  -- both hide the bug this stub exists to catch.
  local function is_enum(key)
    return key:match("^%a+Flags_") or key:match("^Cond_") or key:match("^Col_")
        or key:match("^Dir_") or key:match("^MouseButton_")
  end
  for k, v in pairs(consts) do stub[k] = v end

  local returns = {
    Begin            = function() return true, true end,
    CollapsingHeader = function() return true end,
    Button           = function(_, label) return clicks[label] == true end,
    SmallButton      = function(_, label) return clicks[label] == true end,
    Checkbox         = function(_, _, v) return changed, v end,
    SliderDouble     = function(_, _, v) return changed, v end,
    SliderInt        = function(_, _, v) return false, v end,
    InputDouble      = function(_, _, v) return false, v end,
    InputInt         = function(_, _, v) return false, v end,
    -- Both tab items report open, so ONE frame walks the controls of both
    -- tabs. The panel takes the last one that answered true as the active tab,
    -- which is enough: the plots and the control column are selected from
    -- ST.tab outside the tab bar, so the suite drives the other tab by setting
    -- ST.tab in its prepare function.
    BeginTabBar      = function() return true end,
    BeginTabItem     = function() return true end,
    Combo            = function(_, _, v) return false, v end,
    -- `changed` flips every control to "the user just moved this", so a frame
    -- can execute the code BEHIND a slider and not only the drawing of it.
    -- That is where a panel's worst bugs live -- a stub whose sliders always
    -- report false never runs those branches at all.
    -- The track pickers. BeginCombo must open, or the dropdown body -- where the role is
    -- actually written -- is never executed, and a picker that assigned the wrong key would
    -- pass. Selectable follows `changed` for the same reason the sliders do.
    BeginCombo = function() return true end,
    Selectable = function() return changed end,
    InputText  = function(_, _, v) return changed, v end,
    IsItemDeactivatedAfterEdit = function() return changed end,
    GetContentRegionAvail = function() return 500, 400 end,
    GetCursorScreenPos    = function() return 0, 0 end,
    GetWindowDrawList     = function() return {} end,
    CreateContext         = function() return {} end,
    CreateFunctionFromEEL = function() return {} end,
    GetBuiltinPath        = function() return "." end,
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
        return nil
      end
    end,
  })
end

-- Renders one frame and returns ok, err, log, ST, cfg. `changed` makes every
-- control report that it was just moved. `prepare` is handed the panel's own
-- ST and cfg, so a case can set up both the state and the settings the frame
-- will be drawn under.
-- The panel persists on edit, and in the `changed` pass every control reports as edited -- so
-- a run would write fixture track GUIDs into the user's saved roles. Snapshot and restore.
local ROLE_SUFFIXES = { "_guid", "_name", "_override" }

local function role_keys(Config)
  local out = {}
  for k in pairs(Config.defaults or {}) do
    for _, suffix in ipairs(ROLE_SUFFIXES) do
      if k:sub(-#suffix) == suffix then out[#out + 1] = k end
    end
  end
  return out
end

function M.snapshot_roles(Config, section)
  local saved = {}
  for _, k in ipairs(role_keys(Config)) do
    saved[k] = reaper.GetExtState(section, k)
  end
  return saved
end

function M.restore_roles(saved, section)
  for k, v in pairs(saved or {}) do
    reaper.SetExtState(section, k, v, true)
  end
end

function M.run(UI, dir, prepare, clicks, changed)
  local log = { push = 0, pop = 0, dis = 0 }
  local stub = make_stub(log, clicks or {}, changed or false)
  local ST, _, cfg = UI._init(stub, dir)
  if prepare then prepare(ST, cfg) end
  -- _frame catches and unwinds its own errors, but a fault in _frame itself
  -- would still escape, so it is pcalled too.
  local ran, ok, err = pcall(UI._frame)
  if not ran then return false, ok, log, ST, cfg end
  return ok, err, log, ST, cfg
end

return M
