-- Vocal Normalizer -- whole-pipeline check. Run from the Actions list.
--
-- The only test that crosses the seam between the pure stages and the project:
-- accessor -> kernel -> blocks -> gate -> gain -> take volume -> read back. In
-- every sibling repo that seam is exactly where the real bugs lived, and it is
-- the one place unit tests on either side prove nothing about.
--
-- It builds its own fixture rather than using whatever is selected, and it
-- builds it TWICE -- once at playrate 1 and once at 1.25. The stretched copy
-- is the point: the take accessor hands back audio with the playrate already
-- applied, so the span to read is the item length and not the item length
-- times the playrate. An implementation that scaled the span would read past
-- the end of the accessor, capture silence for the last fifth of the take, and
-- pass at playrate 1 while quietly measuring the wrong thing on every
-- time-stretched item. The fixture therefore ENDS on a loud burst, so that
-- silence has somewhere to show.
--
-- Two things here cannot be checked by anything else in the repo:
--
--   * the LUFS null against REAPER's own analysis. Opening the band wide and
--     switching K-weighting on turns this script into an ordinary BS.1770
--     meter, and SWS's NF_AnalyzeTakeLoudness is an independent implementation
--     of the same standard sitting in the same process. If those two agree on
--     a real file, then the accessor read, the frame grid, the filters, the
--     channel summation, the gate and the integration are all right together.
--   * the round trip. Measure, apply, measure again: the second measurement
--     has to land on the target, which is the only assertion that says the
--     gain arithmetic and the volume arithmetic agree about what they mean.
--
-- Cleans up after itself: the tracks are deleted, the fixture removed, and the
-- item selection put back.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local cleanup = {}
local function say(s) out[#out + 1] = s end
local function report()
  for i = #cleanup, 1, -1 do pcall(cleanup[i]) end
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
     string.format("%s vs %.6g (tol %.3g)", tostring(a), b, tol))
end
-- Anything that stops the run counts as a failed run: a green exit has to mean
-- the pipeline was verified, not that the script declined to look.
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then
  say("  FAIL  ReaImGui is not installed") fail = 1 report() return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui    = require "imgui" "0.9"
local Wav      = require "wav"
local Config   = require "vn.config"
local Kernel   = require "vn.kernel"
local Analyze  = require "vn.analyze"
local Loudness = require "vn.loudness"
local Plan     = require "vn.plan"
local Apply    = require "vn.apply"

-- ReaImGui destroys a context that has not been used for a few seconds, and a
-- suite like this one spends real time writing a fixture and pushing audio
-- through a kernel between uses. The symptom is not subtle -- "expected a
-- valid ImGui_Context*, got 0x..." out of Attach, several sections in -- but
-- it depends on how fast the machine is, so it is a flake rather than a
-- failure. Asking for the context through here means it is checked at every
-- use and rebuilt when it has gone.
local ctx
local function alive(c)
  if not c then return false end
  -- pcall, because an optional or strict ReaImGui symbol raises rather than
  -- returning false, and a validity check that can itself throw is no check.
  local okv, v = pcall(ImGui.ValidatePtr, c, "ImGui_Context*")
  return okv and v == true
end
local function get_ctx()
  if alive(ctx) then return ctx end
  ctx = ImGui.CreateContext("Vocal Normalizer verify")
  return ctx
end

--------------------------------------------------------------------- fixture
--
-- Three files, because three different questions need three different signals.
--
--   BRIGHT  mono, fundamentals plus a lot of high-frequency energy. The main
--           fixture: geometry, the round trip, linked mode.
--   STEREO  the same signal on two channels. Used for the null against SWS,
--           for a reason worth stating -- see the null section below.
--   DARK    the same fundamentals with the high end taken away. Paired with
--           BRIGHT it is the demonstration this whole script exists for.
--
-- All three are four one-second bursts with one-second gaps, and the LAST
-- second is a burst, so a read that ran past the end of the accessor has
-- somewhere to show up.

