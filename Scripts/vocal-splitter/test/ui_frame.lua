-- Drive one panel frame against a stub ImGui.
--
-- The panel needs a ReaImGui context and a defer loop, so no suite can run it
-- for real. What it does not need is a real ImGui to *fail*: every way this
-- file has broken has been a Lua error inside frame() -- a config key renamed
-- out from under a slider, a diagnostic field that no longer exists, an
-- unbalanced Begin/End -- and all of those raise against a stub just as well.
--
-- The stub returns the shape each call site expects and records what was
-- pushed and popped, so imbalance is caught too. It cannot tell you the panel
-- *looks* right. It can tell you it does not throw, which is the difference
-- between a working panel and one red line where the panel used to be.

local M = {}

-- `clicks` is a set of button labels that should report as pressed this frame,
-- so a test can reach the code behind a button and not just the drawing of it.
local function make_stub(log, clicks)
  local stub = {}
  -- Values, not functions: ReaImGui pre-evaluates its enums in the shim.
  local consts = { Cond_FirstUseEver = 1, Col_Button = 21, Col_Text = 0 }
  for k, v in pairs(consts) do stub[k] = v end

  local returns = {
    Begin            = function() return true, true end,
    CollapsingHeader = function() return true end,
    Button           = function(_, label) return clicks[label] == true end,
    SmallButton      = function(_, label) return clicks[label] == true end,
    Checkbox         = function(_, _, v) return false, v end,
    SliderDouble     = function(_, _, v) return false, v end,
    SliderInt        = function(_, _, v) return false, v end,
    InputDouble      = function(_, _, v) return false, v end,
    Combo            = function(_, _, v) return false, v end,
    IsItemDeactivatedAfterEdit = function() return false end,
    GetContentRegionAvail = function() return 500, 400 end,
    GetCursorScreenPos    = function() return 0, 0 end,
    GetWindowDrawList     = function() return {} end,
    CreateContext         = function() return {} end,
    CreateFunctionFromEEL = function() return {} end,
    GetBuiltinPath        = function() return "." end,
  }

  return setmetatable(stub, {
    __index = function(t, key)
      local fn = returns[key]
      if fn then return fn end
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

-- Renders one frame and returns ok, err, log, ST.
function M.run(UI, dir, prepare, clicks)
  local log = { push = 0, pop = 0, dis = 0 }
  local stub = make_stub(log, clicks or {})
  local ST = UI._init(stub, dir)
  if prepare then prepare(ST) end
  local ok, err = pcall(UI._frame)
  return ok, err, log, ST
end

return M
