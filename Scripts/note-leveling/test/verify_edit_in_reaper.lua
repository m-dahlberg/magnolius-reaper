-- Note Leveling -- whole-pipeline check. Run from the Actions list.
--
-- This is the only test that crosses the seam between the pure stages and the
-- project: accessor -> kernel -> clusters -> gains -> envelope -> read back.
-- In both sibling repos that seam is exactly where the real bugs lived, and it
-- is the one place unit tests on either side prove nothing about.
--
-- It builds its own fixture rather than using whatever is selected: a three
-- note take at three known levels, inserted twice -- once at playrate 1 and
-- once at playrate 1.5. The stretched copy is the point, and it is a sharper
-- test than it looks: the take accessor hands back audio with the playrate
-- ALREADY applied, so at 1.5 the notes arrive two thirds as long and a perfect
-- fifth higher, and their times map straight to project time with no playrate
-- factor. An implementation that "corrects" for the playrate passes at 1.0 and
-- fails here by exactly that factor.
--
-- Preserve pitch is off on the stretched copy on purpose: with it on, REAPER's
-- stretcher smears the abrupt note edges of a synthetic fixture by tens of
-- milliseconds and the boundary assertions stop meaning anything.
--
-- Cleans up after itself: the tracks are deleted and the fixture file removed.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Requires ReaImGui.", "Note Leveling verify", 0)
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Wav     = require "wav"
local Config  = require "nl.config"
local Kernel  = require "nl.kernel"
local Analyze = require "nl.analyze"
local Cluster = require "nl.cluster"
local Level   = require "nl.level"
local Apply   = require "nl.apply"

local ctx = ImGui.CreateContext("Note Leveling verify")

