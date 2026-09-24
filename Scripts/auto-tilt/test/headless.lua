-- AutoTilt -- the pure stages, plus one panel frame against a stub ImGui.
--
-- No audio, no accessor, no EEL. Everything here is a function of numbers, and
-- most of it has an analytically known answer -- which is the point: the
-- measurement's neutral point and the shelf pair's asymptotes are claims that
-- can be checked exactly rather than eyeballed on a spectrum analyser.
--
-- There is no system lua on this machine, so this runs inside the already
-- running REAPER via tools/run_tests.py. That is why the os.exit call is
-- guarded: REAPER's embedded Lua has no os.exit, and unguarded this file would
-- die on its own reporting line when run from the Actions list.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local dir = src:match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;" .. package.path

local Config   = require "at.config"
local Spectrum = require "at.spectrum"
local Solve    = require "at.solve"
local Select    = require "at.select"
local Trackpick = require "at.trackpick"

local pass, fail = 0, 0

local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL  %s%s", name, extra and ("  -- " .. extra) or ""))
  end
end

local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %s", tostring(a), tostring(b)))
end

-- Anything that stops the run counts as a failure, not as "nothing to check".
local function bail(msg)
  fail = fail + 1
  print("FAIL  " .. msg)
end

local function section(s) print("-- " .. s) end

local RATE, N = 48000, 4096

local function spec_from(psd)
  local s = {}
  for k = 0, N // 2 do s[k] = (k == 0) and 0 or psd(k * RATE / N) end
  return s
end

local pink  = spec_from(function(f) return 1 / f end)
local white = spec_from(function(f) return 1 end)
local brown = spec_from(function(f) return 1 / (f * f) end)

---------------------------------------------------------------- the ratio ----
section("the balance figure")
do
  local cfg = Config.new()
  local b = Spectrum.band(cfg, RATE, N)
  ok(not b.degenerate, "the default band is usable", b.degenerate)

  -- The neutral point. Energy per octave, so pink -- equal energy per octave
  -- by definition -- has to read zero, and it is worth an exact assertion
  -- because getting this backwards tilts every number the script reports.
  near(Spectrum.ratio(pink, b), 0, 0.01, "pink reads 0.00 dB")
  local rw = Spectrum.ratio(white, b)
  local rb = Spectrum.ratio(brown, b)
  ok(rw > 11 and rw < 13, "white reads about +12 dB", tostring(rw))
  ok(rb > -13 and rb < -11, "-6 dB/oct reads about -12 dB", tostring(rb))
  -- White and -6 dB/oct are mirror images about pink, but only when the band
  -- is geometrically symmetric about the pivot. 80-16000 around 1 kHz is not
  -- (80*16000 = 1.28e6, not 1e6), so it is worth pinning on a band that is.
  do
    local sym = Config.new()
    sym.band_lo_hz, sym.band_hi_hz, sym.pivot_hz = 250, 4000, 1000
    local bs = Spectrum.band(sym, RATE, N)
    near(Spectrum.ratio(white, bs) + Spectrum.ratio(brown, bs), 0, 0.05,
         "white and -6 dB/oct mirror about pink on a symmetric band")
    near(Spectrum.ratio(pink, bs), 0, 0.02, "and pink still reads 0.00 there")
  end

  -- Moving the band edges must not move the reading, or a captured fixed
  -- reference would only be meaningful at the settings it was captured under.
  for _, e in ipairs({ { 80, 16000 }, { 100, 12000 }, { 60, 18000 }, { 120, 10000 } }) do
    cfg.band_lo_hz, cfg.band_hi_hz = e[1], e[2]
    local bb = Spectrum.band(cfg, RATE, N)
    near(Spectrum.ratio(pink, bb), 0, 0.02,
         string.format("pink still reads 0.00 at %d-%d Hz", e[1], e[2]))
  end
  cfg.band_lo_hz, cfg.band_hi_hz = 80, 16000

  -- And the pivot must not either, for pink.
  for _, hz in ipairs({ 300, 700, 1000, 2000, 5000 }) do
    cfg.pivot_hz = hz
    local bb = Spectrum.band(cfg, RATE, N)
    near(Spectrum.ratio(pink, bb), 0, 0.02,
         string.format("pink still reads 0.00 with the pivot at %d Hz", hz))
  end
  cfg.pivot_hz = 1000

  -- Out-of-band energy must be excluded, or rumble and hiss would move the
  -- number for reasons nobody can hear.
  local rumbly = spec_from(function(f) return 1 / f end)
  for k = 1, N // 2 do
    local f = k * RATE / N
    if f < 60 then rumbly[k] = rumbly[k] * 10000 end
  end
  local b2 = Spectrum.band(cfg, RATE, N)
  near(Spectrum.ratio(rumbly, b2), Spectrum.ratio(pink, b2), 0.001,
       "40 dB of sub-60 Hz rumble does not move the reading")

  -- A pivot dragged onto the edge is refused by name rather than dividing by
  -- zero and reporting inf.
  cfg.pivot_hz = 80
  local bd = Spectrum.band(cfg, RATE, N)
  ok(bd.degenerate ~= nil, "a pivot on the band edge is refused by name")
  ok(Spectrum.ratio(pink, bd) == nil, "and yields no ratio rather than inf")
  cfg.pivot_hz = 1000
