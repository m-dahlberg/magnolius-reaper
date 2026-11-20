-- AAF Importer -- the panel against the REAL ReaImGui, not the stub.
--
-- Must be driven by tools/run_panel_test.py, never by reascript_test.py: the
-- generic harness emits its completion sentinel as soon as the FILE finishes
-- loading, so a deferred panel that has rendered nothing at all reports
-- success. This writes a result file after real frames have been drawn, and
-- the runner polls for that instead. Nothing in the loop may throw: REAPER's
-- error dialog is modal. No button is clicked, so the project is not touched.

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;"
            .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "")
            .. package.path
for k in pairs(package.loaded) do if k:match("^ai%.") then package.loaded[k] = nil end end

local RESULT = (os.getenv("TMPDIR") or "/tmp") .. "/aaf-importer-panel-result.txt"
local function report(okflag, msg)
  local fh = io.open(RESULT, "w")
  if fh then fh:write((okflag and "RESULT OK" or "RESULT FAIL") .. "  " .. (msg or "") .. "\n") fh:close() end
end

if not reaper.ImGui_GetBuiltinPath then report(false, "no ReaImGui") return end
local ImGui  = require "imgui" "0.9"
local Config = require "ai.config"
local UI     = require "ai.ui"

local saved = Config.save
Config.save = function() end          -- never clobber the user's settings

local ST, ctx = UI._init(ImGui, root)
if not UI.load(dir .. "fixtures/automation_import.aaf") then
  Config.save = saved
  report(false, "the fixture would not load: " .. tostring(ST.err))
  return
end

local frames, errs = 0, {}
local function loop()
  -- Cond_Always: ImGui persists a collapsed window by title across sessions,
  -- and a once-collapsed panel would make Begin return false forever after.
  ImGui.SetNextWindowSize(ctx, 760, 720, ImGui.Cond_Always)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, "AAF Importer panel test", true)
  if visible then
    local ok, err = UI._frame()
    if not ok then errs[#errs + 1] = tostring(err) end
    ImGui.End(ctx)
  else
    errs[#errs + 1] = "Begin returned not visible"
  end
  frames = frames + 1
  -- Walk the picks: an automated track, a 5-point one, and none.
  if frames == 3 then ST.sel = 3 end
  if frames == 6 then ST.sel = nil end
  if frames < 10 and open then
    reaper.defer(loop)
  else
    Config.save = saved
    if #errs > 0 then report(false, errs[1])
    elseif UI._depth() ~= 0 then report(false, "stack left open: " .. UI._depth())
    elseif not (ST.model and #ST.model.tracks == 4) then report(false, "the fixture's tracks are not listed")
    else report(true, string.format("%d real frames drawn over %d tracks", frames, #ST.model.tracks)) end
  end
end

reaper.defer(loop)
