-- Loudness Envelope -- the whole pipeline, through the real project. Runs
-- inside REAPER.
--
--   fixture WAV -> item -> accessor -> kernel -> frames -> curve
--               -> Vocal Rider Target envelope -> read back -> undo
--
-- The kernel selftest and the headless suite both pass with this file
-- broken: they meet at the frame table and nothing else crosses that seam.
-- This is the test that does.
--
-- Everything happens on two fixture tracks added at the END of whatever
-- project is open and deleted afterwards, inside their own undo block so the
-- undo assertion below takes back only the write. The user's tracks, items,
-- selection and time selection are never edited (the time selection is
-- borrowed and put back).
--
-- Three things in the fixture each catch a class of bug nothing else would:
--
--   * the item sits at 3.0 s, not 0, so take time and project time differ --
--     at position 0 they are the same number and every offset bug passes;
--   * it is played at 1.25 as well as 1.0. At playrate 1 reading item_len and
--     item_len * playrate are the same span, so that bug passes too;
--   * the destination lane is written twice, the second time over a lane that
--     already holds a user point outside the span, which must survive.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local cleanup = {}
local tracks0, items0
local function say(s) out[#out + 1] = s end
local function report()
  for i = #cleanup, 1, -1 do pcall(cleanup[i]) end
  -- The project as it was found, checked after the cleanup has run.
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
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %.5g (tol %.3g)", tostring(a), b, tol))
end
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") return end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Config  = require "le.config"
local Kernel  = require "le.kernel"
local Analyze = require "le.analyze"
local Curve   = require "le.curve"
local Source  = require "le.source"
local Apply   = require "le.apply"
local Wav     = require "wav"

local ctx = ImGui.CreateContext("Loudness Envelope verify")

------------------------------------------------------------------ fixture

-- 1 s room tone | 6 s phrase | 1.5 s breath | 6 s phrase 6 dB louder | 1 s.
-- A 1 kHz sine at 48 kHz: ten whole cycles per 10 ms frame, so every frame's
-- energy is exactly the amplitude's, and the syllable modulation is a
-- per-frame amplitude step -- the same +3 / -10 / +7 dB pattern the headless
-- suite uses.
local RATE = 48000
local FIXTURE = test_dir .. "le_fixture.wav"
local PHRASE_A = { t0 = 1.0, t1 = 7.0, db = -24 }
local PHRASE_B = { t0 = 8.5, t1 = 14.5, db = -18 }
local LEN = 15.5

local function frame_db(t)
  for _, p in ipairs({ PHRASE_A, PHRASE_B }) do
    if t >= p.t0 and t < p.t1 then
      local f = math.floor((t - p.t0) / 0.01 + 1e-9)
      local syl = f // 25
      local within = f % 25
      if within >= 17 then return p.db - 10 end
      return p.db + (((syl + 1) % 3 == 0) and 7 or 3)
    end
  end
  if t >= PHRASE_A.t1 and t < PHRASE_B.t0 then return -60 end
  return -75
end

local function write_fixture()
  local w, err = Wav.create(FIXTURE, 1, RATE)
  if not w then return nil, err end
  local n = math.floor(LEN * RATE)
  local buf, bi = {}, 0
  for i = 0, n - 1 do
    local t = i / RATE
    -- mean square of a sine is A^2/2, so A = sqrt(2 * 10^(dB/10))
    local A = math.sqrt(2 * 10 ^ (frame_db(t) / 10))
    bi = bi + 1
    buf[bi] = A * math.sin(2 * math.pi * 1000 * t)
    if bi == 48000 then w:write(buf, 1, bi) bi = 0 end
  end
  if bi > 0 then w:write(buf, 1, bi) end
  w:close()
  return true
end

local wrote, werr = write_fixture()
if not wrote then bail("could not write the fixture: " .. tostring(werr)) return end
cleanup[#cleanup + 1] = function()
  os.remove(FIXTURE)
  os.remove(test_dir .. "peaks/le_fixture.wav.reapeaks")
end

tracks0, items0 = reaper.CountTracks(0), reaper.CountMediaItems(0)
local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
cleanup[#cleanup + 1] = function()
  reaper.GetSet_LoopTimeRange(true, false, ts0, ts1, false)
end

-- The fixture tracks get an undo block of their own. An edit made outside a
-- block is folded into the next block that closes, so without this the undo
-- assertion below would take the fixture tracks with it.
reaper.Undo_BeginBlock()
reaper.InsertTrackAtIndex(tracks0, true)
reaper.InsertTrackAtIndex(tracks0 + 1, true)
local SRC = reaper.GetTrack(0, tracks0)
local DST = reaper.GetTrack(0, tracks0 + 1)
reaper.GetSetMediaTrackInfo_String(SRC, "P_NAME", "LE fixture source", true)
reaper.GetSetMediaTrackInfo_String(DST, "P_NAME", "LE fixture destination", true)
local FX = reaper.TrackFX_AddByName(DST, "Vocal Rider (Magnolius)", false, -1)
reaper.Undo_EndBlock("Loudness Envelope test fixture", -1)
cleanup[#cleanup + 1] = function()
  pcall(reaper.DeleteTrack, SRC)
  pcall(reaper.DeleteTrack, DST)
  reaper.UpdateArrange()
end

if FX < 0 then bail("the Vocal Rider (Magnolius) JSFX is not installed") return end

local kernels = {}
local function body()

-- Every fixture edit is committed in an undo block of its own, for the same
-- reason as the tracks: an item added or deleted outside a block is folded
-- into the NEXT block that closes -- the write -- and the undo assertion
-- would then take the item with it.
local function committed(name, fn)
  reaper.Undo_BeginBlock()
  local r1, r2 = fn()
  reaper.Undo_EndBlock("Loudness Envelope test: " .. name, -1)
  return r1, r2
end

local POS = 3.0
local function add_item(playrate)
  return committed("add item", function()
    local item = reaper.AddMediaItemToTrack(SRC)
    local take = reaper.AddTakeToMediaItem(item)
    local s = reaper.PCM_Source_CreateFromFile(FIXTURE)
    reaper.SetMediaItemTake_Source(take, s)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", POS)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", LEN / playrate)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playrate)
    -- New takes come up with preserve-pitch ON (the project default), which
    -- stretches through a pitch-preserving algorithm that smears the
    -- syllable steps and costs ~0.66 dB of mean energy on this fixture.
    -- Real, and the accessor reports it faithfully -- but a geometry test
    -- wants a stretch whose energy is known, so: a plain resample.
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
    return item, take
  end)
end
local function del_item(item)
  if reaper.ValidatePtr2(0, item, "MediaItem*") then
    committed("delete item", function() reaper.DeleteTrackMediaItem(SRC, item) end)
  else
    ok(false, "a fixture item vanished before it was deleted")
  end
end

-- The panel's analyse, without the panel: resolve, kernels on this thread,
-- reads serviced by Analyze.drive.
local function analyse(cfg)
  local s = Source.resolve(cfg, SRC)
  if s.err then return nil, s.err end
  local job_clips = {}
  for i, c in ipairs(s.clips) do
    local geo = Analyze.geometry(c)
    local sig = Config.kernel_sig(geo.nchan, geo.rate)
    kernels[sig] = kernels[sig] or Kernel.new(ImGui, ctx, script_dir, geo.nchan, geo.rate)
    if not kernels[sig] then return nil, "kernel would not build" end
    job_clips[i] = { clip = c, geo = geo, k = kernels[sig] }
  end
  local frames, err = Analyze.drive(function()
    local o = {}
    for i, c in ipairs(job_clips) do
      local r, e = Analyze.run(c.clip, c.k, c.geo)
      if not r then return nil, e end
      o[i] = r
    end
    return o
  end)
  if not frames then return nil, err end
  local F = Curve.merge(frames, s.t0, s.t1, Config.FRAME_S)
  local res, berr = Curve.build(F, cfg)
  return res, berr, s
end

local function curve_at(res, t) return Curve.eval_points(res.points, t) end

-- Phrase interiors in project time at a given playrate.
local function interior(p, playrate)
  local mid = (p.t0 + p.t1) / 2
  return POS + (mid - 1.5) / playrate, POS + (mid + 1.5) / playrate
end
local function mean_curve(res, a, b)
  local s, n = 0, 0
  for j, t in ipairs(res.t) do
    if t >= a and t <= b then s, n = s + res.curve[j], n + 1 end
  end
  return n > 0 and s / n or nil, n
end
local function ptp_curve(res, a, b)
  local lo, hi = math.huge, -math.huge
  for j, t in ipairs(res.t) do
    if t >= a and t <= b then
      lo, hi = math.min(lo, res.curve[j]), math.max(hi, res.curve[j])
    end
  end
  return hi - lo
end

-- What the pure path makes of the same signal, frame by frame. The pipeline
-- must agree with it: the accessor and the kernel add nothing but samples.
--
-- At playrate 1 the accessor's frames are the fixture's frames. Stretched,
-- project frame f covers source time [f, f + 1) * 10 ms * playrate, which
-- straddles source frames; its energy is the overlap-weighted mean of theirs.
local function pure_curve(playrate)
  local S = {}
  local ns = math.floor(LEN / 0.01 + 1e-9)
  for k = 0, ns - 1 do S[k] = 10 ^ (frame_db(k * 0.01 + 0.005) / 10) end
  local E = {}
  local n = math.floor(LEN / playrate / 0.01 + 1e-9)
  for f = 0, n - 1 do
    local a, b = f * 0.01 * playrate, (f + 1) * 0.01 * playrate
    local acc = 0
    for k = math.floor(a / 0.01), math.min(ns - 1, math.ceil(b / 0.01) - 1) do
      local lo, hi = math.max(a, k * 0.01), math.min(b, (k + 1) * 0.01)
      if hi > lo then acc = acc + S[k] * (hi - lo) end
    end
    E[f + 1] = acc / (b - a)
  end
  return Curve.build({ t0 = POS, hop = 0.01, n = n, E = E }, Config.new())
end

------------------------------------------------------------- measurement

local A_LEVEL                     -- the phrase-A curve level at playrate 1

for _, rate in ipairs({ 1.0, 1.25 }) do
  say(string.format("analysis at playrate %.2f", rate))
  local item = add_item(rate)
  local res, err, s = analyse(Config.new())
  ok(res ~= nil, "builds a curve", err)
  if res then
    near(s.t0, POS, 1e-9, "the span starts at the item, in project time")
    near(s.t1, POS + LEN / rate, 1e-6, "and ends at the item end: item_len, not item_len * playrate")
    local a0, a1 = interior(PHRASE_A, rate)
    local b0, b1 = interior(PHRASE_B, rate)
    local ma, na = mean_curve(res, a0, a1)
    local mb = mean_curve(res, b0, b1)
    ok(na > 10, "phrase A interior is on the grid", tostring(na))
    ok(ptp_curve(res, a0, a1) < 1.5, "the syllables do not reach the curve",
       string.format("%.2f dB", ptp_curve(res, a0, a1)))
    near(mb - ma, 6.0, 0.75, "the 6 dB phrase step does")
    if rate == 1.0 then
      A_LEVEL = ma
      local pure = pure_curve(rate)
      near(ma, mean_curve(pure, a0, a1), 0.1,
           "accessor + kernel agree with the pure path on the same signal")
      -- Absolute: vowels at -21/-17 and consonants at -34, median a vowel.
      ok(ma > -23 and ma < -20, "phrase A sits at its sung level, in the rider's units",
         string.format("%.2f dB", ma))
    else
      -- NOT "the same level as at playrate 1": stretched syllables are
      -- shorter, and the rider's 50 ms detector rises less on a shorter
      -- vowel, so the true answer moves (about half a dB here). What must
      -- hold is that the pipeline sees the stretched signal the pure path
      -- says it should -- the right samples, at the right project times.
      near(ma, mean_curve(pure_curve(rate), a0, a1), 0.15,
           "a stretched take: accessor + kernel agree with the pure path")
      ok(math.abs(ma - A_LEVEL) < 1.0, "and lands within a dB of the unstretched take",
         string.format("%.2f vs %.2f", ma, A_LEVEL))
    end
    -- The gap is between phrases in PROJECT time, which is where a playrate
    -- bug would put it in the wrong place.
    local g0, g1 = POS + PHRASE_A.t1 / rate, POS + PHRASE_B.t0 / rate
    local _, _, glo = (function()
      local lo = math.huge
      for j, t in ipairs(res.t) do if t >= g0 and t <= g1 then lo = math.min(lo, res.curve[j]) end end
      return nil, nil, lo
    end)()
    ok(glo >= ma - 0.75, "no dip in the gap", string.format("%.2f vs %.2f", glo, ma))
  end
  del_item(item)
end

say("take and item volume")
do
  local item, take = add_item(1.0)
  committed("volume", function()
    reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 0.5)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", -1)        -- polarity flip
  end)
  local res = analyse(Config.new())
  local a0, a1 = interior(PHRASE_A, 1.0)
  near(mean_curve(res, a0, a1), A_LEVEL - 6.0206, 0.05,
       "take volume 0.5 lowers the curve 6.02 dB; a flipped item volume does not")
  del_item(item)
end

say("time selection")
do
  local item = add_item(1.0)
  local cfg = Config.new()
  cfg.use_timesel = true
  reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
  local none, msg = analyse(cfg)
  ok(none == nil and msg and msg:find("time selection"), "no time selection is reported", msg)
  local sel0, sel1 = POS + PHRASE_B.t0 - 0.5, POS + PHRASE_B.t1 + 0.5
  reaper.GetSet_LoopTimeRange(true, false, sel0, sel1, false)
  local res, err, s = analyse(cfg)
  ok(res ~= nil, "builds inside the selection", err)
  if res then
    near(s.t0, sel0, 1e-9, "the span is the selection")
    near(s.t1, sel1, 1e-9, "both ends")
    local b0, b1 = interior(PHRASE_B, 1.0)
    near(mean_curve(res, b0, b1), A_LEVEL + 6, 0.75,
         "and reads phrase B where it is, not from the item start")
  end
  del_item(item)
end

------------------------------------------------------------------- write

say("write")
local item = add_item(1.0)
local res = analyse(Config.new())
local rider = Apply.find_rider(DST)
ok(rider and rider.fx == FX, "finds the rider on the destination")
ok(rider and rider.param_name:find("Target"), "and its Target level parameter")
local nf, nerr = Apply.find_rider(SRC)
ok(nf == nil and nerr ~= nil, "a track without a rider is refused, with a reason")

ok(reaper.GetFXEnvelope(DST, FX, 0, false) == nil, "no Target lane before writing")
local n, warn = Apply.write(DST, res.points, res.t0, res.t1)
ok(n == #res.points, "writes every point", tostring(warn))
local env = reaper.GetFXEnvelope(DST, FX, 0, false)
ok(env ~= nil, "the Target lane exists")
if env then
  ok(reaper.CountEnvelopePoints(env) == #res.points,
     "a fresh lane holds exactly the curve -- the point REAPER seeds at 0 is gone",
     string.format("%d vs %d", reaper.CountEnvelopePoints(env), #res.points))
  local _, active = reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
  ok(active == "1", "and is active")
  local a0, a1 = interior(PHRASE_A, 1.0)
  local worst = 0
  for t = res.t0, res.t1, 0.137 do
    local _, v = reaper.Envelope_Evaluate(env, t, 48000, 0)
    worst = math.max(worst, math.abs(v - curve_at(res, t)))
  end
  ok(worst < 1e-6, "REAPER evaluates the lane to the curve, in dB",
     string.format("worst %.3g dB", worst))
  local _, va = reaper.Envelope_Evaluate(env, (a0 + a1) / 2, 48000, 0)
  near(va, A_LEVEL, 0.5, "phrase A reads its level through the envelope")

  -- Undo takes back the write and only the write.
  reaper.Undo_DoUndo2(0)
  local env2 = reaper.GetFXEnvelope(DST, FX, 0, false)
  ok(env2 == nil or reaper.CountEnvelopePoints(env2) <= 1, "undo removes the curve",
     env2 and tostring(reaper.CountEnvelopePoints(env2)))
  ok(reaper.ValidatePtr2(0, DST, "MediaTrack*"), "and leaves the fixture tracks alone")

  -- An existing lane belongs to the user: only the written span is cleared.
  reaper.Undo_BeginBlock()
  local e3 = reaper.GetFXEnvelope(DST, FX, 0, true)
  for i = reaper.CountEnvelopePoints(e3) - 1, 0, -1 do       -- by index: see apply.lua
    reaper.DeleteEnvelopePointEx(e3, -1, i)
  end
  reaper.InsertEnvelopePoint(e3, 1.0, -33, 0, 0, false, true)        -- before the span
  reaper.InsertEnvelopePoint(e3, POS + 5, -5, 0, 0, false, true)     -- inside it
  reaper.InsertEnvelopePoint(e3, POS + LEN + 2, -31, 0, 0, false, true) -- after it
  reaper.Envelope_SortPoints(e3)
  reaper.Undo_EndBlock("Loudness Envelope test: user points", -1)
  Apply.write(DST, res.points, res.t0, res.t1)
  local e4 = reaper.GetFXEnvelope(DST, FX, 0, false)
  local found = {}
  for i = 0, reaper.CountEnvelopePoints(e4) - 1 do
    local _, t, v = reaper.GetEnvelopePoint(e4, i)
    if math.abs(t - 1.0) < 1e-9 and math.abs(v + 33) < 1e-9 then found.before = true end
    if math.abs(t - (POS + 5)) < 1e-9 and math.abs(v + 5) < 1e-9 then found.inside = true end
    if math.abs(t - (POS + LEN + 2)) < 1e-9 and math.abs(v + 31) < 1e-9 then found.after = true end
  end
  ok(found.before and found.after, "user points outside the span survive")
  ok(not found.inside, "a user point inside the span is replaced")
  ok(reaper.CountEnvelopePoints(e4) == #res.points + 2, "and nothing else is there",
     tostring(reaper.CountEnvelopePoints(e4)))
end
del_item(item)

end -- body

-- A crash in the body still has to run the cleanup, or the fixture tracks are
-- left in the user's project; it counts as a failure, not a quiet stop.
local okb, berr = pcall(body)
if not okb then ok(false, "the suite ran to the end", tostring(berr)) end
for _, k in pairs(kernels) do Kernel.detach(ImGui, ctx, k) end
report()