end

------------------------------------------------------------------ the gate ----
section("the gate")
do
  local cfg = Config.new()
  local nbins, nlev = 65, Config.NLEV
  local rows, counts = {}, {}
  for lev = 0, nlev - 1 do counts[lev] = 0 end
  -- A cube row is the SUM of the frames in its bucket, not one frame's
  -- spectrum, so the fixture builds it the way the kernel does.
  local function flat(per_frame, nframes)
    local r = {}
    for k = 1, nbins do r[k] = per_frame * nframes end
    return r
  end
  -- 100 loud frames at bucket 100, 300 quiet ones 50 dB down.
  rows[100], counts[100] = flat(1.0, 100), 100
  rows[50],  counts[50]  = flat(1e-5, 300), 300

  local ana = Spectrum.build(rows, counts, nbins, nlev, Config.LEV0)
  ok(ana.frames == 400, "build counts every frame", tostring(ana.frames))
  ok(ana.lev_min == 50 and ana.lev_max == 100, "and finds the occupied range")

  -- Taken from the top, so three quarters of the clip being silence does not
  -- drag the loud reference down into it.
  ok(Spectrum.loud_level(ana, 95) == 100,
     "the loud level is the loud bucket even at 75% silence")

  cfg.gate_db = 30
  local g = Spectrum.gate_level(ana, cfg)
  ok(g == 70, "the gate sits 30 dB below it", tostring(g))
  local _, kept = Spectrum.gated(ana, cfg)
  ok(kept == 100, "and keeps only the loud frames", tostring(kept))

  cfg.gate_db = 60
  local _, kept2 = Spectrum.gated(ana, cfg)
  ok(kept2 == 400, "a deep enough gate keeps everything", tostring(kept2))

  -- The cumulative rows must be sums, not means: two buckets gated in together
  -- have to give the power sum of both.
  cfg.gate_db = 60
  local spec = Spectrum.gated(ana, cfg)
  near(spec[1], (100 * 1.0 + 300 * 1e-5) / 400, 1e-12,
       "gating in both buckets gives their mean power")
end

------------------------------------------------------------- the shelf pair ----
section("the shelf pair")
do
  local cfg = Config.new()
  for _, G in ipairs({ -11, -8, -3, 0, 1.5, 4.5, 11 }) do
    local lo, hi = Solve.pair(cfg, RATE, G)
    local at_piv = 10 * math.log(Solve.pair_response_sq(lo, hi, cfg.pivot_hz, RATE), 10)
    local at_lo  = 10 * math.log(Solve.pair_response_sq(lo, hi, 20, RATE), 10)
    local at_hi  = 10 * math.log(Solve.pair_response_sq(lo, hi, 20000, RATE), 10)
    near(at_piv, 0, 1e-9, string.format("G=%+.1f is unity at the pivot", G))
    near(at_lo, -G / 2, 0.25, string.format("G=%+.1f asymptotes to -G/2", G))
    near(at_hi,  G / 2, 0.25, string.format("G=%+.1f asymptotes to +G/2", G))
    near(at_hi - at_lo, G, 0.5, string.format("G=%+.1f spans G dB overall", G))
  end

  -- G = 0 has to be a pass-through coefficient for coefficient, not merely a
  -- quiet filter: that is what makes the render a bit-exact null.
  local lo0, hi0 = Solve.pair(cfg, RATE, 0)
  ok(lo0[1] == 1 and lo0[2] == lo0[4] and lo0[3] == lo0[5],
     "G=0: the low shelf is an exact pass-through")
  ok(hi0[1] == 1 and hi0[2] == hi0[4] and hi0[3] == hi0[5],
     "G=0: the high shelf is an exact pass-through")

  -- A pivot past Nyquist has no filter to design and must do nothing.
  local lon = Solve.shelf("low", 30000, RATE, 6, 0.7)
  ok(lon[1] == 1 and lon[2] == 0 and lon[3] == 0, "a pivot past Nyquist is inert")
