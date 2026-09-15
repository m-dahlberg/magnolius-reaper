-- Note Leveling -- whole-pipeline check for the rider. Run from the Actions list.
--
-- The rider's counterpart to verify_edit_in_reaper: the only test that crosses
-- every seam at once -- selection -> accessor -> band-passed kernel -> mixing
-- several reference clips onto the target's grid -> segments -> gains -> curve
-- -> the fader envelope -> read back.
--
-- It builds its own fixture, three tracks laid out the way the feature is
-- meant to be used: two reference clips and one target below them.
--
-- Three things in the fixture are there to catch a specific class of bug, and
-- none of them would fire on a "everything at position zero, playrate one"
-- layout:
--
--   * The reference clips sit HALF A SECOND EARLIER on the timeline than the
--     target. So target frame i and reference frame i are not the same instant
--     and the mixing has to shift one onto the other. At the same position
--     every shift bug -- dropped, negated, doubled -- passes.
--   * The reference clips therefore also RUN OUT half a second before the
--     target ends, which is the only way to check that an uncovered stretch is
--     reported as uncovered rather than as silence. Those two are opposite
--     mistakes: silence should pull a vocal down, no-reference must not.
--   * The target is inserted twice, once at playrate 1 and once at 1.5, for
--     the same reason the note leveling's verify does it. The accessor applies
--     the playrate itself, so take times map to project times with no factor
--     anywhere -- and an implementation that "corrects" for it passes at 1.0
--     and fails here by exactly 1.5.
--
-- Both reference clips are the same file, so the mixed reference must read
-- exactly 3.01 dB above one of them. Power summing is the only rule that gives
-- that number: adding dB gives +40, taking the louder gives +0.
--
-- Cleans up after itself -- tracks deleted, files removed, and the item
-- selection it had to change put back.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Requires ReaImGui.", "Note Leveling ride verify", 0)
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui     = require "imgui" "0.9"
local Wav       = require "wav"
local Config    = require "nl.config"
local Kernel    = require "nl.kernel"
local Analyze   = require "nl.analyze"
local Apply     = require "nl.apply"
local Ride      = require "nl.ride"
local Level     = require "nl.level"
local Rider     = require "nl.rider"
local Select    = require "nl.select"

