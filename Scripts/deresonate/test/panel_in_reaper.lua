-- The panel against the REAL ReaImGui, not the stub.
--
-- Must be driven by tools/run_panel_test.py, never by reascript_test.py: the
-- generic harness emits its completion sentinel as soon as the FILE finishes
-- loading, so a deferred panel that has rendered nothing at all reports
-- success. This writes a result file after real frames have been drawn, and
-- the runner polls for that instead.

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;"
            .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "")
            .. package.path

local RESULT = (os.getenv("TMPDIR") or "/tmp") .. "/deresonate-panel-result.txt"
local function report(okflag, msg)
  local fh = io.open(RESULT, "w")
  if fh then fh:write((okflag and "RESULT OK" or "RESULT FAIL") .. "  " .. (msg or "") .. "\n"); fh:close() end
end

if not reaper.ImGui_GetBuiltinPath then report(false, "no ReaImGui") return end
local ImGui = require "imgui" "0.9"
local UI    = require "dr.ui"
local UIF   = require "ui_frame"

local ctx = ImGui.CreateContext("DeResonate panel test")
local Config = require "dr.config"
local saved = Config.save
Config.save = function() end          -- never clobber the user's settings

-- drive the module's own frame against the real ImGui
UI._init(ImGui, root)
local ST, cfg = UI._init(ImGui, root)
UIF.stub_state(ST, cfg)

local frames, errs = 0, {}
local function loop()
  ImGui.SetNextWindowSize(ctx, 640, 900, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "DeResonate panel test", true)
  if visible then
    local ok, err = pcall(UI._frame)
    if not ok then errs[#errs + 1] = tostring(err) end
    ImGui.End(ctx)
  end
  frames = frames + 1
  if frames < 8 and open then
    reaper.defer(loop)
  else
    Config.save = saved
    if #errs > 0 then report(false, errs[1])
    elseif UI._disabled_depth() ~= 0 then report(false, "disabled stack left at " .. UI._disabled_depth())
    else report(true, frames .. " real frames drawn") end
  end
end

-- UI._init created its own context; render against that one via the module.
reaper.defer(loop)