end

----------------------------------------------------------------- the solve ----
section("the solve")
do
  local cfg = Config.new()
  local b = Spectrum.band(cfg, RATE, N)

  local prev = -math.huge
  local mono = true
  for G = -12, 12, 0.25 do
    local r = Solve.ratio_after(pink, cfg, RATE, b, G)
    if not (r > prev) then mono = false end
    prev = r
  end
  ok(mono, "the ratio is strictly increasing in the gain")

  -- The round trip: pre-tilt a spectrum by a known amount and the solver has
  -- to hand back exactly its negation.
  for _, want in ipairs({ -9, -6, -2.5, 0, 1.75, 7, 10 }) do
    local c = Solve.curve(cfg, RATE, b, want)
    local tilted = {}
    for k = b.lo, b.hi do tilted[k] = pink[k] * c[k] end
    local r = Solve.solve(tilted, cfg, RATE, b, Spectrum.ratio(pink, b))
    ok(not r.clamped and math.abs(r.gain + want) < 0.02,
       string.format("solve undoes a pre-tilt of %+.2f dB", want),
       string.format("got %+.4f", r.gain))
  end

  -- It also has to work between two genuinely different spectra, not just a
  -- spectrum against itself.
  -- Not brown: pink to -6 dB/oct is an 11.4 dB difference, and because a
  -- shelf pair moves the balance by less than its own gain that needs more
  -- than the 12 dB limit. -3.9 dB/oct is a realistic gap between two mics.
  local dull = spec_from(function(f) return f ^ -1.3 end)
  local target_ratio = Spectrum.ratio(dull, b)
  local r = Solve.solve(pink, cfg, RATE, b, target_ratio)
  ok(not r.clamped, "pink can be matched to a duller spectrum inside the limit",
     string.format("target %.2f dB, gain %.2f", target_ratio, r.gain or 0/0))
  near(Solve.ratio_after(pink, cfg, RATE, b, r.gain), target_ratio, 0.01,
       "and the solved gain actually lands on it")

  -- The reason the gain is SOLVED and not simply set to the difference: a
  -- shelf pair only reaches its full +-G/2 far from the pivot, so a tilt of G
  -- moves the measured balance by rather less than G. Setting gain = delta
  -- would undershoot every time, by an amount that varies with the material.
  local base = Solve.ratio_after(pink, cfg, RATE, b, 0)
  for _, G in ipairs({ 3, 6, 9, 12 }) do
    local moved = Solve.ratio_after(pink, cfg, RATE, b, G) - base
    ok(moved < G, string.format("a tilt of %d dB moves the balance by less", G),
       string.format("moved %.3f", moved))
    ok(moved > G * 0.5, string.format("but by more than half of it (%d dB)", G),
       string.format("moved %.3f", moved))
  end

  -- Clamping is reported rather than passed off as an answer.
  local rc = Solve.solve(pink, cfg, RATE, b, 99)
  ok(rc.clamped and rc.gain == cfg.max_gain, "an unreachable target clamps and says so")
  local rc2 = Solve.solve(pink, cfg, RATE, b, -99)
  ok(rc2.clamped and rc2.gain == -cfg.max_gain, "and in the other direction")

  -- Level compensation.
  cfg.compensate_level = true
  ok(Solve.makeup(pink, cfg, RATE, b, 0) == 1, "makeup is exactly 1 at G=0")
  ok(Solve.makeup(pink, cfg, RATE, b, 6) ~= 1, "and not 1 for a real tilt")
  cfg.compensate_level = false
  ok(Solve.makeup(pink, cfg, RATE, b, 6) == 1, "and it is 1 when switched off")
  cfg.compensate_level = true

  -- The invariant that actually matters, in both directions and on spectra
  -- with the energy at opposite ends: after the tilt AND the makeup gain, the
  -- in-band power is where it started.
  for _, spec in ipairs({ pink, white, brown }) do
    for _, G in ipairs({ -9, -4, 4, 9 }) do
      local mk = Solve.makeup(spec, cfg, RATE, b, G)
      local before = Spectrum.band_power(spec, b)
      local after  = Spectrum.band_power(spec, b, Solve.curve(cfg, RATE, b, G))
      near(after * mk * mk, before, before * 1e-9,
           string.format("makeup holds the in-band power at %+d dB", G))
    end
  end
end

