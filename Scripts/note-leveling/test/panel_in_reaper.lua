-- Note Leveling -- panel smoke test against the real ReaImGui.
--
-- test/ui_frame drives the panel against a stub, which catches Lua errors but
-- cannot catch calling a real ImGui function that does not exist, taking the
-- wrong arguments, or leaving a Begin/End pair unbalanced in a way only the
-- real library notices. This does.
--
-- It cannot run under reascript_test.py, and both reasons are worth knowing:
--
--   * The harness emits its completion sentinel as soon as the file finishes
--     loading. A reaper.defer loop therefore reports success before it has
--     rendered anything -- a green run that checked nothing.
--   * Rendering synchronously to get around that does not work either.
--     ImGui.Begin outside the defer cycle blocks REAPER's main thread on its
--     script-timeout dialog, and every later test times out until someone
--     clicks it.
--
-- So it defers like a real panel and writes its own result file, which
-- test/run_panel_test.sh polls for. The window opens for a moment and closes
-- itself.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")
local RESULT = test_dir .. "panel_result.txt"

local function finish(lines, code)
  local fh = io.open(RESULT, "w")
  if fh then
    fh:write(table.concat(lines, "\n") .. "\n__PANEL_DONE__ " .. code .. "\n")
    fh:close()
  end
end

if not reaper.ImGui_GetBuiltinPath then
  finish({ "  FAIL  ReaImGui is not installed" }, 1)
  return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui     = require "imgui" "0.9"
local UI        = require "nl.ui"
local Config    = require "nl.config"
local Cluster   = require "nl.cluster"
local Level     = require "nl.level"
local Reference = require "nl.reference"
local Rider     = require "nl.rider"
local Ride      = require "nl.ride"

