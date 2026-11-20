-- AAF Importer -- one panel frame at a time, against a stub ImGui.
--
-- Runs inside REAPER (the panel asks REAPER for the selected track every
-- frame), but never edits the project: Apply is replaced by spies before any
-- button is clicked, and Config.save by a no-op so the user's settings stay
-- as they were. "Open AAF..." is never clicked -- it opens a modal dialog.
--
-- Every state is drawn twice: quiet, and with every control reporting that it
-- was just moved, because the code behind a control only runs when it moves.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local root = test_dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. test_dir .. "?.lua;" .. package.path
for k in pairs(package.loaded) do
  if k:match("^ai%.") or k == "ui_frame" then package.loaded[k] = nil end
end

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end

local Frame  = require "ui_frame"
local Config = require "ai.config"
local Apply  = require "ai.apply"
local Model  = require "ai.model"
local UI     = require "ai.ui"

local saved_save = Config.save
Config.save = function() end

local calls = {}
local real_apply, real_insert = Apply.apply, Apply.insert_new
Apply.apply = function(track, tr, cfg, off)
  calls[#calls + 1] = { "apply", track, tr, off }
  return Apply.plan(tr, cfg), nil
end
Apply.insert_new = function(tr, cfg, off)
  calls[#calls + 1] = { "insert", tr, off }
  return {}, Apply.plan(tr, cfg), nil
end

local FIX = test_dir .. "fixtures/automation_import.aaf"
local fixture = assert(Model.load(FIX))

local body_ok, body_err = pcall(function()
  local function loaded(st) st.model, st.sel = fixture, 1 end
  local states = {
    { "no file", nil, {} },
    { "file loaded", loaded, {} },
    { "last track picked", function(st) loaded(st) st.sel = 4 end, {} },
    { "names-only file", function(st)
        st.model = assert(Model.load(test_dir .. "fixtures/names_only.aaf")) st.sel = 3
      end, {} },
    { "a track with pan, square steps", function(st)
        st.model = {
          path = FIX, comps = 2, warnings = {}, name = "synthetic",
          tracks = { { name = "P", mob = "m", track_no = 1, rate_num = 48000, rate_den = 1,
            length_s = 4, index = 1,
            volume = { first = 1, min = 0.5, max = 1, t0 = 0, t1 = 2,
                       points = { { t = 0, v = 1, shape = 1 }, { t = 2, v = 0.5, shape = 1 } } },
            pan = { static = -0.5, first = -0.5, min = -0.5, max = -0.5, t0 = 0, t1 = 1,
                    points = { { t = 0, v = -0.5, shape = 0 } } } } },
        }
        st.sel = 1
      end, {} },
    { "errors and warnings shown", function(st)
        loaded(st) st.err = "boom" st.warn = "careful"
      end, {} },
    { "timecode placement without timecode", function(st, c)
        loaded(st) st.model = setmetatable({ tc = false }, { __index = fixture })
        c.placement = "timecode"
      end, {} },
    { "every button clicked", loaded,
      { ["Apply to selected track"] = true, ["Insert as new track"] = true, Reload = true,
        ["1##row1"] = true } },
  }
  for _, moved in ipairs({ false, true }) do
    for _, s in ipairs(states) do
      local name = s[1] .. (moved and " (moved)" or "")
      local good, err, log = Frame.run(UI, root, s[2], s[3], moved)
      ok(good, "frame: " .. name, tostring(err))
      if good then
        ok(log.push == log.pop and log.dis == 0 and log.table_ == 0 and log.wrap == 0,
           "stacks balanced: " .. name,
           string.format("push %d pop %d dis %d table %d wrap %d",
                         log.push, log.pop, log.dis, log.table_, log.wrap))
      end
    end
  end

  -- The buttons reach Apply with the picked track and the placement offset.
  calls = {}
  local good, err = Frame.run(UI, root, function(st, c)
    st.model, st.sel = fixture, 3
    c.placement = "zero"
  end, { ["Insert as new track"] = true }, false)
  ok(good, "frame: insert clicked", tostring(err))
  ok(#calls == 1 and calls[1][1] == "insert" and calls[1][2] == fixture.tracks[3]
     and calls[1][3] == 0, "Insert passes the picked AAF track and offset 0")

  -- After an import the status says where the points went, and warns when
  -- none of them is on screen (Match timecode puts them an hour in).
  Apply.insert_new = function(tr, cfg, off)
    local p = Apply.plan(tr, cfg)
    p.span = { 1e7, 1e7 + 266.239 }
    return {}, p, nil
  end
  local good3, err3, _, st3 = Frame.run(UI, root, function(st, c)
    st.model, st.sel = fixture, 1
    c.placement = "zero"
  end, { ["Insert as new track"] = true }, false)
  ok(good3 and st3.span and st3.status:find("Points from", 1, true) ~= nil,
     "the status names the span the points went to", good3 and st3.status or tostring(err3))
  -- Which warning depends on the open project: past its end if it has
  -- items, otherwise off screen.
  ok(good3 and st3.warn and (st3.warn:find("on screen", 1, true)
                             or st3.warn:find("after the end of the project", 1, true))
     and st3.warn:find("holds -1.0 dB until", 1, true) ~= nil,
     "and warns when they are off screen, and when the lane first moves",
     good3 and tostring(st3.warn) or "")
  local good4, err4, log4 = Frame.run(UI, root, function(st)
    st.model, st.sel, st.span = fixture, 1, { 1, 2 }
  end, {}, true)
  ok(good4 and log4.push == log4.pop, "a frame with the Show in arrange button", tostring(err4))

  -- Selecting a row picks that track.
  local good2, err2, _, st2 = Frame.run(UI, root, loaded, { ["3##row3"] = true }, false)
  ok(good2 and st2.sel == 3, "clicking row 3 picks track 3", tostring(err2))
end)

Apply.apply, Apply.insert_new = real_apply, real_insert
Config.save = saved_save
if not body_ok then fail = fail + 1 say("  FAIL  the suite raised: " .. tostring(body_err)) end
say(string.format("panel frames: %d passed, %d failed", pass, fail))
reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
if os.exit then os.exit(fail == 0 and 0 or 1) end
