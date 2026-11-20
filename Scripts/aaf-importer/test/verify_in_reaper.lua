-- AAF Importer -- the whole path, through the real project. Runs inside REAPER.
--
--   fixture AAF -> model -> plan -> track name, fader, Volume/Pan envelopes
--               -> read back through REAPER's own evaluation and formatting
--
-- The headless suite stops at the plan; nothing there can tell whether a gain
-- lands on the envelope as the right dB, whether the pan lane runs the right
-- way, or whether a user's point outside the span survives. This can.
--
-- Everything happens on fixture tracks added at the END of whatever project
-- is open and deleted afterwards. The user's tracks and items are never
-- edited; the track selection and edit cursor are borrowed and put back.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;" .. package.path
for k in pairs(package.loaded) do if k:match("^ai%.") then package.loaded[k] = nil end end

local out, pass, fail = {}, 0, 0
local cleanup = {}
local tracks0, items0
local function say(s) out[#out + 1] = s end
local function report()
  for i = #cleanup, 1, -1 do pcall(cleanup[i]) end
  if tracks0 then
    if reaper.CountTracks(0) == tracks0 and reaper.CountMediaItems(0) == items0 then
      pass = pass + 1 say("  ok    the project is left with the tracks and items it had")
    else
      fail = fail + 1 say("  FAIL  the project was not left as it was found")
    end
  end
  say(string.format("verify: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(type(a) == "number" and math.abs(a - b) <= tol, name,
     string.format("%.10g vs %.10g (tol %.3g)", tonumber(a) or 0 / 0, b, tol))
end
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

local Model  = require "ai.model"
local Config = require "ai.config"
local Apply  = require "ai.apply"

local model, err = Model.load(test_dir .. "fixtures/automation_import.aaf")
if not model then bail("the fixture would not load: " .. tostring(err)) return end

------------------------------------------------------------------ isolation

tracks0, items0 = reaper.CountTracks(0), reaper.CountMediaItems(0)
local sel0 = {}
for i = 0, reaper.CountSelectedTracks(0) - 1 do sel0[#sel0 + 1] = reaper.GetSelectedTrack(0, i) end
local cursor0 = reaper.GetCursorPosition()
local fixtures = {}

cleanup[#cleanup + 1] = function()
  for i = #fixtures, 1, -1 do
    if reaper.ValidatePtr2(0, fixtures[i], "MediaTrack*") then reaper.DeleteTrack(fixtures[i]) end
  end
  reaper.SetOnlyTrackSelected(reaper.GetMasterTrack(0))
  reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "I_SELECTED", 0)
  for _, t in ipairs(sel0) do
    if reaper.ValidatePtr2(0, t, "MediaTrack*") then reaper.SetTrackSelected(t, true) end
  end
  reaper.SetEditCurPos(cursor0, false, false)
  reaper.UpdateArrange()
end

local function fixture_track()
  local n = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(n, true)
  local tr = reaper.GetTrack(0, n)
  fixtures[#fixtures + 1] = tr
  return tr
end

local function vol_env(tr) return reaper.GetTrackEnvelopeByChunkName(tr, "<VOLENV2") end
local function pan_env(tr) return reaper.GetTrackEnvelopeByChunkName(tr, "<PANENV2") end

-- The envelope's gain at time t, as REAPER plays it, in dB.
local function eval_db(env, t)
  local _, v = reaper.Envelope_Evaluate(env, t, 48000, 1)
  return Model.db(reaper.ScaleFromEnvelopeMode(reaper.GetEnvelopeScalingMode(env), v))
end
local function active(env)
  local _, s = reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
  return s == "1"
end

local body_ok, body_err = pcall(function()

  say("apply a real AAF track over a lane that already holds the user's points")
  do
    local tr = fixture_track()
    local env = vol_env(tr)
    local mode = reaper.GetEnvelopeScalingMode(env)
    -- One user point inside the span (must go) and one after it (must stay).
    reaper.InsertEnvelopePoint(env, 100, reaper.ScaleToEnvelopeMode(mode, 0.9), 0, 0, false, true)
    reaper.InsertEnvelopePoint(env, 250, reaper.ScaleToEnvelopeMode(mode, 0.25), 0, 0, false, true)
    reaper.Envelope_SortPoints(env)

    local cfg = Config.new()
    local src_tr = model.tracks[3]                  -- "Mono Audio 1", 5 points
    local p, w = Apply.apply(tr, src_tr, cfg, 0)
    ok(p ~= nil, "applies", tostring(w))
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    ok(name == "Mono Audio 1", "the track takes the AAF name", name)
    near(reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), 1.0, 1e-12,
         "the fader sits at 0 dB under an envelope")
    ok(reaper.CountEnvelopePoints(env) == #src_tr.volume.points + 1,
       "the lane holds the AAF's points plus the user's point outside the span",
       tostring(reaper.CountEnvelopePoints(env)))
    ok(active(env), "the Volume envelope is active")

    near(eval_db(env, 0), -10.6, 0.01, "-10.6 dB at 0 s, as in Pro Tools")
    near(eval_db(env, 100), -10.6, 0.01, "the user's point at 100 s, inside the span, is gone")
    near(eval_db(env, 134.6074), -10.6, 0.01, "-10.6 dB at 134.6 s")
    near(eval_db(env, 224.3425), -23.2, 0.01, "-23.2 dB at 224.3 s")
    local L = src_tr.volume.t1
    near(eval_db(env, L - 2 / 48000), -18.8, 0.05, "-18.8 dB just before the clip's end")
    -- Sampled just past the step: further on, the lane ramps toward the
    -- user's point at 250 s, as it should.
    near(eval_db(env, L + 1e-3), -15.3, 0.01, "-15.3 dB just after the end step")
    near(eval_db(env, 300), Model.db(0.25), 0.01, "the user's point at 250 s, outside the span, survives")
    local fmt = reaper.Envelope_FormatValue(env, reaper.ScaleToEnvelopeMode(reaper.GetEnvelopeScalingMode(env),
                                            src_tr.volume.points[1].v))
    ok(fmt == "-10.6dB", "REAPER itself reads the first point as -10.6dB", fmt)
    local undo = reaper.Undo_CanUndo2(0)
    ok(undo == "AAF import: apply Mono Audio 1", "one named undo point", tostring(undo))
  end

  say("placement")
  do
    local cfg = Config.new()
    reaper.SetEditCurPos(12.5, false, false)
    cfg.placement = "cursor"
    local off = Apply.offset(cfg, model)
    near(off, 12.5, 1e-9, "edit cursor placement")
    local tr = fixture_track()
    local p = Apply.apply(tr, model.tracks[1], cfg, off)
    ok(p and p.span and math.abs(p.span[1] - 12.5) < 1e-9
       and math.abs(p.span[2] - (12.5 + 12779473 / 48000)) < 1e-6,
       "the plan reports the span the points were written to",
       p and p.span and string.format("%.6f .. %.6f", p.span[1], p.span[2]) or "no span")
    local env = vol_env(tr)
    local _, t0 = reaper.GetEnvelopePoint(env, 0)
    near(t0, 12.5, 1e-9, "the AAF's first point lands at the cursor")
    near(eval_db(env, 12.5), -1.0, 0.01, "holding -1.0 dB")
    local n = reaper.CountEnvelopePoints(env)
    local _, tl = reaper.GetEnvelopePoint(env, n - 1)
    near(tl, 12.5 + 12779473 / 48000, 1e-6, "and the last point 266.239 s later")
    ok(n == 233, "all 233 points written", tostring(n))

    cfg.placement = "zero"
    near(Apply.offset(cfg, model), 0, 0, "project-start placement is 0")
    cfg.placement = "timecode"
    near(Apply.offset(cfg, model), 3590 - reaper.GetProjectTimeOffset(0, false), 1e-9,
         "timecode placement: 00:59:50:00 less the project start time")
  end

  say("a static lane goes to the fader; a pan lane runs the right way")
  do
    local cfg = Config.new()
    local tr = fixture_track()
    local static_tr = {
      name = "Static", volume = { static = 0.5, first = 0.5, t0 = 0, t1 = 1,
                                  points = { { t = 0, v = 0.5, shape = 0 }, { t = 1, v = 0.5, shape = 0 } } },
      pan = { first = -1, t0 = 0, t1 = 2, min = -1, max = 1,
              points = { { t = 0, v = -1, shape = 0 }, { t = 2, v = 1, shape = 0 } } },
    }
    Apply.apply(tr, static_tr, cfg, 0)
    near(reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), 0.5, 1e-12, "static volume sets the fader")
    ok(reaper.CountEnvelopePoints(vol_env(tr)) == 0, "and writes no volume envelope")
    near(reaper.GetMediaTrackInfo_Value(tr, "D_PAN"), 0, 1e-12, "a moving pan centres the pan knob")
    local env = pan_env(tr)
    ok(reaper.CountEnvelopePoints(env) == 2 and active(env), "the pan lane has both points and is active")
    local _, _, v0 = reaper.GetEnvelopePoint(env, 0)
    local _, _, v1 = reaper.GetEnvelopePoint(env, 1)
    local f0, f1 = reaper.Envelope_FormatValue(env, v0), reaper.Envelope_FormatValue(env, v1)
    ok(f0 == "100%L", "pan -1 reads 100%L on REAPER's lane", f0)
    ok(f1 == "100%R", "pan +1 reads 100%R", f1)

    cfg.imp_automation = false
    local tr2 = fixture_track()
    Apply.apply(tr2, static_tr, cfg, 0)
    near(reaper.GetMediaTrackInfo_Value(tr2, "D_PAN"), -1, 1e-12,
         "without Automation, pan takes the opening value (hard left = -1)")
    ok(reaper.CountEnvelopePoints(pan_env(tr2)) == 0, "and writes no pan envelope")
  end

  say("insert as new track")
  do
    local cfg = Config.new()
    local anchor = fixture_track()
    reaper.SetOnlyTrackSelected(anchor)
    local before = reaper.CountTracks(0)
    local new, p = Apply.insert_new(model.tracks[2], cfg, 0)
    if new then fixtures[#fixtures + 1] = new end
    ok(new ~= nil, "inserts", tostring(p))
    ok(reaper.CountTracks(0) == before + 1, "exactly one track more")
    ok(new and reaper.GetMediaTrackInfo_Value(new, "IP_TRACKNUMBER")
             == reaper.GetMediaTrackInfo_Value(anchor, "IP_TRACKNUMBER") + 1,
       "directly below the selected track")
    local _, name = reaper.GetSetMediaTrackInfo_String(new, "P_NAME", "", false)
    ok(name == "Volume automation", "named from the AAF", name)
    ok(reaper.IsTrackSelected(new) and not reaper.IsTrackSelected(anchor), "and selected alone")
    ok(reaper.CountEnvelopePoints(vol_env(new)) == 233, "with its automation")
  end
end)

if not body_ok then fail = fail + 1 say("  FAIL  the suite raised: " .. tostring(body_err)) end
report()