local out, pass, fail = {}, 0, 0
local cleanup = {}
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %.6g (tol %.3g)", tostring(a), b, tol))
end
local function report()
  for i = #cleanup, 1, -1 do pcall(cleanup[i]) end
  say(string.format("verify: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
-- Anything that stops the check short counts as a failed run. A green exit has
-- to mean the envelope was actually verified, not that the script declined to
-- look.
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

--------------------------------------------------------------------- fixture

local SR = 48000
local FIXTURE = script_dir .. "test/nl_fixture.wav"

-- start, stop, Hz, peak. Peaks chosen so the RMS of each note is a round
-- number: a sine's RMS is 3.01 dB under its peak.
--   -6 dBFS peak -> -9.03 dB RMS      loud, over a -12 dB ceiling
--  -24 dBFS peak -> -27.03 dB RMS     quiet, under a -20 dB floor
--  -12 dBFS peak -> -15.03 dB RMS     inside the window, must not move
local NOTES = {
  { 0.00, 0.60, 220.000, 10 ^ (-6 / 20)  },  -- A3
  { 0.90, 1.50, 261.626, 10 ^ (-24 / 20) },  -- C4
  { 1.80, 2.40, 329.628, 10 ^ (-12 / 20) },  -- E4
}
local FIX_LEN = 3.0

local function write_fixture()
  local w, err = Wav.create(FIXTURE, 1, SR)
  if not w then return nil, tostring(err) end
  local n = math.floor(FIX_LEN * SR)
  local buf = {}
  for i = 0, n - 1 do
    local t, v = i / SR, 0
    for _, nt in ipairs(NOTES) do
      if t >= nt[1] and t < nt[2] then
        v = nt[4] * math.sin(2 * math.pi * nt[3] * (t - nt[1]))
      end
    end
    buf[i + 1] = v
  end
  w:write(buf, 1, n)
  w:close()
  return true
end

local function add_item(playrate, pos)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  local psrc = reaper.PCM_Source_CreateFromFile(FIXTURE)
  if not psrc then return nil end
  reaper.SetMediaItemTake_Source(take, psrc)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", FIX_LEN / playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
  reaper.UpdateItemInProject(item)
  return { track = tr, item = item, take = take, pos = pos, playrate = playrate }
end

--------------------------------------------------------------- envelope read

-- The envelope's dB at a project time, from the points themselves. Stored
-- values interpolate linearly in the envelope's own domain -- that is what
-- REAPER does between two linear-shaped points -- and only then unscale.
local function env_db_at(env, mode, t)
  local n = reaper.CountEnvelopePointsEx(env, -1)
  if n == 0 then return nil end
  local i = reaper.GetEnvelopePointByTimeEx(env, -1, t)
  if i < 0 then i = 0 end
  local _, t0, v0 = reaper.GetEnvelopePointEx(env, -1, i)
  local v = v0
  if i + 1 < n then
    local _, t1, v1 = reaper.GetEnvelopePointEx(env, -1, i + 1)
    if t > t0 and t1 > t0 then
      v = v0 + (v1 - v0) * (t - t0) / (t1 - t0)
    end
  end
  return 20 * math.log(math.max(reaper.ScaleFromEnvelopeMode(mode, v), 1e-12), 10)
end

-------------------------------------------------------------------- the run

local wrote, werr = write_fixture()
if not wrote then bail("could not write the fixture: " .. tostring(werr)) end
cleanup[#cleanup + 1] = function()
  os.remove(FIXTURE)
  -- REAPER builds a peaks file beside the fixture the moment it is imported.
  os.remove(FIXTURE .. ".reapeaks")
  os.remove(test_dir .. "peaks/nl_fixture.wav.reapeaks")
  os.remove(test_dir .. "peaks")
end

local cfg = Config.new()
cfg.floor_db, cfg.ceiling_db, cfg.amount = -20, -12, 100
cfg.ramp_in_ms, cfg.ramp_out_ms, cfg.ramp_res_ms = 30, 60, 10
-- Limits wide open for the first pass, so it tests the leveling maths alone.
-- The second pass below tightens them on purpose.
cfg.max_boost_db, cfg.max_cut_db = 24, 24
cfg.write_markers = false

local fixtures = {}
reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()
for _, spec in ipairs({ { 1.0, 5.0 }, { 1.5, 20.0 } }) do
  local f = add_item(spec[1], spec[2])
  if not f then
    reaper.Undo_EndBlock("Note Leveling verify fixture", -1)
    reaper.PreventUIRefresh(-1)
    bail("could not create the fixture item")
  end
  fixtures[#fixtures + 1] = f
end
reaper.Undo_EndBlock("Note Leveling verify fixture", -1)
reaper.PreventUIRefresh(-1)
cleanup[#cleanup + 1] = function()
  for _, f in ipairs(fixtures) do reaper.DeleteTrack(f.track) end
  reaper.UpdateArrange()
end

-- Analyse both, exactly the way the panel does.
local results = {}
for _, f in ipairs(fixtures) do
  local geo = Analyze.geometry(f.take)
  local k, kerr = Kernel.new(ImGui, ctx, script_dir, geo.nchan, cfg, geo.rate)
  if not k then bail("kernel would not build: " .. tostring(kerr)) end

  local F, ferr = Analyze.drive(function()
    return Analyze.run(f.take, cfg, k, geo)
  end)
  if not F then bail("analysis failed at playrate " .. f.playrate ..
                     ": " .. tostring(ferr)) end

  -- The accessor-in-a-coroutine bug reads as a completely silent file, and
  -- everything downstream of it stays quietly plausible. Catch it here.
  local loud = 0
  for i = 1, F.n do if F.level_db[i] > -60 then loud = loud + 1 end end
  ok(loud > F.n / 4, "the accessor actually delivered audio at playrate "
     .. f.playrate, loud .. " of " .. F.n .. " frames above -60 dB")

  local notes = Level.gains(Cluster.run(F, cfg), cfg)
  results[#results + 1] = {
    item = f.item, take = f.take, geo = geo, notes = notes,
    points = Level.envelope(notes, cfg, F.span), fix = f, F = F,
  }
end

------------------------------------------------------------------ detection

for _, r in ipairs(results) do
  local p = r.fix.playrate
  local tag = " at playrate " .. p
  ok(#r.notes == 3, "three notes are found" .. tag, "got " .. #r.notes)
  if #r.notes == 3 then
    for i, nt in ipairs(NOTES) do
      local n = r.notes[i]
      -- The accessor already applied the playrate, so at 1.5 the pitch is a
      -- fifth up and the note is two thirds as long.
      local want_midi = Cluster.label(nt[3] * p, 100)
      ok(n.midi == want_midi, string.format("note %d is %s%s", i,
         Cluster.note_name(want_midi), tag),
         "got " .. Cluster.note_name(n.midi))
      near(n.t0, nt[1] / p, 0.02, string.format("note %d starts on time%s", i, tag))
      near(n.t1, nt[2] / p, 0.02, string.format("note %d ends on time%s", i, tag))
      -- 0.15 dB covers the 20 Hz DC blocker, which trims a 220 Hz sine by
      -- about 0.04 dB.
      near(n.rms_db, 20 * math.log(nt[4], 10) - 3.0103, 0.15,
           string.format("note %d measures its RMS%s", i, tag))
    end
    near(r.notes[1].gain_db, -12 - r.notes[1].rms_db, 1e-9,
         "the loud note is pushed down to the ceiling" .. tag)
    near(r.notes[2].gain_db, -20 - r.notes[2].rms_db, 1e-9,
         "the quiet note is lifted to the floor" .. tag)
    near(r.notes[3].gain_db, 0, 1e-9,
         "the note inside the window is untouched" .. tag)
  end

  local mono = true
  for i = 2, #r.points do
    if r.points[i].t <= r.points[i - 1].t then mono = false end
  end
  ok(mono, "envelope point times strictly increase" .. tag)
end

---------------------------------------------------------------------- apply

for _, f in ipairs(fixtures) do
  local e = reaper.GetTrackEnvelopeByChunkName(f.track, "<VOLENV")
  -- The envelope object always exists; what a fresh track has is no points.
  ok(e ~= nil and reaper.CountEnvelopePointsEx(e, -1) == 0,
     "the track starts with an empty Pre-FX volume envelope")
end

-- Second return is the take marker count on success, the error on failure.
local npoints, second = Apply.run(results, cfg)
if not npoints then bail("apply failed: " .. tostring(second)) end
ok(npoints > 0, "points were written", tostring(npoints))
ok(second == 0, "and no take markers, because the option is off",
   tostring(second))
for _, f in ipairs(fixtures) do
  ok(reaper.GetNumTakeMarkers(f.take) == 0, "the take has no markers yet",
     tostring(reaper.GetNumTakeMarkers(f.take)))
end

for ri, r in ipairs(results) do
  local f = r.fix
  local tag = " at playrate " .. f.playrate
  local env = reaper.GetTrackEnvelopeByChunkName(f.track, "<VOLENV")
  ok(env ~= nil, "a Volume (Pre-FX) envelope now exists" .. tag)
  if env then
    local mode = reaper.GetEnvelopeScalingMode(env)
    local n = reaper.CountEnvelopePointsEx(env, -1)
    ok(n == #r.points, "every point reached the envelope" .. tag,
       n .. " vs " .. #r.points)

    -- Take seconds map straight onto project seconds. No playrate factor:
    -- the accessor already applied it, so the times the analysis produced are
    -- already in the item's own timebase.
    local p = f.playrate
    local function proj(t) return f.pos + t end

    for i, nt in ipairs(NOTES) do
      local mid = proj((nt[1] + nt[2]) / 2 / p)
      near(env_db_at(env, mode, mid), r.notes[i].gain_db, 0.02,
           string.format("note %d reads back at its gain%s", i, tag))
    end

    -- The gaps are 300 ms and the ramps total 90 ms, so the middle of each
    -- gap must be back at unity.
    for i = 1, #NOTES - 1 do
      local mid = proj((NOTES[i][2] + NOTES[i + 1][1]) / 2 / p)
      near(env_db_at(env, mode, mid), 0, 0.02,
           string.format("gap %d rests at unity gain%s", i, tag))
    end

    -- Exactly ramp_out after a note the envelope must have arrived at unity,
    -- and halfway there it must be half the gain. Ramp lengths are real time,
    -- so 60 ms is 60 ms of project time on the stretched copy too.
    -- Anchored on the note the analysis actually found, not on the nominal
    -- fixture boundary: the two differ by a few frames, and a 60 ms ramp
    -- measured from the wrong end reads as the wrong shape.
    local g = r.notes[1].gain_db
    local nend = proj(r.notes[1].t1)
    near(env_db_at(env, mode, nend + 0.060), 0, 0.02,
         "the ramp out reaches unity after exactly ramp_out" .. tag)
    near(env_db_at(env, mode, nend + 0.030), g / 2, 0.05,
         "and is linear in dB on the way" .. tag)

    near(env_db_at(env, mode, f.pos - 0.1), 0, 0.02,
         "the envelope is at unity before the item" .. tag)
    near(env_db_at(env, mode, f.pos + FIX_LEN / p + 0.1), 0, 0.02,
         "and after it" .. tag)

    local _, ec = reaper.GetEnvelopeStateChunk(env, "", false)
    ok(ec:match("\nACT 1") ~= nil,
       "the envelope is active, so the automation actually applies" .. tag,
       tostring(ec:match("ACT [^\n]*")))
    ok(ec:match("\nVIS 1") ~= nil, "and visible" .. tag,
       tostring(ec:match("VIS [^\n]*")))

    local _, ext = reaper.GetSetMediaItemInfo_String(f.item, "P_EXT:notelevel",
                                                     "", false)
    ok(ext:find("3 notes", 1, true) ~= nil,
       "the item records what the pass did" .. tag, ext)
  end
end

----------------------------------------------- second pass: limits and markers
--
-- Re-levels the SAME frame tables with a boost limit tight enough to bite, and
-- with take markers on. Nothing is re-read: this is the path the panel takes
-- when a slider moves.

cfg.max_boost_db = 3
cfg.write_markers = true

local results2 = {}
for _, r in ipairs(results) do
  local notes = Level.gains(Cluster.run(r.F, cfg), cfg)
  results2[#results2 + 1] = {
    item = r.item, take = r.take, geo = r.geo, notes = notes,
    points = Level.envelope(notes, cfg, r.F.span), fix = r.fix,
  }
end

local np2, nm2 = Apply.run(results2, cfg)
if not np2 then bail("second apply failed: " .. tostring(nm2)) end
ok(nm2 == 2 * 3 * #results2, "two take markers per note were written",
   tostring(nm2))

for _, r in ipairs(results2) do
  local f = r.fix
  local p = f.playrate
  local tag = " at playrate " .. p

  -- The quiet note wanted about +7 dB and may now have only 3.
  ok(r.notes[2].clamped, "the quiet note is held at the boost limit" .. tag)
  near(r.notes[2].gain_db, 3, 1e-9, "moving exactly the limit" .. tag)
  ok(not r.notes[1].clamped,
     "the loud note is inside the cut limit and not marked" .. tag)
  ok(not r.notes[3].clamped, "and an untouched note is never marked" .. tag)

  local env = reaper.GetTrackEnvelopeByChunkName(f.track, "<VOLENV")
  local mode = reaper.GetEnvelopeScalingMode(env)
  local mid = f.pos + (NOTES[2][1] + NOTES[2][2]) / 2 / p
  near(env_db_at(env, mode, mid), 3, 0.02,
       "and the envelope carries the limited gain, not the wanted one" .. tag)

  -- Take markers are stored in SOURCE position, so they land on the original
  -- fixture times whatever the playrate -- the clearest possible check that
  -- the startoffs + t * playrate conversion is right.
  ok(reaper.GetNumTakeMarkers(f.take) == 6, "six take markers on the take" .. tag,
     tostring(reaper.GetNumTakeMarkers(f.take)))
  for i, nt in ipairs(NOTES) do
    local src0, name0 = reaper.GetTakeMarker(f.take, (i - 1) * 2)
    local src1, name1 = reaper.GetTakeMarker(f.take, (i - 1) * 2 + 1)
    near(src0, nt[1], 0.04,
         string.format("marker %d starts at the source position%s", i, tag))
    near(src1, nt[2], 0.04,
         string.format("marker %d ends at the source position%s", i, tag))
    ok(name0 == r.notes[i].name,
       string.format("marker %d is named for the note%s", i, tag),
       name0 .. " vs " .. r.notes[i].name)
    ok(name1 == r.notes[i].name .. " end",
       string.format("and its end marker says so%s", i, tag), name1)
  end
end

----------------------------------------------------------------------- undo

-- Two applies, so two undos. Both the automation and the markers went in
-- inside those blocks and must come back out.
reaper.Undo_DoUndo2(0)
reaper.Undo_DoUndo2(0)
local left, marks = 0, 0
for _, f in ipairs(fixtures) do
  local env = reaper.GetTrackEnvelopeByChunkName(f.track, "<VOLENV")
  if env then left = left + reaper.CountEnvelopePointsEx(env, -1) end
  marks = marks + reaper.GetNumTakeMarkers(f.take)
end
ok(left == 0, "undo takes the automation back off", left .. " points left")
ok(marks == 0, "and the take markers with it", marks .. " markers left")

report()