local ctx = ImGui.CreateContext("Note Leveling ride verify")

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
  say(string.format("ride verify: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

--------------------------------------------------------------------- fixture

local SR = 48000
local REF_FILE = script_dir .. "test/nl_ride_ref.wav"
local TGT_FILE = script_dir .. "test/nl_ride_tgt.wav"
local LEN = 6.0

-- The reference: one steady tone at 1 kHz -- dead centre of the vocal band, so
-- the band-pass leaves it alone and the numbers stay exact -- that steps 6 dB
-- louder halfway through.
local REF_HZ    = 1000
local REF_STEP  = 3.0              -- source seconds
local REF_QUIET = 10 ^ (-26 / 20)  -- peak; RMS is 3.01 under it
local REF_LOUD  = 10 ^ (-20 / 20)

-- The target: four notes, ALL AT THE SAME PITCH. The vocal band tilts a 440 Hz
-- note by about a dB more than a 590 Hz one, and every assertion below is a
-- difference between two segments, so keeping the pitch constant makes that
-- tilt cancel exactly instead of having to be allowed for.
local TGT_HZ = 440
local NOTES = {
  { 0.0, 0.8, 10 ^ (-12 / 20) },   -- loud,  under the quiet reference
  { 1.5, 2.3, 10 ^ (-18 / 20) },   -- soft,  under the quiet reference
  { 3.0, 3.8, 10 ^ (-12 / 20) },   -- loud,  under the loud reference
  { 4.5, 5.3, 10 ^ (-18 / 20) },   -- soft,  under the loud reference
}

local function write_wav(path, gen)
  local w, err = Wav.create(path, 1, SR)
  if not w then return nil, tostring(err) end
  local n = math.floor(LEN * SR)
  local buf = {}
  for i = 0, n - 1 do buf[i + 1] = gen(i / SR) end
  w:write(buf, 1, n)
  w:close()
  return true
end

local function add_item(file, pos, playrate)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  local psrc = reaper.PCM_Source_CreateFromFile(file)
  if not psrc then return nil end
  reaper.SetMediaItemTake_Source(take, psrc)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", LEN / playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
  reaper.UpdateItemInProject(item)
  return { track = tr, item = item, take = take, pos = pos, playrate = playrate }
end

--------------------------------------------------------------- envelope read

-- The envelope's dB at a project time, from the points. Stored values
-- interpolate linearly in the envelope's OWN domain between two linear points;
-- unscale only after interpolating, or the answer is wrong by the scaling.
local function env_db_at(env, mode, t)
  local n = reaper.CountEnvelopePointsEx(env, -1)
  if n == 0 then return nil end
  local i = reaper.GetEnvelopePointByTimeEx(env, -1, t)
  if i < 0 then i = 0 end
  local _, t0, v0 = reaper.GetEnvelopePointEx(env, -1, i)
  local v = v0
  if i + 1 < n then
    local _, t1, v1 = reaper.GetEnvelopePointEx(env, -1, i + 1)
    if t > t0 and t1 > t0 then v = v0 + (v1 - v0) * (t - t0) / (t1 - t0) end
  end
  return 20 * math.log(math.max(reaper.ScaleFromEnvelopeMode(mode, v), 1e-12), 10)
end

-------------------------------------------------------------------- the run

if not write_wav(REF_FILE, function(t)
     local a = t < REF_STEP and REF_QUIET or REF_LOUD
     return a * math.sin(2 * math.pi * REF_HZ * t)
   end) then bail("could not write the reference fixture") end

if not write_wav(TGT_FILE, function(t)
     for _, nt in ipairs(NOTES) do
       if t >= nt[1] and t < nt[2] then
         return nt[3] * math.sin(2 * math.pi * TGT_HZ * (t - nt[1]))
       end
     end
     return 0
   end) then bail("could not write the target fixture") end

cleanup[#cleanup + 1] = function()
  for _, f in ipairs({ REF_FILE, TGT_FILE }) do
    os.remove(f)
    os.remove(f .. ".reapeaks")
  end
  os.remove(test_dir .. "peaks/nl_ride_ref.wav.reapeaks")
  os.remove(test_dir .. "peaks/nl_ride_tgt.wav.reapeaks")
  os.remove(test_dir .. "peaks")
end

-- Put the caller's item selection back: this suite has to change it, because
-- which clips are selected IS the rider's input.
local saved_sel = {}
for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
  saved_sel[#saved_sel + 1] = reaper.GetSelectedMediaItem(0, i)
end
cleanup[#cleanup + 1] = function()
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(saved_sel) do reaper.SetMediaItemSelected(it, true) end
  reaper.UpdateArrange()
end

local cfg = Config.new()
-- 440 Hz at playrate 1.5 is 660, past the 600 Hz default, so the search has to
-- reach further or the stretched case finds no notes at all.
cfg.max_hz = 900
cfg.floor_db, cfg.ceiling_db = -60, 0        -- part 1 must not move anything:
cfg.amount = 100                             -- this suite is about the ride.
cfg.rider_smooth_ms = 0                      -- measure the law, not the smoothing
cfg.rider_seg_max_ms = 0
cfg.rider_gate_db = -70
cfg.rider_max_boost_db, cfg.rider_max_cut_db = 40, 40
cfg.rider_trim_db, cfg.rider_offset_db = 0, 0
cfg.rider_lookahead_ms, cfg.rider_trans_ms = 40, 60
cfg.rider_speed_db_s = 60
cfg.rider_after_notes = true
cfg.rider_target_track = 0                   -- exercise the auto rule

-- Two cases, each its own set of three tracks. The references stay at playrate
-- 1 in both: nobody time-stretches the backing, and the geometry risk is all
-- on the target side.
local cases = {}
reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()
for _, spec in ipairs({ { 1.0, 10.0 }, { 1.5, 30.0 } }) do
  local playrate, pos = spec[1], spec[2]
  local c = { playrate = playrate, pos = pos, refs = {} }
  -- Half a second EARLIER than the target: see the header.
  c.refs[1] = add_item(REF_FILE, pos - 0.5, 1.0)
  c.refs[2] = add_item(REF_FILE, pos - 0.5, 1.0)
  c.tgt = add_item(TGT_FILE, pos, playrate)
  if not (c.refs[1] and c.refs[2] and c.tgt) then
    reaper.Undo_EndBlock("Note Leveling ride fixture", -1)
    reaper.PreventUIRefresh(-1)
    bail("could not create the fixture items")
  end
  cases[#cases + 1] = c
end
reaper.Undo_EndBlock("Note Leveling ride fixture", -1)
reaper.PreventUIRefresh(-1)
cleanup[#cleanup + 1] = function()
  for _, c in ipairs(cases) do
    for _, r in ipairs(c.refs) do reaper.DeleteTrack(r.track) end
    reaper.DeleteTrack(c.tgt.track)
  end
  reaper.UpdateArrange()
end

local kernels = {}
local function ensure_kernel(nchan, rate)
  local key = Config.kernel_sig(cfg, nchan) .. "|" .. rate
  if not kernels[key] then
    local k, err = Kernel.new(ImGui, ctx, script_dir, nchan, cfg, rate)
    if not k then return nil, err end
    kernels[key] = k
  end
  return kernels[key]
end

------------------------------------------------------------------- selection

for _, c in ipairs(cases) do
  local tag = " at playrate " .. c.playrate
  reaper.SelectAllMediaItems(0, false)
  for _, r in ipairs(c.refs) do reaper.SetMediaItemSelected(r.item, true) end
  reaper.SetMediaItemSelected(c.tgt.item, true)

  local sel = Select.resolve(cfg)
  ok(sel.err == nil, "the selection resolves" .. tag, tostring(sel.err))
  ok(#sel.refs == 2, "two clips are taken as reference" .. tag,
     tostring(#sel.refs))
  ok(#sel.target == 1, "one clip is taken as the target" .. tag,
     tostring(#sel.target))
  ok(sel.target[1] and sel.target[1].item == c.tgt.item,
     "and it is the one on the highest-numbered track" .. tag)
  c.sel = sel
end

-- Selection order is not what picks the target, and cannot be -- REAPER does
-- not expose it. Reselecting in the opposite order must give the same answer,
-- which is the whole reason the rule is positional.
do
  local c = cases[1]
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(c.tgt.item, true)
  for _, r in ipairs(c.refs) do reaper.SetMediaItemSelected(r.item, true) end
  local sel = Select.resolve(cfg)
  ok(sel.target[1] and sel.target[1].item == c.tgt.item,
     "selecting the target first changes nothing")

  -- And an explicit track number overrides it, which is what a headless run
  -- uses when the layout does not suit the rule.
  local cfg2 = Config.new()
  for k, v in pairs(cfg) do cfg2[k] = v end
  cfg2.rider_target_track =
    math.floor(reaper.GetMediaTrackInfo_Value(c.refs[1].track, "IP_TRACKNUMBER"))
  local sel2 = Select.resolve(cfg2)
  ok(sel2.target[1] and sel2.target[1].item == c.refs[1].item,
     "an explicit target track overrides the auto rule")
  ok(#sel2.refs == 2, "and everything else becomes reference",
     tostring(#sel2.refs))
end

-------------------------------------------------------------------- analysis

for _, c in ipairs(cases) do
  local tag = " at playrate " .. c.playrate
  local data, err = Analyze.drive(Ride.analyse(c.sel, cfg, ensure_kernel, nil))
  if not data then bail("ride analysis failed" .. tag .. ": " .. tostring(err)) end
  c.data = data

  local t = data.targets[1]
  local F, R = t.F, t.R

  -- The accessor-in-a-coroutine bug reads as a completely silent file and
  -- everything downstream stays plausible. Catch it on both sides.
  local loud = 0
  for i = 1, F.n do if (F.bp_db[i] or -120) > -60 then loud = loud + 1 end end
  ok(loud > F.n / 8, "the target accessor delivered audio" .. tag,
     loud .. " of " .. F.n .. " frames above -60 dB in the band")
  ok(R.nrefs == 2, "both reference clips were read" .. tag, tostring(R.nrefs))
  ok(R.n_covered > 0, "and the reference covers the target" .. tag)

  -- Two copies of the same file sum in POWER: exactly 3.01 dB above one.
  -- A single reference's quiet half is its peak less 3.01 for RMS.
  local one_quiet = 20 * math.log(REF_QUIET, 10) - 3.0103
  local function at(take_t) return R.db[math.floor(take_t / F.hop_s) + 1] end
  near(at(1.0), one_quiet + 3.0103, 0.35,
       "two equal reference clips mix to +3.01 dB" .. tag)

  -- The reference steps at SOURCE time 3.0. The clips sit half a second before
  -- the target, so on the target's own timeline that instant is 2.5 s in --
  -- whatever the target's playrate, because the shift is a project-time fact
  -- about the reference and the target's stretch does not touch it.
  local step_t = REF_STEP - 0.5
  local quiet_db, loud_db = at(step_t - 0.4), at(step_t + 0.4)
  near(loud_db - quiet_db, 6, 0.5,
       "the reference step is 6 dB" .. tag,
       string.format("%.2f -> %.2f", quiet_db, loud_db))

  -- ...and it lands where the shift says, not where an unshifted grid would
  -- put it. Bisect for the crossing.
  local lo, hi = step_t - 0.5, step_t + 0.5
  local mid_db = (quiet_db + loud_db) / 2
  for _ = 1, 24 do
    local m = (lo + hi) / 2
    if at(m) < mid_db then lo = m else hi = m end
  end
  near((lo + hi) / 2, step_t, 0.05,
       "and it lands 0.5 s earlier than the target, as the offset says" .. tag)

  -- Whether the reference outruns the target depends on the playrate, and the
  -- test has to say which case it is in rather than assume. The reference sits
  -- 0.5 s early and is LEN long, so on the target's own timeline it stops at
  -- LEN - 0.5 whatever the target's stretch -- at playrate 1 the 6 s target
  -- runs half a second past it, at 1.5 the 4 s target ends well inside it.
  local ref_ends_at = LEN - 0.5
  ok(R.covered[math.floor(1.0 / F.hop_s)],
     "the covered part is marked covered" .. tag)
  if F.span > ref_ends_at + 0.1 then
    ok(not R.covered[F.n],
       "the tail past the reference is marked uncovered" .. tag)
    ok(R.covered[math.floor((ref_ends_at - 0.1) / F.hop_s)],
       "and coverage ends exactly where the reference does" .. tag)
  else
    ok(R.covered[F.n],
       "a target that ends inside the reference is covered throughout" .. tag)
    ok(R.n_covered == F.n, "every one of its frames" .. tag,
       R.n_covered .. " of " .. F.n)
  end
end

-------------------------------------------------------------------- segments

for _, c in ipairs(cases) do
  local tag = " at playrate " .. c.playrate
  local d = Ride.derive(c.data, cfg)[1]
  c.d = d
  ok(#d.notes == 4, "four notes are found" .. tag, tostring(#d.notes))
  ok(#d.segs == 4, "and become four segments" .. tag, tostring(#d.segs))
  if #d.segs == 4 then
    for i, nt in ipairs(NOTES) do
      -- The accessor already applied the playrate, so a note at source 1.5 s
      -- arrives at take time 1.0 on a 1.5x take. No factor anywhere else.
      near(d.segs[i].t0, nt[1] / c.playrate, 0.03,
           string.format("segment %d starts with its note%s", i, tag))
      ok(d.segs[i].kind == "note",
         string.format("segment %d came from a note, not the fallback%s", i, tag))
    end
  end
end

------------------------------------------------------------------- the terms

-- Every assertion here is a DIFFERENCE between two segments. The vocal band
-- tilts all four by the same amount (they are the same pitch) and the static
-- term is common to all four, so both cancel and what is left is the term
-- under test.
for _, c in ipairs(cases) do
  local tag = " at playrate " .. c.playrate
  local function derive(over)
    local c2 = Config.new()
    for k, v in pairs(cfg) do c2[k] = v end
    for k, v in pairs(over) do c2[k] = v end
    return Ride.derive(c.data, c2)[1], c2
  end

  -- Follow alone. Which notes straddle the reference step is a function of the
  -- playrate: the step is at take time 2.5 either way, but the notes arrive
  -- two thirds as early on the stretched take, so note 3 is AFTER the step at
  -- playrate 1 and BEFORE it at 1.5. Notes 1 and 2 are always before it and
  -- note 4 always after, so those are the pairs to compare -- and with the
  -- level term at zero the vocal's own loudness is out of the answer, which is
  -- what lets a loud note and a soft one be compared at all.
  local d = derive({ rider_tgt_level = 0, rider_ref_follow = 100 })
  if #d.segs == 4 then
    near(d.segs[4].gain_db - d.segs[1].gain_db, 6, 0.6,
         "following the reference lifts the loud-backing note by 6 dB" .. tag)
    near(d.segs[4].gain_db - d.segs[2].gain_db, 6, 0.6,
         "however loud the vocal itself was" .. tag)
    near(d.segs[2].gain_db - d.segs[1].gain_db, 0, 0.3,
         "while the vocal's own level is ignored at 0% level" .. tag)
    -- And note 3 follows whichever side of the step it actually falls on.
    local step_side = d.segs[3].t0 >= 2.5 and 6 or 0
    near(d.segs[3].gain_db - d.segs[1].gain_db, step_side, 0.6,
         string.format("note 3 follows the backing it is actually under (%d dB)%s",
                       step_side, tag))
  end

  -- Level alone: notes 1 and 2 sit under the same backing, 6 dB apart in the
  -- vocal, so the ride must close that 6 dB. This is the property the whole
  -- feature exists for -- the soft note rises further under identical backing.
  d = derive({ rider_tgt_level = 100, rider_ref_follow = 0 })
  if #d.segs == 4 then
    near(d.segs[2].gain_db - d.segs[1].gain_db, 6, 0.6,
         "the soft note is raised 6 dB further than the loud one" .. tag)
    near(d.segs[3].gain_db - d.segs[1].gain_db, 0, 0.3,
         "while the backing is ignored at 0% follow" .. tag)
  end

  -- Half strength is half the move.
  d = derive({ rider_tgt_level = 50, rider_ref_follow = 0 })
  if #d.segs == 4 then
    near(d.segs[2].gain_db - d.segs[1].gain_db, 3, 0.4,
         "and at 50% it is half of it" .. tag)
  end

  -- Both together: note 4 is soft under a loud backing, note 1 loud under a
  -- quiet one, so it gets both corrections.
  d = derive({ rider_tgt_level = 100, rider_ref_follow = 100 })
  if #d.segs == 4 then
    near(d.segs[4].gain_db - d.segs[1].gain_db, 12, 1.0,
         "both terms stack on the soft note under the loud backing" .. tag)
  end
end

--------------------------------------------- part 1 under a rider selection

-- The regression this section exists for. Part 1 used to work on "every
-- selected item", which was correct while the script had a single input -- and
-- silently wrong the moment the rider gave the user a reason to select the
-- backing tracks too. Under this selection it analysed a reference clip,
-- reported its note count as the vocal's, and wrote Pre-FX automation onto the
-- reference TRACKS. Both tabs now resolve the selection through Select, so the
-- note leveling reads the target and nothing else.
--
-- This drives the same modules the Notes tab drives, in the same order, rather
-- than the panel itself: the panel needs a defer loop no suite can run, but
-- everything that decides WHICH audio gets touched is out here.
for _, c in ipairs(cases) do
  local tag = " at playrate " .. c.playrate
  reaper.SelectAllMediaItems(0, false)
  for _, r in ipairs(c.refs) do reaper.SetMediaItemSelected(r.item, true) end
  reaper.SetMediaItemSelected(c.tgt.item, true)

  local sel = Select.resolve(cfg)
  ok(#sel.target == 1 and sel.target[1].item == c.tgt.item,
     "part 1 resolves to the target clip, not the first selected one" .. tag)

  -- Part 1's read is Ride.analyse with no reference at all.
  local data, err = Analyze.drive(
    Ride.analyse({ target = sel.target, refs = {} }, cfg, ensure_kernel, nil))
  if not data then bail("part 1 analysis failed" .. tag .. ": " .. tostring(err)) end
  ok(#data.targets == 1, "and reads exactly one clip" .. tag,
     tostring(#data.targets))
  ok(data.targets[1].item == c.tgt.item,
     "the one it read is the target" .. tag)

  local results = Ride.notes_only(data, cfg)
  ok(#results == 1, "part 1 produces one result" .. tag, tostring(#results))
  ok(#results[1].notes == 4,
     "with the target's four notes, not a reference's" .. tag,
     tostring(#results[1].notes))
  ok(#results[1].points > 0, "and an envelope to write" .. tag)

  local npoints = Apply.run(results, cfg)
  ok(npoints and npoints > 0, "part 1 writes" .. tag, tostring(npoints))

  -- The decisive assertion: the reference tracks must be untouched. Before the
  -- fix each of them got a full Pre-FX envelope of its own.
  for i, r in ipairs(c.refs) do
    local env = reaper.GetTrackEnvelopeByChunkName(r.track, "<VOLENV")
    local n = env and reaper.CountEnvelopePointsEx(env, -1) or 0
    ok(n == 0,
       string.format("reference track %d keeps a clean Pre-FX envelope%s", i, tag),
       n .. " points")
  end
  local tenv = reaper.GetTrackEnvelopeByChunkName(c.tgt.track, "<VOLENV")
  ok(reaper.CountEnvelopePointsEx(tenv, -1) > 0,
     "while the target track got one" .. tag)

  reaper.Undo_DoUndo2(0)
end

-- An explicit target track redirects part 1 too, so a headless run and the
-- panel cannot disagree about what "the target" means.
do
  local c = cases[1]
  reaper.SelectAllMediaItems(0, false)
  for _, r in ipairs(c.refs) do reaper.SetMediaItemSelected(r.item, true) end
  reaper.SetMediaItemSelected(c.tgt.item, true)
  local cfg2 = Config.new()
  for k, v in pairs(cfg) do cfg2[k] = v end
  cfg2.rider_target_track =
    math.floor(reaper.GetMediaTrackInfo_Value(c.refs[2].track, "IP_TRACKNUMBER"))
  local sel = Select.resolve(cfg2)
  ok(sel.target[1] and sel.target[1].item == c.refs[2].item,
     "part 1 follows an explicit target track")
end

--------------------------------------------------------------------- the write

-- A point far away from the fixture, to prove the rider clears only the span
-- of the clips it rides. Part 1 wipes its whole envelope; this one must not.
local guard_t = cases[1].pos - 5.0
do
  local env = reaper.GetTrackEnvelopeByChunkName(cases[1].tgt.track, "<VOLENV2")
  if not env then bail("the target track has no Volume envelope") end
  local mode = reaper.GetEnvelopeScalingMode(env)
  -- In its own undo block, and that is not tidiness. REAPER snapshots project
  -- state when a block CLOSES, so an edit made outside one is folded into the
  -- next block that closes -- here, the first Apply.ride -- and undoing that
  -- would take the guard point with it. The point of the guard is to still be
  -- there after the undo, so it has to be a committed state of its own.
  reaper.Undo_BeginBlock()
  reaper.InsertEnvelopePointEx(env, -1, guard_t,
    reaper.ScaleToEnvelopeMode(mode, 10 ^ (-3 / 20)), 0, 0, false, false)
  reaper.Envelope_SortPointsEx(env, -1)
  reaper.Undo_EndBlock("Note Leveling ride verify guard point", -1)
end

for _, c in ipairs(cases) do
  local tag = " at playrate " .. c.playrate
  local d = c.d
  local nride, npre = Apply.ride({ {
    item = d.item, take = d.take, geo = d.geo,
    points = d.points, prefx_points = d.prefx_points, segs = d.segs,
  } }, cfg)
  ok(nride and nride > 0, "the ride is written" .. tag, tostring(npre))
  ok(npre and npre > 0, "and the Pre-FX envelope with it" .. tag, tostring(npre))

  local env = reaper.GetTrackEnvelopeByChunkName(c.tgt.track, "<VOLENV2")
  local mode = reaper.GetEnvelopeScalingMode(env)

  -- Each segment's own level, read back out of the project at the segment's
  -- midpoint in PROJECT time. This is the assertion that the whole chain --
  -- take time to project time, dB to the envelope's scaling -- is right.
  for i, s in ipairs(d.segs) do
    local mid = c.pos + (s.t0 + s.t1) / 2
    near(env_db_at(env, mode, mid), s.gain_db, 0.05,
         string.format("the envelope carries segment %d's gain%s", i, tag))
  end

  -- The claim the design rests on: the move is FINISHED before the word, not
  -- arriving during it. At lookahead before each onset the envelope already
  -- reads that segment's gain.
  local look = cfg.rider_lookahead_ms / 1000
  for i = 2, #d.segs do
    local s = d.segs[i]
    near(env_db_at(env, mode, c.pos + s.t0 - look), s.gain_db, 0.05,
         string.format("and reaches segment %d's gain %d ms before its onset%s",
                       i, cfg.rider_lookahead_ms, tag))
  end

  -- And it holds between segments instead of returning to unity.
  local gap = c.pos + (d.segs[1].t1 + d.segs[2].t0) / 2
  near(env_db_at(env, mode, gap), d.segs[1].gain_db, 0.05,
       "the envelope holds through a gap rather than returning to unity" .. tag)

  local pre = reaper.GetTrackEnvelopeByChunkName(c.tgt.track, "<VOLENV")
  ok(reaper.CountEnvelopePointsEx(pre, -1) > 0,
     "the Pre-FX envelope has points" .. tag)
end

do
  local env = reaper.GetTrackEnvelopeByChunkName(cases[1].tgt.track, "<VOLENV2")
  local mode = reaper.GetEnvelopeScalingMode(env)
  near(env_db_at(env, mode, guard_t), -3, 0.05,
       "automation outside the ridden span survives the write")
end

----------------------------------------------------------------------- undo

-- One apply per case, so one undo per case. Both envelopes went in inside
-- those blocks and both must come back out.
for _ = 1, #cases do reaper.Undo_DoUndo2(0) end
local left = 0
for _, c in ipairs(cases) do
  for _, name in ipairs({ "<VOLENV2", "<VOLENV" }) do
    local env = reaper.GetTrackEnvelopeByChunkName(c.tgt.track, name)
    if env then left = left + reaper.CountEnvelopePointsEx(env, -1) end
  end
end
-- The guard point was inserted outside any undo block, so it is the one thing
-- that should still be there.
ok(left == 1, "undo takes both envelopes back off", left .. " points left")

report()