local SR      = 48000
local FIX_LEN = 8.0

local F_BRIGHT = script_dir .. "test/vn_fixture.wav"
local F_STEREO = script_dir .. "test/vn_fixture_stereo.wav"
local F_DARK   = script_dir .. "test/vn_fixture_dark.wav"
local FIXTURE_FILES = { F_BRIGHT, F_STEREO, F_DARK }

-- Same three fundamentals in both, so the two takes are the "same performance".
-- The bright one adds 3, 6.5 and 9 kHz -- consonants, breath and air, the
-- content a sibilant close-mic'd vocal has and a soft dark one does not.
local FUNDAMENTALS = { { 220, 1.0 }, { 440, 0.6 }, { 660, 0.4 } }
local AIR          = { { 3000, 0.9 }, { 6500, 0.8 }, { 9000, 0.5 } }

local function burst(partials)
  return function(t)
    if math.floor(t) % 2 == 0 then return 0 end
    local v = 0
    for _, p in ipairs(partials) do
      v = v + p[2] * math.sin(2 * math.pi * p[1] * t)
    end
    return v * 0.12
  end
end

local function write_wav(path, nchan, gen)
  local w, err = Wav.create(path, nchan, SR)
  if not w then return nil, tostring(err) end
  local n = math.floor(FIX_LEN * SR)
  local buf = {}
  for i = 0, n - 1 do
    local v = gen(i / SR)
    for _ = 1, nchan do buf[#buf + 1] = v end
  end
  w:write(buf, 1, n * nchan)
  w:close()
  return true
end

local function write_fixtures()
  -- burst() closes over the list it is given, so the bright partials are built
  -- into their own table rather than appended to FUNDAMENTALS, which the dark
  -- generator is still holding.
  local all = {}
  for _, p in ipairs(FUNDAMENTALS) do all[#all + 1] = p end
  for _, p in ipairs(AIR) do all[#all + 1] = p end
  local bright = burst(all)

  local o, e = write_wav(F_BRIGHT, 1, bright)
  if not o then return nil, e end
  o, e = write_wav(F_STEREO, 2, bright)
  if not o then return nil, e end
  return write_wav(F_DARK, 1, burst(FUNDAMENTALS))
end

-- The fixture tracks are NAMED, and the suite sweeps for that name before it
-- builds anything. The reason is a run that did not reach its own cleanup:
-- REAPER puts up a modal ReaScript Error dialog on an uncaught error, which
-- blocks the main thread until somebody clicks it, and by then the run has
-- been killed and its tracks are still in the project. Sweeping first makes
-- the suite self-healing instead of leaving a trail.
local TRACK_NAME = "VN verify fixture"

-- Matched two ways, because the name is only on tracks this version made: a
-- track is also stale if everything on it came from the fixture file.
local function is_stale(tr)
  local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if nm == TRACK_NAME then return true end
  local n = reaper.CountTrackMediaItems(tr)
  if n == 0 then return false end
  for i = 0, n - 1 do
    local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(tr, i))
    if not take or reaper.TakeIsMIDI(take) then return false end
    local fn = reaper.GetMediaSourceFileName(
      reaper.GetMediaItemTake_Source(take), "")
    local mine = false
    for _, f in ipairs(FIXTURE_FILES) do if fn == f then mine = true end end
    if not mine then return false end
  end
  return true
end

local function sweep()
  local n = 0
  for i = reaper.CountTracks(0) - 1, 0, -1 do
    local tr = reaper.GetTrack(0, i)
    if is_stale(tr) then reaper.DeleteTrack(tr) n = n + 1 end
  end
  return n
end

local function add_item(playrate, pos, path)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", TRACK_NAME, true)
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  local psrc = reaper.PCM_Source_CreateFromFile(path or F_BRIGHT)
  if not psrc then return nil end
  reaper.SetMediaItemTake_Source(take, psrc)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", FIX_LEN / playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playrate)
  -- Preserve pitch off on purpose: with it on, REAPER's stretcher smears the
  -- abrupt burst edges of a synthetic fixture by tens of milliseconds and the
  -- boundary assertions stop meaning anything.
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
  reaper.UpdateItemInProject(item)
  return { track = tr, item = item, take = take, pos = pos, playrate = playrate }
end

--------------------------------------------------------------------- helpers

local function analyse(f, cfg)
  local geo = Analyze.geometry(f.take)
  local k, kerr = Kernel.new(ImGui, get_ctx(), script_dir, geo.nchan, cfg, geo.rate)
  if not k then return nil, "kernel would not build: " .. tostring(kerr) end
  local F, ferr = Analyze.drive(function()
    return Analyze.run(f.take, cfg, k, geo)
  end)
  Kernel.detach(ImGui, get_ctx(), k)
  if not F then return nil, tostring(ferr) end
  return { item = f.item, take = f.take, name = "fixture", geo = geo, F = F }
end

-- Re-price without re-reading, against whatever volumes the take now carries.
-- Exactly what the panel does after an Apply, and the reason a second read is
-- not needed to prove the pass landed.
local function reprice(clips, cfg)
  for _, c in ipairs(clips) do c.geo = Analyze.geometry(c.take) end
  return Plan.run(clips, cfg)
end

local function conf(over)
  local c = Config.new()
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

------------------------------------------------------------------------- run

local wrote, werr = write_fixtures()
if not wrote then bail("could not write the fixtures: " .. tostring(werr)) end
cleanup[#cleanup + 1] = function()
  for _, f in ipairs(FIXTURE_FILES) do
    os.remove(f)
    os.remove(f .. ".reapeaks")
    os.remove(test_dir .. "peaks/" .. f:match("([^/\\]+)$") .. ".reapeaks")
  end
  os.remove(test_dir .. "peaks")
end

-- Remember the selection: this suite needs none, and must leave none behind.
local had = {}
for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
  had[#had + 1] = reaper.GetSelectedMediaItem(0, i)
end
cleanup[#cleanup + 1] = function()
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(had) do reaper.SetMediaItemSelected(it, true) end
  reaper.UpdateArrange()
end

local fixtures = {}
reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()
local stale = sweep()
if stale > 0 then
  say(string.format("  note  removed %d fixture track%s left by an earlier run",
                    stale, stale == 1 and "" or "s"))
end
for _, spec in ipairs({ { 1.0, 37.5 }, { 1.25, 60.0 } }) do
  local f = add_item(spec[1], spec[2])
  if not f then
    reaper.Undo_EndBlock("Vocal Normalizer verify fixture", -1)
    reaper.PreventUIRefresh(-1)
    bail("could not create the fixture item")
  end
  fixtures[#fixtures + 1] = f
end
reaper.Undo_EndBlock("Vocal Normalizer verify fixture", -1)
reaper.PreventUIRefresh(-1)
cleanup[#cleanup + 1] = function()
  for _, f in ipairs(fixtures) do reaper.DeleteTrack(f.track) end
  reaper.UpdateArrange()
end

-- The two playrate copies, which is what the geometry, round-trip and linked
-- sections operate on. `fixtures` keeps growing as later sections add the
-- stereo and dark takes, and it is the list cleanup walks -- but a round trip
-- over "however many items exist by now" would silently change what it was
-- testing every time a section was added above it.
local main = { fixtures[1], fixtures[2] }

----------------------------------------------------------------- geometry

do
  local cfg = conf()
  for _, f in ipairs(main) do
    local c, err = analyse(f, cfg)
    if not c then bail(string.format("playrate %.2f: %s", f.playrate, err)) end
    local tag = string.format("at playrate %.2f", f.playrate)

    -- The span is the ITEM length, not the item length times the playrate.
    near(c.F.span, FIX_LEN / f.playrate, 1e-6,
         "the analysed span is the item length " .. tag)
    near(c.geo.item_len, FIX_LEN / f.playrate, 1e-6,
         "and the item is the length we asked for " .. tag)
    ok(c.F.rate == SR, "the source rate came from the file " .. tag,
       tostring(c.F.rate))
    ok(c.geo.rate_known, "and it was known, not guessed " .. tag)

    -- The item sits at 37.5 s and 60 s on the timeline; the accessor's own
    -- clock still starts at zero. A read anchored at project time would have
    -- come back silent, so the fact that anything was measured at all is the
    -- assertion here.
    local rows = Plan.run({ c }, cfg)
    ok(rows[1].band ~= nil, "the take measured at all " .. tag,
       tostring(rows[1].err))

    -- THE ONE THAT CATCHES A SCALED SPAN. The fixture's last second is a
    -- burst. If the read had run past the accessor's end, the tail would be
    -- digital silence and the final blocks would fall under the absolute gate.
    local last = rows[1].blocks[#rows[1].blocks]
    ok(last.abs, "the final block is real audio, not padded silence " .. tag,
       string.format("%.2f dB at %.2f s", last.db, last.t0))
    ok(last.gated, "and it is inside the measurement " .. tag,
       string.format("%.2f dB", last.db))

    -- The gate has to have done something: half the fixture is silence.
    ok(rows[1].band.ngated < rows[1].band.nblocks * 0.75,
       "the gate dropped the gaps " .. tag,
       string.format("%d of %d kept", rows[1].band.ngated, rows[1].band.nblocks))
  end
end

--------------------------------------------------- the null against REAPER

do
  -- Band wide open plus K-weighting IS BS.1770, so this must agree with an
  -- independent implementation of the same standard living in the same
  -- process. If it does, then the accessor read, the frame grid, the filters,
  -- the channel summation, the gate and the integration are all right
  -- together, which no other test in this repo can say.
  --
  -- On the STEREO fixture, and that is not a detail. Measured on 7.75, SWS
  -- reads a MONO take exactly 3.0103 dB higher than we do -- it is measuring
  -- the take as it lands on a stereo track, where one channel of material
  -- appears on two, while we sum the channels the file actually has. Both are
  -- defensible readings of BS.1770 and neither is a bug, so the null is run
  -- where the question does not arise. The mono/stereo relationship is then
  -- asserted separately, on our own two takes, where it IS ours to get right.
  local cfg = conf({ band_lo_hz = 20, band_hi_hz = 20000, band_order = 4,
                     kweight = true })

  local stereo = add_item(1.0, 90.0, F_STEREO)
  if not stereo then bail("could not create the stereo fixture item") end
  fixtures[#fixtures + 1] = stereo

  local cs, serr = analyse(stereo, cfg)
  if not cs then bail("stereo analysis: " .. tostring(serr)) end
  ok(cs.geo.nchan == 2, "the stereo fixture read as two channels",
     tostring(cs.geo.nchan))
  local rs = Plan.run({ cs }, cfg)

  local rv, lufs, _, truepeak = reaper.NF_AnalyzeTakeLoudness(cs.take, true)
  if not rv then bail("NF_AnalyzeTakeLoudness would not run") end

  near(rs[1].kw.db, lufs, 0.3, "our LUFS agrees with SWS's BS.1770 analysis")
  -- The band chain is configured as LUFS here too, so the two must agree with
  -- each other as well -- which says the band path and the reference path are
  -- reading the same samples through the same grid.
  near(rs[1].own.db, lufs, 0.3, "and so does the band chain, configured wide")

  -- Ours is a SAMPLE peak and theirs is a true peak, so ours must be at or
  -- below theirs and within the fraction of a dB inter-sample peaks add.
  ok(rs[1].peak_db <= truepeak + 0.01, "the sample peak is not above true peak",
     string.format("%.3f vs %.3f", rs[1].peak_db, truepeak))
  near(rs[1].peak_db, truepeak, 1.0, "and is close to it")

  -- Channel summation, through the accessor this time rather than on a buffer
  -- the selftest built: the same signal on two channels is exactly 3.0103 dB
  -- louder than on one. This is the number SWS and we disagree about above, so
  -- it is worth pinning down on the side that is ours.
  local cm, merr = analyse(main[1], cfg)
  if not cm then bail("mono analysis: " .. tostring(merr)) end
  local rm = Plan.run({ cm }, cfg)
  near(rs[1].kw.db - rm[1].kw.db, 3.0103, 0.02,
       "two channels of the same signal read 3.01 dB above one")
end

------------------------------------------------- the bias, on two takes

do
  -- The reason the script exists, as a measurement rather than an argument.
  --
  -- Two takes of the same performance -- identical fundamentals -- one bright
  -- and one dark. The dark one is trimmed until the two have exactly the same
  -- LUFS, which is the situation a LUFS normalizer would call "done": it would
  -- leave both where they are and they would not sound alike. The band
  -- measurement has to disagree, and by enough to matter.
  local cfg = conf({ target_db = -30, max_boost_db = 24, max_cut_db = 24,
                     limit_peak = false })

  local dark = add_item(1.0, 110.0, F_DARK)
  if not dark then bail("could not create the dark fixture item") end
  fixtures[#fixtures + 1] = dark

  local cb, e1 = analyse(main[1], cfg)
  local cd, e2 = analyse(dark, cfg)
  if not cb or not cd then bail("bias analysis: " .. tostring(e1 or e2)) end
  local clips = { cb, cd }

  -- Trim the dark take so the two match in LUFS. Take volume is folded into
  -- the measurement, so this needs no second read.
  local first = Plan.run(clips, cfg)
  local delta = first[1].kw.db - first[2].kw.db
  reaper.SetMediaItemTakeInfo_Value(cd.take, "D_VOL", 10 ^ (delta / 20))

  local rows = reprice(clips, cfg)
  near(rows[1].kw.db, rows[2].kw.db, 0.02,
       "the two takes are matched in LUFS, which is where a LUFS pass stops")

  local gap = rows[2].own.db - rows[1].own.db
  ok(gap > 3, "but the band hears the dark take as the LOUDER of the two",
     string.format("bright %.2f, dark %.2f, %.2f dB apart",
                   rows[1].own.db, rows[2].own.db, gap))

  -- ...so they ask for different gains, and the difference is the correction.
  near(rows[1].gain_db - rows[2].gain_db, gap, 0.02,
       "and the two gains differ by exactly that gap")
  ok(rows[1].gain_db > rows[2].gain_db,
     "the bright take is the one lifted, which is the complaint answered")

  -- After the pass they match where it counts -- and now differ in LUFS by
  -- the amount they always differed by in the band.
  Apply.run(rows, cfg)
  local after = reprice(clips, cfg)
  near(after[1].own.db, after[2].own.db, 0.02,
       "after the pass the two takes match in the band")
  -- `gap` is dark minus bright in the band, so the BRIGHT take is the one
  -- lifted, and afterwards it is the bright take whose LUFS is the higher.
  -- That is the whole trade being made visible: matched where the voice is,
  -- deliberately unmatched where the sibilance is.
  near(after[1].kw.db - after[2].kw.db, gap, 0.05,
       "and their LUFS now differ by the bias that was removed")

  Apply.reset(after, cfg)
end

-------------------------------------------------------------- the round trip

do
  local cfg = conf({ target_db = -30, max_boost_db = 24, max_cut_db = 24,
                     limit_peak = false, apply_to = "take" })
  local clips = {}
  for i, f in ipairs(main) do
    local c, err = analyse(f, cfg)
    if not c then bail("round trip analysis: " .. tostring(err)) end
    clips[i] = c
  end

  local rows = Plan.run(clips, cfg)
  local wanted = rows[1].gain_db
  ok(math.abs(wanted) > 0.5, "the fixture needs a real move to reach target",
     string.format("%+.2f dB", wanted))

  local n, skipped, aerr = Apply.run(rows, cfg)
  ok(n == 2 and not aerr, "both clips were written", tostring(aerr))

  -- Re-price against the volumes just written. No second read: the frames are
  -- unchanged, which is the whole architecture -- and if that is true, the
  -- measurement must now be exactly the target.
  local rows2 = Plan.run(clips, cfg)   -- stale geo on purpose
  ok(rows2[1].gain_db == wanted, "a stale price does not notice the write")

  rows2 = reprice(clips, cfg)
  for i = 1, 2 do
    near(rows2[i].own.db, cfg.target_db, 0.01,
         string.format("clip %d now measures at target", i))
    near(rows2[i].gain_db, 0, 0.01,
         string.format("clip %d asks for nothing more", i))
  end

  -- Idempotent: applying again must change nothing.
  local before = reaper.GetMediaItemTakeInfo_Value(clips[1].take, "D_VOL")
  Apply.run(rows2, cfg)
  near(reaper.GetMediaItemTakeInfo_Value(clips[1].take, "D_VOL"), before, 1e-9,
       "a second pass writes the same number")

  -- Take polarity is a signed D_VOL, not a negative gain: normalising must not
  -- silently un-flip a deliberately inverted take.
  reaper.SetMediaItemTakeInfo_Value(clips[1].take, "D_VOL", -before)
  local rows3 = reprice(clips, cfg)
  near(rows3[1].own.db, cfg.target_db, 0.01,
       "an inverted take measures the same as an upright one")
  Apply.run(rows3, cfg)
  ok(reaper.GetMediaItemTakeInfo_Value(clips[1].take, "D_VOL") < 0,
     "and stays inverted after a pass")
  reaper.SetMediaItemTakeInfo_Value(clips[1].take, "D_VOL", before)

  -- Item volume multiplies with take volume, so writing take volume has to
  -- account for it or the clip lands short by exactly the item volume.
  reaper.SetMediaItemInfo_Value(clips[1].item, "D_VOL", 0.5)
  local rows4 = reprice(clips, cfg)
  near(rows4[1].gain_db, 6.0206, 0.02,
       "halving item volume asks for 6.02 dB back")
  Apply.run(rows4, cfg)
  local rows5 = reprice(clips, cfg)
  near(rows5[1].own.db, cfg.target_db, 0.01,
       "and take volume compensated for it exactly")
  reaper.SetMediaItemInfo_Value(clips[1].item, "D_VOL", 1)

  -- Reset puts the written control back to unity.
  Apply.reset(rows5, cfg)
  near(reaper.GetMediaItemTakeInfo_Value(clips[1].take, "D_VOL"), 1, 1e-9,
       "reset returns take volume to unity")
end

----------------------------------------------------------------- linked mode

do
  -- One gain for the pair, so the 6 dB the two clips differ by survives the
  -- pass. That is the difference between normalising takes and normalising a
  -- performance, and it is the setting a comped vocal needs.
  local cfg = conf({ target_db = -30, max_boost_db = 24, max_cut_db = 24,
                     limit_peak = false, link_items = true })
  local clips = {}
  for i, f in ipairs(main) do
    local c, err = analyse(f, cfg)
    if not c then bail("linked analysis: " .. tostring(err)) end
    clips[i] = c
  end
  reaper.SetMediaItemTakeInfo_Value(clips[2].take, "D_VOL", 0.5)

  local rows = Plan.run(clips, cfg)
  near(rows[1].gain_db, rows[2].gain_db, 1e-12, "linked, one gain for both")

  local before1 = rows[1].own.db
  local before2 = rows[2].own.db
  Apply.run(rows, cfg)
  local after = reprice(clips, cfg)
  near(after[1].own.db - after[2].own.db, before1 - before2, 0.01,
       "the difference between the two clips is preserved")
  near(after[1].band.db, cfg.target_db, 0.05,
       "and the pair as a programme lands on target")

  Apply.reset(after, cfg)
end

report()