local out, pass, fail = {}, 0, 0
local function ok(cond, name, extra)
  if cond then pass = pass + 1 out[#out + 1] = "  ok    " .. name
  else fail = fail + 1
       out[#out + 1] = "  FAIL  " .. name .. (extra and ("  -- " .. extra) or "") end
end

-- Enough state that every readout and all three plots have something to draw.
local function fixture()
  local F = { hop_s = 0.005, n = 0, item_pos = 0,
              ms = {}, level_db = {}, bp_ms = {}, bp_db = {},
              f0 = {}, aper = {} }
  local function seg(hz, n, dbv)
    for _ = 1, n do
      local i = F.n + 1
      F.n = i
      F.ms[i] = 10 ^ (dbv / 10)
      F.level_db[i] = dbv
      F.bp_ms[i] = F.ms[i]
      F.bp_db[i] = dbv
      F.f0[i] = hz or 0
      F.aper[i] = hz and 0.05 or 0.9
    end
  end
  seg(220, 120, -6) seg(nil, 60, -80) seg(261.626, 120, -40)
  seg(nil, 60, -80) seg(329.628, 120, -15)
  F.span = F.n * F.hop_s
  return F
end

local ST, ctx, cfg = UI._init(ImGui, script_dir)
local cfg = Config.new()

-- One analysis feeds both tabs, so the fixture is one `data` blob shaped like
-- the read job's output; the panel derives everything else from it.
local full = fixture()
local refs = { { n = full.n, hop_s = full.hop_s, item_pos = 0, bp_ms = {} } }
for i = 1, full.n do refs[1].bp_ms[i] = 10 ^ (-20 / 10) end
local data = {
  targets = { { F = full, R = Reference.mix(refs, full),
                geo = { item_pos = 0, item_len = full.span, nchan = 1,
                        rate = 48000, playrate = 1 } } },
  refs = refs,
}
local nd = Ride.notes_only(data, cfg)
local rd = Ride.derive(data, cfg)
ST.status = "panel smoke test"

ok(#nd[1].notes == 3, "the fixture produced notes to draw", tostring(#nd[1].notes))
ok(#nd[1].points > 0, "and an envelope to draw", tostring(#nd[1].points))
ok(#rd[1].segs > 0, "the fixture produced a ride to draw", tostring(#rd[1].segs))
ok(#rd[1].points > 0, "and a curve to draw", tostring(#rd[1].points))

-- Eight frames: both tabs, each with results in hand or not, and the controls
-- column shown or hidden. Every combination is a different set of
-- BeginChild/EndChild pairs, and the tab bar adds a Begin/End pair of its own
-- that only the real library checks -- a stub cannot tell whether EndTabItem
-- was called for a tab item that returned false, and ReaImGui raises on it.
local PHASES = {
  { tab = "notes", data = true,  controls = true,  label = "notes, controls shown" },
  { tab = "notes", data = true,  controls = false, label = "notes, controls hidden" },
  { tab = "notes", data = false, controls = true,  label = "notes empty, controls shown" },
  { tab = "notes", data = false, controls = false, label = "notes empty, controls hidden" },
  { tab = "rider", data = true,  controls = true,  label = "rider, controls shown" },
  { tab = "rider", data = true,  controls = false, label = "rider, controls hidden" },
  { tab = "rider", data = false, controls = true,  label = "rider empty, controls shown" },
  { tab = "rider", data = false, controls = false, label = "rider empty, controls hidden" },
  -- Glide mode hides two sliders inside a disabled scope and shows a different
  -- block of help. _init loads the settings from ExtState, so without pinning
  -- it here whichever arrangement the phases above drew is whatever the user
  -- last saved -- and the other one is never rendered at all.
  { tab = "notes", data = true,  controls = true,  glide = true,
    label = "notes, glide between notes" },
}

local phase, errors = 0, {}

-- Each phase gets two passes and is asserted on the second. ImGui honours a
-- tab selection request when it next lays the bar out, so the frame that asks
-- for a tab is not yet the frame that draws it.
local pass_in_phase = 0

local function body()
  pass_in_phase = pass_in_phase + 1
  if pass_in_phase == 1 then phase = phase + 1 end
  local ph = PHASES[phase]
  local assert_now = (pass_in_phase == 2)
  if assert_now then pass_in_phase = 0 end

  ST.show_controls = ph.controls
  cfg.glide_notes = ph.glide or false
  -- A REQUEST, not an assignment: the tab bar writes ST.tab every frame from
  -- ImGui's own state, so setting it here would be undone before the columns
  -- below were drawn -- and the rider phases would quietly render the Notes
  -- tab while reporting that they had covered the rider.
  ST.tab_request = ph.tab
  if ph.data then
    ST.data, ST.nd, ST.rd, ST.clip_idx = data, nd, rd, 1
    ST.F, ST.notes, ST.points = nd[1].F, nd[1].notes, nd[1].points
    ST.geo, ST.take = nd[1].geo, nd[1].take
  else
    ST.data, ST.nd, ST.rd = nil, nil, nil
    ST.F, ST.notes, ST.points, ST.take, ST.geo = nil, nil, nil, nil, nil
  end

  ImGui.SetNextWindowSize(ctx, 1280, 820, ImGui.Cond_FirstUseEver)
  -- Forced open every frame, and that is not belt-and-braces. ImGui persists a
  -- window's collapsed state by TITLE across sessions, so a panel someone --
  -- or some other test harness -- once collapsed makes Begin return false here
  -- forever after, and the suite reports seven layout failures that have
  -- nothing to do with the panel. The assertion below is meant to catch an
  -- unbalanced stack, not to re-read a saved window setting.
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, _ = ImGui.Begin(ctx, "Note Leveling", true)
  if visible then
    local good, err = UI._frame()
    if not good then errors[#errors + 1] = ph.label .. ": " .. tostring(err) end
    -- End must be called whenever Begin returned visible, error or not.
    ImGui.End(ctx)
  end
  if assert_now then
    ok(visible, "ImGui.Begin succeeded (" .. ph.label .. ")")
    -- Prove the tab actually changed. Without this the suite cannot tell a
    -- rendered rider tab from a Notes tab wearing its label.
    ok(ST.tab == ph.tab, "the " .. ph.tab .. " tab is the one that rendered ("
       .. ph.label .. ")", "got " .. tostring(ST.tab))
  end

  return phase < #PHASES or not assert_now
end

-- Nothing may escape into REAPER's error handler: its dialog is modal, so a
-- throw here would stop the main thread answering any script until a human
-- clicks it. On a fault we record it, stop deferring and report.
local function loop()
  local ran, again = pcall(body)
  if not ran then
    errors[#errors + 1] = "uncaught: " .. tostring(again)
    again = false
  end
  if again then
    reaper.defer(loop)
  else
    ok(#errors == 0, "the panel rendered every layout through real ReaImGui",
       errors[1])
    out[#out + 1] = string.format("panel: %d passed, %d failed", pass, fail)
    finish(out, fail == 0 and 0 or 1)
  end
end

os.remove(RESULT)
reaper.defer(loop)
