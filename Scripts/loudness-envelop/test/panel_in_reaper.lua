-- Loudness Envelope -- the panel against the REAL ReaImGui, not the stub.
--
-- Must be driven by tools/run_panel_test.py, never by reascript_test.py: the
-- generic harness emits its completion sentinel as soon as the FILE finishes
-- loading, so a deferred panel that has rendered nothing at all reports
-- success. This writes a result file after real frames have been drawn, and
-- the runner polls for that instead. Nothing in the loop may throw: REAPER's
-- error dialog is modal.

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;"
            .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "")
            .. package.path

local RESULT = (os.getenv("TMPDIR") or "/tmp") .. "/loudness-envelope-panel-result.txt"
local function report(okflag, msg)
  local fh = io.open(RESULT, "w")
  if fh then fh:write((okflag and "RESULT OK" or "RESULT FAIL") .. "  " .. (msg or "") .. "\n") fh:close() end
end

if not reaper.ImGui_GetBuiltinPath then report(false, "no ReaImGui") return end
local ImGui  = require "imgui" "0.9"
local Config = require "le.config"
local UI     = require "le.ui"

local saved = Config.save
Config.save = function() end          -- never clobber the user's settings

local ST, ctx = UI._init(ImGui, root)

-- A populated state, so the plot and readout are drawn with real data.
local E = {}
local function e(db) return 10 ^ (db / 10) end
for _ = 1, 100 do E[#E + 1] = e(-70) end
for i = 1, 600 do E[#E + 1] = e(-22 + ((i % 25) < 17 and 3 or -10)) end
for _ = 1, 150 do E[#E + 1] = e(-60) end
for i = 1, 600 do E[#E + 1] = e(-16 + ((i % 25) < 17 and 3 or -10)) end
ST.F = { t0 = 12.5, hop = Config.FRAME_S, n = #E, E = E }
ST.src = { track = nil, name = "panel test", clips = {}, t0 = 12.5,
           t1 = 12.5 + #E * Config.FRAME_S }
ST.key, ST.csig, ST.status, ST.hover_t = "panel test", nil, "panel test", 15

local frames, errs = 0, {}
local function loop()
  -- Cond_Always: ImGui persists a collapsed window by title across sessions,
  -- and a once-collapsed panel would make Begin return false forever after.
  ImGui.SetNextWindowSize(ctx, 1100, 700, ImGui.Cond_Always)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, "Loudness Envelope panel test", true)
  if visible then
    local ok, err = UI._frame()
    if not ok then errs[#errs + 1] = tostring(err) end
    ImGui.End(ctx)
  else
    errs[#errs + 1] = "Begin returned not visible"
  end
  frames = frames + 1
  if frames == 4 then ST.show_controls = false end
  if frames == 6 then ST.show_controls = true end
  if frames < 10 and open then
    reaper.defer(loop)
  else
    Config.save = saved
    if #errs > 0 then report(false, errs[1])
    elseif not ST.res then report(false, "no curve was built: " .. tostring(ST.res_err))
    elseif UI._depth() ~= 0 then report(false, "stack left open: " .. UI._depth())
    else report(true, string.format("%d real frames drawn, %d curve points", frames, #ST.res.points)) end
  end
end

reaper.defer(loop)