------------------------------------------------------- the parameter classes ----
section("parameter classes")
do
  local cfg = Config.new()
  local abase = Config.analysis_sig(cfg)
  local mbase = Config.measure_sig(cfg)

  for _, key in ipairs(Config.MEASURE_KEYS) do
    local save = cfg[key]
    cfg[key] = save + 1
    ok(Config.analysis_sig(cfg) == abase, key .. " does not force a re-read")
    ok(Config.measure_sig(cfg) ~= mbase, key .. " does force a re-measure")
    cfg[key] = save
  end
  for _, key in ipairs(Config.SOLVE_KEYS) do
    local save = cfg[key]
    -- Written as `(type(save) == "boolean") and not save or (save + 1)` this
    -- falls through to the arithmetic whenever the flag is already true, which
    -- is the and/or idiom's one sharp edge.
    if type(save) == "boolean" then cfg[key] = not save else cfg[key] = save + 1 end
    ok(Config.analysis_sig(cfg) == abase, key .. " does not force a re-read")
    ok(Config.measure_sig(cfg) == mbase, key .. " does not force a re-measure")
    cfg[key] = save
  end
  for _, key in ipairs(Config.OUTPUT_KEYS) do
    local save = cfg[key]
    cfg[key] = not save
    ok(Config.analysis_sig(cfg) == abase, key .. " does not force a re-read")
    ok(Config.measure_sig(cfg) == mbase, key .. " does not force a re-measure")
    cfg[key] = save
  end
  -- Perturb by type: the track-role keys are strings, so `save + 1` would raise rather than
  -- test anything. What matters is that ANY change to an analysis key changes the signature.
  for _, key in ipairs(Config.ANALYSIS_KEYS) do
    local save = cfg[key]
    cfg[key] = (type(save) == "number") and (save + 1) or (tostring(save) .. "-changed")
    ok(Config.analysis_sig(cfg) ~= abase, key .. " DOES force a re-read")
    cfg[key] = save
  end

  -- The FFT size is forced to a power of two, because the kernel's radix-2
  -- transform has no other option and a silently wrong size would come back as
  -- a wrong spectrum rather than an error.
  for _, e in ipairs({ { 4096, 4096 }, { 3000, 4096 }, { 1025, 2048 },
                       { 100, 256 }, { 99999, 16384 } }) do
    cfg.fft_size = e[1]
    ok(Config.fft_size(cfg) == e[2],
       string.format("fft_size %d rounds to %d", e[1], e[2]),
       tostring(Config.fft_size(cfg)))
  end
  cfg.fft_size = 4096
  cfg.ana_hop = 99999
  ok(Config.hop(cfg) == 4096, "the hop is clamped to the window")
end

