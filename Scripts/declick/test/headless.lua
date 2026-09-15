-- Adaptive De-Click -- headless tests.
--
-- Covers the pure-Lua stages: the threshold derivation, the config split that
-- decides what invalidates what, the CSV log and the WAV writer. No REAPER, no
-- audio, no ReaImGui.
--
--   python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/headless.lua
--
-- What this cannot cover is the EEL transcription itself, which is what
-- test/selftest_in_reaper.lua exists for, or whether the rules match a voice,
-- which only real material can say.

package.path = "./?.lua;./test/?.lua;" .. package.path

local AutoThresh = require "dc.autothresh"
local Silence    = require "dc.silence"
local Config     = require "dc.config"
local Log        = require "dc.log"
local Wav        = require "dc.wav"

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then pass = pass + 1
  else fail = fail + 1 print("FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function between(v, lo, hi, name)
  ok(v ~= nil and v >= lo and v <= hi, name,
     string.format("%s not in [%g, %g]", tostring(v), lo, hi))
end
local function section(s) print("-- " .. s) end

-- Histograms on the kernel's own axis: 260 bins of 0.25 dB from -5 dB.
local HN, HLO, HBIN = 260, -5, 0.25
local function build(density)
  local counts = {}
  for b = 0, HN - 1 do
    counts[b] = math.floor(density(HLO + (b + 0.5) * HBIN) + 0.5)
  end
  return { counts = counts, n = HN, lo = HLO, bin = HBIN }
end
local function total_of(h)
  local t = 0
  for b = 0, h.n - 1 do t = t + h.counts[b] end
  return t
end

local function taper(db) return db < 0 and 0 or 4000 * math.exp(-0.5 * db) end
local function bump(db, at, wid, amp)
  return amp * math.exp(-((db - at) ^ 2) / (2 * wid * wid))
end

--------------------------------------------------------------- autothresh

section("autothresh: a file with a clean gap")
do
  -- A tapering transient population, a stretch of nothing, then a separate
  -- click cluster. This is the case the whole design assumes exists.
  local h = build(function(db) return taper(db) + bump(db, 30, 3, 60) end)
  local cfg = Config.new()
  local th = AutoThresh.derive(h, cfg)

  ok(not th.fallback, "a clean gap does not fall back")
  ok(th.tail_db ~= nil, "tail departure finds a crossover")
  ok(th.knee_db ~= nil, "the knee search finds a shelf")
  between(th.tail_db, 16, 32, "tail lands in or above the gap")
  -- The knee fires at the elbow of the drop, not at the start of the shelf, so
  -- with a strong click cluster it lands systematically BELOW the tail
  -- departure -- the taper's contribution falls to the cluster's level well
  -- before it vanishes. That is exactly why the spec takes the higher of the
  -- two rather than averaging them, and it is worth asserting the relationship
  -- rather than a magic range.
  between(th.knee_db, 5, 32, "knee lands somewhere on the drop")
  ok(th.knee_db <= th.tail_db, "the knee is the less conservative of the two",
     string.format("knee %.2f, tail %.2f", th.knee_db, th.tail_db))
  ok(th.derived_db == math.max(th.tail_db, th.knee_db),
     "the higher estimator wins")
  ok(th.fit and th.fit.slope < 0, "the fitted taper decays")
  -- The threshold has to sit above the transients and below the clicks, or it
  -- is not in the gap at all.
  between(th.final_db, 16, 34, "the derived threshold sits in the gap")
end

section("autothresh: the offset is the tuning knob")
do
  local h = build(function(db) return taper(db) + bump(db, 30, 3, 60) end)
  local base = AutoThresh.derive(h, Config.new())
  local c = Config.new()
  c.sens_offset_db = 4
  local up = AutoThresh.derive(h, c)
  ok(math.abs(up.final_db - (base.derived_db + 4)) < 1e-9,
     "the offset moves the final threshold and nothing else",
     string.format("%.3f vs %.3f", up.final_db, base.derived_db + 4))
  ok(up.derived_db == base.derived_db, "the offset does not move the estimate")
  c.sens_offset_db = -60
  ok(AutoThresh.derive(h, c).final_db >= 0.5, "the result is clamped low")
  c.sens_offset_db = 60
  ok(AutoThresh.derive(h, c).final_db <= 42, "the result is clamped high")
end

section("autothresh: a file with no gap")
do
  -- One smooth population and nothing else. There is no threshold that
  -- separates clicks from consonants here, and the honest answer is to say so.
  local h = build(taper)
  local th = AutoThresh.derive(h, Config.new())
  ok(total_of(h) >= 50, "the no-gap fixture has enough events to be judged")
  ok(th.tail_db == nil, "no crossover is invented on a pure taper")
  ok(th.knee_db == nil, "no knee is invented on a straight log curve")
  ok(th.fallback, "a file with no gap falls back")
  ok(th.warning ~= nil, "and says why")
  ok(th.final_db ~= nil, "and still yields a usable number")
end

section("autothresh: too few events")
do
  local h = build(function(db) return bump(db, 20, 1, 1.5) end)
  ok(total_of(h) < 50, "the sparse fixture really is sparse")
  local th = AutoThresh.derive(h, Config.new())
  ok(th.fallback, "too few candidates falls back")
  ok(th.warning and th.warning:find("too few"), "and names the reason")
  ok(th.final_db == Config.defaults.sens_db,
     "and uses the manual threshold rather than a fitted guess")
end

section("autothresh: the estimators disagreeing is reported")
do
  -- A shelf low down (so the knee fires early) with the real click cluster far
  -- above it (so the tail fires late). The number is still usable -- the higher
  -- one wins -- but the disagreement is the thing worth saying.
  local h = build(function(db)
    return taper(db) + bump(db, 12, 1.2, 40) + bump(db, 36, 2, 50)
  end)
  local th = AutoThresh.derive(h, Config.new())
  if th.tail_db and th.knee_db and math.abs(th.tail_db - th.knee_db) > 8 then
    ok(th.warning ~= nil and th.warning:find("disagree"),
       "wide disagreement is reported")
    ok(th.derived_db == math.max(th.tail_db, th.knee_db),
       "and the conservative one is still used")
  else
    ok(true, "fixture did not separate the estimators; nothing to assert")
  end
end

section("autothresh: a threshold resting on almost nothing is flagged")
do
  -- A big bulk with a handful of stray events far above it. Nothing here is
  -- obviously wrong -- the fit is real and the crossover is real -- but the
  -- resulting threshold keeps four events out of thousands, and the panel has
  -- to say so rather than report a confident number.
  local h = build(function(db)
    return taper(db) + ((db > 34 and db < 36) and 2 or 0)
  end)
  local th = AutoThresh.derive(h, Config.new())
  if th.derived_db and th.derived_db > 30 then
    ok(th.sparse, "a threshold with almost no survivors is flagged")
    ok(th.warning and th.warning:find("resting on very little"),
       "and says what to loosen")
  else
    ok(true, "fixture did not produce a sparse estimate; nothing to assert")
  end

  -- The healthy case must NOT be flagged, or the warning is noise.
  local clean = build(function(db) return taper(db) + bump(db, 30, 3, 60) end)
  local cth = AutoThresh.derive(clean, Config.new())
  ok(not cth.sparse, "a well-populated gap is not flagged",
     string.format("%s survivors", tostring(cth.survivors)))
end

section("autothresh: an empty histogram does not throw")
do
  local th = AutoThresh.derive(build(function() return 0 end), Config.new())
  ok(th.fallback and th.final_db ~= nil, "an empty file falls back cleanly")
  ok(AutoThresh.derive(nil, Config.new()).final_db ~= nil, "so does no histogram")
end

------------------------------------------------------------------- config

section("silence")

-- The step-level histogram the kernel builds during analysis. Shape measured
-- off a real take with stripped pauses: the silence at -79..-72 dBFS, a dead
-- gap of seventeen buckets, then the material from -54 up, continuous.
local function levels(t)
  local counts = {}
  for b = 0, 139 do counts[b] = 0 end
  for db, c in pairs(t) do counts[db + 140] = c end
  return { counts = counts, n = 140, lo = -140, bin = 1 }
end
local function material(counts, lo, hi, n)
  for db = lo, hi do counts.counts[db + 140] = n end
  return counts
end

do
  local h = levels { [-79] = 281, [-77] = 1971, [-75] = 1544, [-74] = 420,
                     [-73] = 44, [-72] = 5 }
  material(h, -54, -9, 120)
  local out = Silence.floor(h)
  ok(out.floor_db ~= nil, "silence: a floor is found")
  ok(out.floor_db and out.floor_db < -55 and out.floor_db > -66,
     "silence: it lands just under the material",
     tostring(out.floor_db))
  ok(out.skipped == 4265, "silence: and counts what it excludes",
     tostring(out.skipped))
  ok(not out.refused, "silence: with no guard tripped")
end

do
  -- A file with no edited silence must be left entirely alone: a floor here
  -- can only throw away real events.
  local h = levels {}
  material(h, -54, -9, 120)
  local out = Silence.floor(h)
  ok(out.floor_db == nil, "continuous material draws no floor",
     tostring(out.floor_db))
  ok(out.skipped == 0, "and nothing is excluded")
end

do
  -- The calibration that took two attempts. A share of the TOTAL scales with
  -- the silence, so on a mostly-silent file it grows until the material's own
  -- sparse mid-range reads as empty and the search walks through it. Measured
  -- at 0.2 %: the floor came out 20 dB too high, in the middle of the speech.
  local h = levels { [-79] = 275, [-77] = 1903, [-75] = 1498, [-74] = 415,
                     [-73] = 41, [-72] = 5 }
  -- material exactly as measured on the 67 %-silent case: thin in the middle
  for _, pair in ipairs({ {-53,2},{-52,12},{-51,39},{-50,41},{-49,18},{-48,12},
                          {-47,12},{-46,2},{-45,5},{-44,7},{-42,5},{-41,6},
                          {-40,2},{-39,6},{-38,4},{-37,6},{-36,6},{-35,9},
                          {-34,8},{-33,14},{-32,17},{-31,14},{-30,5},{-29,4},
                          {-28,15},{-27,12},{-26,13},{-25,17},{-24,54} }) do
    h.counts[pair[1] + 140] = pair[2]
  end
  material(h, -23, -7, 80)
  local out = Silence.floor(h)
  ok(out.floor_db and out.floor_db < -55,
     "a thin mid-range is not mistaken for a second gap",
     tostring(out.floor_db))
end

do
  -- The guard. Almost nothing but silence: there is no distribution left to
  -- read a threshold off, and saying so beats guessing.
  local h = levels { [-79] = 5000 }
  material(h, -54, -50, 4)
  local out = Silence.floor(h)
  ok(out.refused, "a file that is almost all silence is refused")
  ok(out.floor_db == nil, "and no floor is applied")
end

do
  local out = Silence.floor(nil)
  ok(out.floor_db == nil and out.total == 0, "no histogram does not throw")
  local empty = levels {}
  ok(Silence.floor(empty).floor_db == nil, "an empty histogram does not throw")
end

section("config")
do
  local c = Config.new()
  ok(Config.step_samples(c, 48000) == 240, "5 ms at 48 kHz is 240 samples")
  ok(Config.nsteps(c, 48000, 48000) == 202, "one second is 202 steps",
     tostring(Config.nsteps(c, 48000, 48000)))

  -- The split that makes the panel live: sensitivity must not invalidate the
  -- envelope cache, and must not invalidate the surveyed histogram either.
  local a0, d0 = Config.analysis_sig(c), Config.detect_sig(c)
  c.sens_db, c.sens_offset_db = 20, 3
  ok(Config.analysis_sig(c) == a0, "sensitivity does not touch the analysis key")
  ok(Config.detect_sig(c) == d0, "sensitivity does not touch the detect key")
  c.sep = 5
  ok(Config.detect_sig(c) ~= d0, "a detection parameter does move the detect key")
  -- The two post-filters must NOT invalidate the histogram: the survey does
  -- not apply them, so a move cannot change the distribution it describes.
  -- If they ever creep back into DETECT_KEYS the survey gets rebuilt for no
  -- reason -- and, worse, someone may then "fix" that by letting them into the
  -- survey, which empties it of the taper the estimators fit.
  local pf = Config.new()
  local pf0 = Config.detect_sig(pf)
  pf.min_reach_hz = (pf.min_reach_hz or 0) + 1000
  ok(Config.detect_sig(pf) == pf0, "min_reach_hz does not touch the detect key")
  pf.max_event_ms = (pf.max_event_ms or 0) + 10
  ok(Config.detect_sig(pf) == pf0, "nor does max_event_ms")
  ok(Config.analysis_sig(pf) == Config.analysis_sig(Config.new()),
     "and neither touches the analysis key")
  ok(Config.analysis_sig(c) == a0, "but still not the analysis key")
  c.step_ms = 8
  ok(Config.analysis_sig(c) ~= a0, "a step size change invalidates the envelopes")

  -- The band layout has to agree with the kernel's, since the panel labels
  -- bands from here and the kernel selects them from the indices this returns.
  local bc = Config.new()
  bc.flo, bc.fhi, bc.nbands = 150, 9600, 12      -- 0.5 octave per band
  ok(math.abs(Config.band_center(bc, 0) - 150 * 2 ^ 0.25) < 0.5,
     "band 0 centres on the geometric mean of its edges",
     string.format("%.2f", Config.band_center(bc, 0)))
  ok(Config.band_center(bc, 11) > Config.band_center(bc, 0) * 40,
     "and the top band is six octaves up")

  bc.det_lo_hz, bc.det_hi_hz = 150, 9600
  local b0, b1 = Config.band_range(bc)
  ok(b0 == 0 and b1 == 11, "the full span selects every band",
     string.format("%d..%d", b0, b1))

  bc.det_lo_hz, bc.det_hi_hz = 2000, 9600
  b0, b1 = Config.band_range(bc)
  ok(b0 > 0 and b1 == 11, "a raised low edge drops the bottom bands",
     string.format("%d..%d", b0, b1))

  -- The reach test resolves to a band index the same way, and its edges are
  -- what make it safe: above the span must clamp rather than qualify no band,
  -- which would reject every event and look exactly like a clean file.
  bc.min_reach_hz = 0
  ok(Config.reach_band(bc) == -1, "reach 0 is off")
  bc.min_reach_hz = 999999
  ok(Config.reach_band(bc) == bc.nbands - 1,
     "a reach above the analysed span clamps to the top band",
     tostring(Config.reach_band(bc)))
  bc.min_reach_hz = 1
  ok(Config.reach_band(bc) == 0, "and below it clamps to the bottom")
  bc.min_reach_hz = 2400
  local rb = Config.reach_band(bc)
  ok(rb > 0 and rb < bc.nbands - 1 and Config.band_center(bc, rb) > 1500,
     "a reach inside the span lands on a band at about that frequency",
     string.format("band %d = %.0f Hz", rb, Config.band_center(bc, rb)))
  bc.min_reach_hz = nil
  ok(Config.band_center(bc, b0) > 1400,
     "and the first selected band is up where it was asked for",
     string.format("%.0f Hz", Config.band_center(bc, b0)))

  -- A range outside the analysed span must not select nothing: detecting
  -- nothing is indistinguishable from a clean file, which is the worst
  -- possible way for a control to fail.
  bc.det_lo_hz, bc.det_hi_hz = 20000, 30000
  b0, b1 = Config.band_range(bc)
  ok(b0 <= b1 and b1 <= 11, "a range above the span still selects a band",
     string.format("%d..%d", b0, b1))
  bc.det_lo_hz, bc.det_hi_hz = 10, 20
  b0, b1 = Config.band_range(bc)
  ok(b0 <= b1 and b0 >= 0, "so does a range below it",
     string.format("%d..%d", b0, b1))
  bc.det_lo_hz, bc.det_hi_hz = 8000, 500       -- inverted
  b0, b1 = Config.band_range(bc)
  ok(b0 <= b1, "and an inverted range is normalised, not empty",
     string.format("%d..%d", b0, b1))

  -- Changing the band selection must rebuild the surveyed histogram: which
  -- bands take part changes which events exist, so the distribution the
  -- threshold is read off changes with it.
  local d0 = Config.detect_sig(Config.new())
  local dc = Config.new()
  dc.det_lo_hz = 2000
  ok(Config.detect_sig(dc) ~= d0, "the band selection is a detect parameter")
  ok(Config.analysis_sig(dc) == Config.analysis_sig(Config.new()),
     "but not an analysis one -- it must not cost a re-read")

  local big = Config.heap_doubles(Config.new(), 48000, 48000 * 300, 2)
  ok(big * 8 / 1048576 > 30 and big * 8 / 1048576 < 60,
     "five stereo minutes wants tens of MB, as documented",
     string.format("%.1f MB", big * 8 / 1048576))

  local r = Config.new()
  r.crackle_db = -12
  r._scratch = "panel key"
  local same = Config.reset(r)
  ok(same == r, "reset keeps the same table")
  ok(r.crackle_db == Config.defaults.crackle_db, "reset restores a number")
  ok(r.thresh_auto == Config.defaults.thresh_auto, "reset restores a boolean")
  ok(r._scratch == nil, "reset drops keys that are not defaults")
end

section("config: the settings migration")
do
  -- Persistence is the reason a changed default does nothing on an install
  -- that has run once: load() reads ExtState straight back over it. The whole
  -- point of MIGRATIONS is to break that, so it is worth a real ExtState.
  local store
  local stub = {
    SetExtState = function(_, k, v) store[k] = tostring(v) end,
    GetExtState = function(_, k) return store[k] or "" end,
    HasExtState = function(_, k) return store[k] ~= nil end,
    DeleteExtState = function(_, k) store[k] = nil end,
  }
  -- `reaper` is a global here only for the duration of each call, so a stray
  -- reaper reference elsewhere in this suite still fails loudly.
  local saved = reaper
  local function with_stub(fn)
    reaper = stub
    local ok_, res = pcall(fn)
    reaper = saved
    if not ok_ then error(res, 0) end
    return res
  end

  -- An install from before the version key: every setting stored, band keys at
  -- the values that could not see a click above 9.6 kHz.
  store = {}
  local old = Config.new()
  old.fhi, old.nbands, old.det_hi_hz = 9600, 12, 9600
  old.sep, old.max_cut_db = 7, 18          -- tuning we must not touch
  with_stub(function() Config.save(old) end)
  store["__cfg_version"] = nil             -- ...but written by a v1 install

  local cfg = with_stub(function() return Config.load() end)
  ok(cfg.fhi == Config.defaults.fhi,
     "a v1 install picks up the new top of the analysed span",
     tostring(cfg.fhi))
  ok(cfg.nbands == Config.defaults.nbands, "and the new band count")
  ok(cfg.det_hi_hz == Config.defaults.det_hi_hz,
     "and detection listens to the new bands rather than clamping to 9.6 kHz")
  ok(cfg.sep == 7 and cfg.max_cut_db == 18,
     "while settings whose default did not move are kept")
  ok(Config.migrated and #Config.migrated == 3,
     "and the panel is told which keys moved",
     Config.migrated and tostring(#Config.migrated) or "nil")

  -- Idempotent: the second load must not fight the user.
  cfg.fhi = 12000
  with_stub(function() Config.save(cfg) end)
  local again = with_stub(function() return Config.load() end)
  ok(again.fhi == 12000, "a later deliberate change survives the next load",
     tostring(again.fhi))
  ok(#Config.migrated == 0, "and the migration does not run twice")
end

---------------------------------------------------------------------- log

section("log")
do
  local function ncols(s)
    local n, inq = 1, false
    for i = 1, #s do
      local ch = s:sub(i, i)
      if ch == '"' then inq = not inq
      elseif ch == "," and not inq then n = n + 1 end
    end
    return n
  end
  ok(ncols(Log.header()) == #Log.COLUMNS, "the header has one field per column")

  local rec = {
    time = "2026-08-25 12:00:00", name = 'vox, "take 3"', rate = 48000,
    seconds = 12.5, channels = 2, mode = "repair", elapsed = 1.25,
    cfg = Config.new(),
    th = { tail_db = 21.5, knee_db = 18.25, derived_db = 21.5, sens_used = 21.5,
           retries = 0, stats = { events = 143, repaired = 0.0012 } },
  }
  local row = Log.row(rec)
  ok(ncols(row) == #Log.COLUMNS, "a row has one field per column",
     string.format("%d vs %d", ncols(row), #Log.COLUMNS))
  ok(row:find('"vox, ""take 3"""', 1, true),
     "commas and quotes in a take name are escaped")
  ok(row:find("143", 1, true), "the event count is in there")

  -- A row with nothing measured must still be a well-formed row: a skipped or
  -- failed item is exactly the one you want to find in the log later.
  ok(ncols(Log.row({})) == #Log.COLUMNS, "an empty record still yields a row")
end

---------------------------------------------------------------------- wav

section("wav")
do
  local path = os.tmpname() .. ".wav"
  local w = assert(Wav.create(path, 2, 48000))
  local samples = { 0, 0.5, -0.5, 1, -1, 0.25 }
  w:write(samples, 1, #samples)
  w:close()

  local fh = assert(io.open(path, "rb"))
  local data = fh:read("a")
  fh:close()
  os.remove(path)

  ok(data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE", "it is a RIFF WAVE")
  local fmt, nch, rate = string.unpack("<I2I2I4", data, 21)
  ok(fmt == 3, "format tag is IEEE float")
  ok(nch == 2, "channel count round-trips")
  ok(rate == 48000, "sample rate round-trips")
  local riff = string.unpack("<I4", data, 5)
  local dlen = string.unpack("<I4", data, 41)
  ok(dlen == #samples * 4, "the data chunk length was patched on close")
  ok(riff == 36 + dlen, "the RIFF size agrees with it")
  for i, want in ipairs(samples) do
    local got = string.unpack("<f", data, 45 + (i - 1) * 4)
    ok(got == want, "sample " .. i .. " round-trips")
  end
  ok(not Wav.will_overflow(48000 * 600, 2), "ten stereo minutes is under 4 GB")
  ok(Wav.will_overflow(48000 * 60 * 400, 2), "and 400 minutes is not")
end

---------------------------------------------------------------------- panel

-- The panel cannot be run for real without a context and a defer loop, but a
-- frame rendered against a stub still catches every Lua error inside it -- and
-- that is how it has actually broken.
section("panel")
do
  local UIFrame = require "ui_frame"
  local UI = require "dc.ui"

  local function populated(ST, _)
    ST.k = UIFrame.stub_kernel()
    ST.analysed = true
    ST.geo = { rate = 48000, nchan = 2, acc_len = 12.5, item_len = 12.5,
               playrate = 1, total_samples = 600000, item = {} }
    ST.dirty = true          -- forces recompute() through the real Detect path
  end

  for _, case in ipairs({
    { name = "empty",     prep = nil,       changed = false },
    { name = "populated", prep = populated, changed = false },
    -- The one that matters: every control reports that it was moved, so each
    -- callback behind it actually runs. With the controls quiet, the bug that
    -- killed the panel on every slider was completely invisible here.
    { name = "empty, all controls moved",     prep = nil,       changed = true },
    { name = "populated, all controls moved", prep = populated, changed = true },
  }) do
    local good, err, log = UIFrame.run(UI, "./", case.prep, {}, case.changed)
    ok(good, "the frame renders: " .. case.name, tostring(err))
    -- An unbalanced disabled stack is what turns a small error into a dead
    -- panel: ImGui.End raises over the top of it and the defer loop stops.
    ok(log.dis == 0, "disabled stack balances: " .. case.name,
       "depth " .. tostring(log.dis))
    ok(log.push == log.pop, "style stack balances: " .. case.name,
       string.format("%d pushed, %d popped", log.push, log.pop))
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
-- Guarded: this file is pure Lua, but with no system `lua` on the machine it
-- runs inside REAPER, whose embedded Lua has no os.exit. Unguarded, a failing
-- run would die on the reporting line instead of reporting.
if os.exit then os.exit(fail == 0 and 0 or 1) end