------------------------------------------------------------------ the panel ----
section("the panel")
do
  local okr, Frame = pcall(require, "ui_frame")
  local oku, UI = pcall(require, "at.ui")
  if not okr then bail("test/ui_frame.lua did not load: " .. tostring(Frame))
  elseif not oku then bail("at/ui.lua did not load: " .. tostring(UI))
  else
    -- The `changed` pass reports every control as edited, and the panel persists on edit, so
    -- without this a run would leave a stub track GUID saved as the user's real role.
    local saved_roles = reaper and Frame.snapshot_roles(Config, Config.EXT_SECTION)
    local function populated(ST, cfg)
      cfg.fft_size, cfg.ana_hop = 256, 64
      ST.k = { fft_size = 256, nbins = 129 }
      ST.ana = {
        geo = { rate = 48000, nchan = 1, item_len = 4, rate_known = true },
        target = Frame.stub_ana(256, 48000, -5, 200, 90),
        ref    = Frame.stub_ana(256, 48000, -1, 180, 92),
      }
      ST.cache_key = "x"
      ST.sel = { target = {}, refs = {} }
    end

    local states = {
      { "empty",              nil },
      { "populated",          populated },
      { "populated, no ref",  function(ST, cfg)
          populated(ST, cfg) ST.ana.ref = nil end },
      { "busy",               function(ST, cfg)
          populated(ST, cfg) ST.job = coroutine.create(function() end)
          ST.jobkind, ST.progress = "Analysing", 0.4 end },
      { "error",              function(ST, cfg)
          populated(ST, cfg) ST.err = "something went wrong"
          ST.note = "a note" end },
      { "manual gain",        function(ST, cfg)
          populated(ST, cfg) ST.manual = 3.25 end },
    }

    for _, st in ipairs(states) do
      for _, moved in ipairs({ false, true }) do
        local label = st[1] .. (moved and ", every control moved" or ", quiet")
        local ran, err, log = Frame.run(UI, root, st[2], {}, moved)
        ok(ran, "renders: " .. label, tostring(err))
        ok(log.dis == 0, "disabled stack balances: " .. label, tostring(log.dis))
        ok(log.push == log.pop, "style stack balances: " .. label)
      end
    end
    if saved_roles then Frame.restore_roles(saved_roles, Config.EXT_SECTION) end

    -- Every cfg key a control names must exist, or a rename would leave a
    -- slider silently reading nil until someone touched it.
    local fh = io.open(root .. "at/ui.lua", "rb")
    if not fh then bail("could not read at/ui.lua for the coverage scan")
    else
      local text = fh:read("a")
      fh:close()
      local seen = {}
      -- A track role is three settings behind ONE control, so the grep above cannot see them:
      -- Trackpick.widget is handed a prefix, not a key. Expand the roles the select module
      -- declares, and assert the panel actually draws them -- otherwise this would quietly
      -- excuse a picker that had been deleted.
      ok(text:find("Trackpick.widget", 1, true) ~= nil, "the panel draws the track pickers")
      for _, prefix in ipairs(Select.ROLES) do
        ok(text:find('"' .. prefix .. '"', 1, true) ~= nil,
           "the panel names the " .. prefix .. " role")
        for _, key in ipairs(Trackpick.sig_keys(prefix)) do
          seen[key] = true
          ok(Config.defaults[key] ~= nil,
             string.format("role key %q is a real config key", key))
        end
      end
      -- [%w_] rather than %w for the function name: %w excludes the
      -- underscore, so input_double scanned as "double" and the ^input filter
      -- below silently skipped both text fields.
      for fn, key in text:gmatch('([%w_]+)%("[^"]*",%s*"([%w_]+)"') do
        if fn:match("slider$") or fn == "checkbox" or fn:match("^input") then
          seen[key] = true
          ok(Config.defaults[key] ~= nil,
             string.format("control %s(\"%s\") names a real config key", fn, key))
        end
      end
      local missing = {}
      for key in pairs(Config.defaults) do
        if not seen[key] then missing[#missing + 1] = key end
      end
      table.sort(missing)
      ok(#missing == 0, "every setting has a control",
         "no control for: " .. table.concat(missing, ", "))
    end
  end
end

------------------------------------------------------------------ track roles

do
  -- find() is pure: it takes the track list rather than asking REAPER for it, which is what
  -- makes the resolution order testable at all.
  local tracks = {
    { name = "Vox",     guid = "{A}", num = 1 },
    { name = "Ref Vox", guid = "{B}", num = 2 },
  }
  ok(Trackpick.find(tracks, "", "{B}", "").guid == "{B}", "found by guid")
  ok(Trackpick.find(tracks, "", "", "Vox").guid == "{A}", "found by remembered name")
  ok(Trackpick.find(tracks, "Ref Vox", "{A}", "Vox").guid == "{B}",
     "a typed name overrides the remembered guid")
  ok(Trackpick.find(tracks, "REF VOX", "", "").guid == "{B}", "name match ignores case")
  ok(Trackpick.find(tracks, "", "{gone}", "") == nil, "a stale guid resolves to nothing")

  -- A typed name matching nothing must be an ERROR rather than a quiet fall-back to the guid:
  -- falling back would tilt the wrong track and say nothing.
  local t, err = Trackpick.find(tracks, "Nope", "{A}", "Vox")
  ok(t == nil and err ~= nil, "a typed name matching nothing is an error, not a fallback")

  -- Both halves of why all three are stored.
  ok(Trackpick.find({ { name = "Vox 2", guid = "{A}", num = 1 } }, "", "{A}", "Vox").guid == "{A}",
     "guid survives a rename")
  ok(Trackpick.find({ { name = "Vox", guid = "{NEW}", num = 1 } }, "", "{A}", "Vox").guid == "{NEW}",
     "name survives the track being rebuilt with a new guid")

  local c = Config.new()
  ok(not Trackpick.is_set(c, "target"), "a fresh config has no target role set")
  c.target_guid = "{A}"
  ok(Trackpick.is_set(c, "target"), "a guid counts as set")
  Trackpick.clear(c, "target")
  ok(not Trackpick.is_set(c, "target"), "clear() unsets all three")

  ok(#Select.ROLES == 2, "two roles: target and reference")
end

print(string.format("\nheadless: %d passed, %d failed", pass, fail))
-- The tally has to reach the exit code, or a CI job or an && chain reads a
-- suite that printed FAIL as green. Run from the Actions list this is a no-op:
-- REAPER's Lua has no os.exit, so the call is simply absent.
if os.exit then os.exit(fail == 0 and 0 or 1) end
