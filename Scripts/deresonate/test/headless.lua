-- Pure-Lua suite. Requires only the stages that import no `reaper`.
-- Run:  python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/headless.lua
-- REAPER's embedded Lua stands in for the missing system interpreter.

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;" .. package.path

local pass, fail = 0, 0
local function section(s) print("\n-- " .. s) end
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function near(a, b, tol, name)
  local good = a and b and math.abs(a - b) <= tol
  ok(good, name, good and nil or string.format("%s vs %s, tol %s", tostring(a), tostring(b), tostring(tol)))
end
-- anything that stops the run is a FAILURE, never a skip
local function bail(msg) fail = fail + 1; print("  FAIL " .. msg) end

local Config   = require "dr.config"
local Spectrum = require "dr.spectrum"
local Mask     = require "dr.mask"
local Ring     = require "dr.ring"
local Broad    = require "dr.broad"
local Detect   = require "dr.detect"

--------------------------------------------------------------------- config
section("config")
do
  local c = Config.new()
  ok(c.fft_size == 2048, "defaults load")
  near(Config.bin_hz(c), 1.953125, 1e-6, "bin spacing is 1.95 Hz at 4 kHz / 2048")
  near(Config.window_ms(c), 512.0, 1e-6, "window is 512 ms")
  ok(Config.latency(c) == 0, "latency is 0 with dereverb off (biquads add none)")
  c.dereverb_on = true
  ok(Config.latency(c) == c.rfft_size, "latency is one FFT with dereverb on")
  c.dereverb_on = false

  -- the parameter-class split is the whole invalidation scheme; assert it
  for _, k in ipairs(Config.DETECT_KEYS) do
    local a0, d0 = Config.analysis_sig(c), Config.detect_sig(c)
    local old = c[k]
    c[k] = (type(old) == "number") and (old + 1) or (not old)
    ok(Config.analysis_sig(c) == a0, "detect key '" .. k .. "' does not force a re-read")
    ok(Config.detect_sig(c) ~= d0, "detect key '" .. k .. "' does invalidate detection")
    c[k] = old
  end
  for _, k in ipairs(Config.OUTPUT_KEYS) do
    local a0, d0 = Config.analysis_sig(c), Config.detect_sig(c)
    local old = c[k]; c[k] = not old
    ok(Config.analysis_sig(c) == a0 and Config.detect_sig(c) == d0,
       "output key '" .. k .. "' invalidates nothing")
    c[k] = old
  end

  local n = 0; for _ in pairs(c) do n = n + 1 end
  c.stray = 7; c.fft_size = 4096
  Config.reset(c)
  local n2 = 0; for _ in pairs(c) do n2 = n2 + 1 end
  ok(c.stray == nil and c.fft_size == 2048 and n2 == n, "reset restores in place and drops strays")
end

------------------------------------------------------------------- spectrum
section("spectrum")
do
  local lev0 = -140
  local h = {}
  for i = 1, 130 do h[i] = 0 end
  -- 100 frames all at exactly -60 dB  -> bucket index -60-(-140)+1 = 81
  h[81] = 100
  near(Spectrum.percentile(h, 0.5, lev0), -60.0, 0.01,
     "a single occupied bucket returns its centre")
  local h2 = {}
  for i = 1, 130 do h2[i] = 0 end
  h2[41] = 50   -- -100 dB
  h2[81] = 50   -- -60 dB
  local p20 = Spectrum.percentile(h2, 0.2, lev0)
  local p90 = Spectrum.percentile(h2, 0.9, lev0)
  ok(p20 < -95 and p90 > -65, "percentile separates a bimodal distribution", p20 .. "/" .. p90)

  -- Silence islands ---------------------------------------------------------
  -- The failure these guard against is silent: a percentile taken over a file
  -- that is mostly edited silence lands INSIDE the silence, at every frequency
  -- at once, and every detector downstream measures a curve against a smoothed
  -- copy of itself -- so a flat curve finds nothing and reports nothing wrong.
  local function hist_of(t)
    local h = {}
    for i = 1, 160 do h[i] = 0 end
    for db, c in pairs(t) do h[db - lev0 + 1] = c end
    return h
  end

  do
    -- 28% of frames are dithered digital silence at the bottom of the axis,
    -- then a 20 dB dead gap, then the recording. Shape measured off a real
    -- take whose pauses had been stripped.
    local h = hist_of { [-140] = 280 }
    for db = -95, -40 do h[db - lev0 + 1] = 18 end      -- 1008 real frames
    local from, kept, refused = Spectrum.floor_bin(h)
    ok(lev0 + from - 1 >= -96 and lev0 + from - 1 <= -94,
       "island: the floor steps over the dithered silence",
       tostring(lev0 + from - 1))
    ok(kept == 1008, "island: and keeps every real frame", tostring(kept))
    ok(not refused, "island: with no guard tripped")
    local p20 = Spectrum.percentile(h, 0.2, lev0, kept, from)
    ok(p20 > -90, "island: p20 is now inside the recording", string.format("%.1f", p20))
    -- the number that made this worth finding
    local raw = Spectrum.percentile(h, 0.2, lev0)
    ok(raw < -130, "island: and was pinned to the axis before",
       string.format("%.1f", raw))
  end

  do
    -- The guard. A bin whose own content is bimodal -- loud whenever a
    -- harmonic sweeps through it, at the floor otherwise -- looks exactly like
    -- an island from below, and stepping over its lower mode would RAISE the
    -- percentile into the signal and manufacture a peak where there is none.
    local h = hist_of {}
    for db = -100, -90 do h[db - lev0 + 1] = 60 end     -- 660 frames, the floor
    for db = -55, -45 do h[db - lev0 + 1] = 30 end      -- 330 frames, the tone
    local from, _, refused = Spectrum.floor_bin(h)
    ok(from == 1 or lev0 + from - 1 <= -100,
       "bimodal: the lower mode is NOT stepped over",
       tostring(lev0 + from - 1))
    ok(refused, "bimodal: and the refusal is reported")
  end

  do
    -- Every histogram ends in empty buckets: the level axis reaches above full
    -- scale, so there is always a long dead run over the loudest frame. That
    -- is the end of the distribution, not a gap in it -- and reading it as one
    -- made every bin of every file report a refusal.
    local h = hist_of {}
    for db = -80, -50 do h[db - lev0 + 1] = 40 end
    local from, kept, refused = Spectrum.floor_bin(h)
    ok(lev0 + from - 1 == -80, "clean: the floor is the first real bucket",
       tostring(lev0 + from - 1))
    ok(kept == 40 * 31, "clean: nothing is dropped", tostring(kept))
    ok(not refused, "clean: and nothing is reported as refused")
  end

  do
    -- Within the programme material the widest empty run measured on real
    -- per-bin histograms was 6 buckets; the gap over an island was 27-30. A
    -- 6-bucket hole must not read as a gap, or the floor walks into the signal.
    local h = hist_of {}
    for db = -90, -70 do h[db - lev0 + 1] = 30 end
    for db = -63, -40 do h[db - lev0 + 1] = 30 end      -- a 6 dB hole at -69..-64
    local from = Spectrum.floor_bin(h)
    ok(lev0 + from - 1 == -90, "a 6 dB hole inside the material is not a gap",
       tostring(lev0 + from - 1))
  end

  do
    -- floor_bins over a cube, and the opt-out.
    local cube = {}
    for k = 1, 8 do
      local h = hist_of { [-140] = 200 }
      for db = -85, -50 do h[db - lev0 + 1] = 20 end
      cube[k] = h
    end
    local f = Spectrum.floor_bins(cube, true)
    ok(f.skipped_frac > 0.15 and f.skipped_frac < 0.30,
       "floor_bins reports how much it stepped over",
       string.format("%.2f", f.skipped_frac))
    ok(f.refused_bins == 0, "floor_bins reports no refusals here")
    local off = Spectrum.floor_bins(cube, false)
    ok(off.from[1] == 1 and off.skipped_frac == 0,
       "floor_bins disabled steps over nothing")
    -- curve() must not be able to reach the unguarded statistic by accident
    local guarded = Spectrum.curve(cube, 0.2, lev0)
    ok(guarded[1] > -100, "curve() guards by default, with no floors passed",
       string.format("%.1f", guarded[1]))
  end

  local hz = Spectrum.hz_axis(1024, 1.953125)
  ok(hz[1] > 0, "bin 0 is never on the axis -- DC is an offset, not a tone")
  near(hz[512], 1000.0, 0.01, "axis reaches 1000 Hz at bin 512")

  -- a flat curve must survive both smoothers untouched
  local flat = {}
  for i = 1, #hz do flat[i] = -70.0 end
  local sp = Spectrum.smooth_power(flat, hz, 1 / 3)
  local sd = Spectrum.smooth_db(flat, hz, 2.0)
  near(sp[400], -70.0, 1e-9, "power smoothing of a constant is a no-op")
  near(sd[400], -70.0, 1e-9, "dB smoothing of a constant is a no-op")

  -- the two means differ where it matters: on a single loud point the power
  -- mean rides up and the dB mean does not
  local spike = {}
  for i = 1, #hz do spike[i] = -70.0 end
  spike[400] = -40.0
  local ps = Spectrum.smooth_power(spike, hz, 1.0)
  local ds = Spectrum.smooth_db(spike, hz, 1.0)
  ok(ps[400] > ds[400] + 3.0,
     "power mean is pulled by a spike, dB mean is not (why the baseline uses dB)",
     string.format("%.1f vs %.1f", ps[400], ds[400]))
end

----------------------------------------------------------------------- mask
section("mask")
do
  local cfg = Config.new()
  local hz = Spectrum.hz_axis(1024, 1.953125)
  local out = {}
  Mask.stamp(out, 200.0, hz, 70, 2000.0)
  local function marked(f)
    local i = Spectrum.index_of(hz, f); return out[i] and true or false
  end
  ok(marked(200) and marked(400) and marked(600) and marked(1000),
     "the whole harmonic series is stamped, not just F0")
  ok(not marked(300) and not marked(510),
     "frequencies between harmonics are left clear")

  -- occupancy over a synthetic frame table
  local F = { n = 200, f0 = {}, aper = {}, level_db = {} }
  for i = 1, F.n do
    F.f0[i] = 200.0; F.aper[i] = 0.05; F.level_db[i] = -20.0
  end
  local occ = Mask.occupancy(F, hz, cfg)
  near(occ[Spectrum.index_of(hz, 400)], 1.0, 1e-9, "occupancy is 1.0 on a constantly-sung harmonic")
  near(occ[Spectrum.index_of(hz, 310)], 0.0, 1e-9, "occupancy is 0.0 away from the series")
end

----------------------------------------------------------------------- ring
section("ring")
do
  local cfg = Config.new()
  local dt = 0.008
  local n = 20000
  -- band A: repeated fast decays (60 dB/s -> ring 1.0 s is NOT what we want;
  -- use an explicit rate) ; band B: decays five times slower
  local function make(rate_db_per_s)
    local e, t = {}, 0
    local lvl = 0.0
    for i = 1, n do
      if (i % 200) == 1 then lvl = 0.0 else lvl = lvl - rate_db_per_s * dt end
      if lvl < -70 then lvl = -70 end
      e[i] = lvl
    end
    return e
  end
  local fastE, slowE = make(600.0), make(120.0)
  local tf = Ring.ring_time(fastE, dt, cfg)
  local ts = Ring.ring_time(slowE, dt, cfg)
  ok(tf and ts, "ring time is measurable on both bands", tostring(tf) .. "/" .. tostring(ts))
  if tf and ts then
    near(tf, 0.1, 0.03, "600 dB/s decay reads as a 0.10 s ring time")
    near(ts, 0.5, 0.10, "120 dB/s decay reads as a 0.50 s ring time")
    ok(ts > tf * 3, "the slower band ranks as ringing far more")
  end
  local _, few = Ring.ring_time({ 1, 2, 3 }, dt, cfg)
  ok(select(1, Ring.ring_time({ 1, 2, 3 }, dt, cfg)) == nil,
     "too little data returns nil rather than a number")

  local hz = { 400, 500, 600, 700, 800 }
  local times = { 0.20, 0.20, 0.60, 0.20, 0.20 }
  local idx = Ring.index(times, hz, cfg)
  ok(idx[3] > 2.0, "a band that rings three times longer scores a high index", idx[3])
  near(idx[1], 1.0, 0.01, "a typical band scores 1.0")
end

---------------------------------------------------------------------- broad
section("broad")
do
  local cfg = Config.new()
  local hz = Spectrum.hz_axis(1024, 1.953125)
  local function curve_with(centre, gain, width_oct)
    local c = {}
    for i = 1, #hz do
      local d = math.log(hz[i] / centre, 2) / width_oct
      c[i] = -70.0 + gain * math.exp(-d * d * 2.0)
    end
    return c
  end
  -- a broad hump, exactly the shape found on the real take
  -- shaped to reproduce the deviation actually measured on the real male take
  -- (+4.1 dB at the 1/1-vs-2-octave scale, centred 476 Hz)
  local direct = curve_with(476.0, 14.0, 0.5)
  local h = Broad.humps(direct, nil, hz, cfg)
  ok(#h >= 1, "a broad hump is found", #h)
  if #h >= 1 then
    ok(math.abs(h[1].hz - 476.0) / 476.0 < 0.15, "found at the right frequency", h[1].hz)
    ok(h[1].width_oct > 0.25, "reported as broad, not narrow", h[1].width_oct)
  end
  -- a NARROW peak must not be reported as broad colouration
  local narrow = {}
  for i = 1, #hz do narrow[i] = -70.0 end
  local ni = Spectrum.index_of(hz, 476.0)
  narrow[ni - 1], narrow[ni], narrow[ni + 1] = -64.0, -58.0, -64.0
  local hn = Broad.humps(narrow, nil, hz, cfg)
  ok(#hn == 0, "a narrow line is not reported as a broad hump", #hn)

  -- attribution: hump present in the tail more than the direct -> "room"
  local tail_room = curve_with(476.0, 20.0, 0.5)
  local hr = Broad.humps(direct, tail_room, hz, cfg)
  ok(#hr >= 1 and hr[1].source == "room", "a hump stronger in the tail is attributed to the room",
     #hr >= 1 and hr[1].source or "none")
  local tail_src = curve_with(476.0, 6.0, 0.5)
  local hs = Broad.humps(direct, tail_src, hz, cfg)
  ok(#hs >= 1 and hs[1].source == "source", "a hump weaker in the tail is attributed to the source",
     #hs >= 1 and hs[1].source or "none")
end

--------------------------------------------------------------------- detect
section("detect")
do
  local cfg = Config.new()
  local bin_hz = 1.953125
  local hz = Spectrum.hz_axis(1024, bin_hz)
  local function base()
    local c = {}
    for i = 1, #hz do c[i] = -80.0 - 3.0 * math.log(hz[i] / 100.0, 2) end
    return c
  end
  local function add_peak(c, f, gain, bw)
    for i = 1, #hz do
      local d = (hz[i] - f) / (bw * 0.5)
      c[i] = 10.0 * math.log(10 ^ (c[i] / 10) + 10 ^ ((c[i] + gain) / 10) / (1 + d * d), 10)
    end
  end
  local zero_occ = {}
  for i = 1, #hz do zero_occ[i] = 0.0 end
  local rings = function() return 2.0 end

  -- three planted narrow resonances, nothing else
  local c = base()
  add_peak(c, 120.0, 12.0, 6.0)
  add_peak(c, 300.0, 10.0, 12.0)
  add_peak(c, 700.0, 10.0, 25.0)
  local cands = Detect.run(c, hz, zero_occ, rings, cfg, bin_hz)
  local acc = {}
  for _, x in ipairs(cands) do if x.accepted then acc[#acc + 1] = x end end
  ok(#acc >= 3, "all three planted resonances are found", #acc)
  local function found(f)
    for _, x in ipairs(acc) do
      if math.abs(x.hz - f) < math.max(3.0, 0.02 * f) then return x end
    end
  end
  ok(found(120) and found(300) and found(700), "each at the right frequency")
  ok(#acc <= 5, "and not much else", #acc)

  -- a FORMANT-width peak must be rejected by the Q gate
  local cf = base()
  add_peak(cf, 550.0, 10.0, 120.0)
  local cf2 = Detect.run(cf, hz, zero_occ, rings, cfg, bin_hz)
  local any_acc = false
  for _, x in ipairs(cf2) do if x.accepted then any_acc = true end end
  ok(not any_acc, "a 120 Hz-wide formant is rejected -- the primary false-positive guard")

  -- REGRESSION, from the real male take: 515.6 Hz stood +10 dB proud and was
  -- H3 of a 169.5 Hz fundamental. Occupancy is what rejects it -- measured 0.42
  -- there, against a 0.35 limit.
  local cr = base()
  add_peak(cr, 515.6, 10.0, 12.0)
  local occ42 = {}
  for i = 1, #hz do occ42[i] = 0.42 end
  local cr2 = Detect.run(cr, hz, occ42, rings, cfg, bin_hz)
  local acc_r = false
  for _, x in ipairs(cr2) do if x.accepted then acc_r = true end end
  ok(not acc_r, "the 515.6 Hz harmonic is rejected by occupancy")

  -- The ring index is a DIAGNOSTIC, not a gate. It was a gate until
  -- test/inject_in_reaper.lua showed it rejected a known injected resonance;
  -- a gate that cannot pass a true positive is worse than no gate.
  local flat_ring = function() return 0.94 end
  local cq = Detect.run(cr, hz, zero_occ, flat_ring, cfg, bin_hz)
  local acc_q = false
  for _, x in ipairs(cq) do if x.accepted then acc_q = true; break end end
  ok(acc_q, "a low ring index no longer rejects a candidate")
  local reported = false
  for _, x in ipairs(cq) do if x.ring_index then reported = true; break end end
  ok(reported, "but the ring index is still reported")

  -- a broad LF shelf must not produce a candidate at all
  local cs = {}
  for i = 1, #hz do cs[i] = -80.0 + 12.0 * math.exp(-hz[i] / 120.0) end
  local cs2 = Detect.run(cs, hz, zero_occ, rings, cfg, bin_hz)
  local acc_s = false
  for _, x in ipairs(cs2) do if x.accepted then acc_s = true end end
  ok(not acc_s, "a broad LF shelf yields no narrow candidate")

  -- Schroeder: above it there are no discrete modes
  near(Detect.schroeder_hz(0.44, 30.0), 242.4, 1.0, "Schroeder frequency for a 30 m3 room at T60 0.44")
  cfg._schroeder_hz = 242.0
  ok(Detect.classify({ hz = 1000, is_line = false }, cfg) == "reflection",
     "a narrow peak above the Schroeder frequency is a reflection, never a mode",
     Detect.classify({ hz = 1000, is_line = false }, cfg))
  ok(Detect.classify({ hz = 1010, is_line = false }, cfg) == "reflection",
     "and mains labelling does not reach up there")
  ok(Detect.classify({ hz = 100.0, is_line = false }, cfg) == "hum 50 Hz",
     "a 50 Hz harmonic is labelled hum")
end

---------------------------------------------------------------------- solve
section("solve")
do
  local Solve = require "dr.solve"
  local RATE = 48000
  local c0 = Solve.peaking(1000, 2.0, 0.0, RATE)
  for _, f in ipairs({ 50, 300, 1000, 5000, 15000 }) do
    near(Solve.response_sq(c0, f, RATE), 1.0, 1e-9,
         "a 0 dB bell is unity at " .. f .. " Hz")
  end
  local c1 = Solve.peaking(1000, 4.0, -9.0, RATE)
  near(10 * math.log(Solve.response_sq(c1, 1000, RATE), 10), -9.0, 0.01,
       "a bell's response at its own centre equals its gain")
  ok(math.abs(10 * math.log(Solve.response_sq(c1, 100, RATE), 10)) < 0.5,
     "and it is out of the way a decade below")

  -- the gain is SOLVED against the real response, not set to the difference
  local g, clamped = Solve.solve_cut({}, 500, 6.0, RATE, -6.0, 12.0)
  near(g, -6.0, 0.05, "an isolated cut solves to exactly what was asked for")
  ok(not clamped, "and is not clamped")
  local g2, cl2 = Solve.solve_cut({}, 500, 6.0, RATE, -30.0, 12.0)
  near(g2, -12.0, 0.01, "an out-of-reach target returns the limit")
  ok(cl2, "and SAYS it clamped rather than silently returning it")

  -- with a filter already placed, the second solves to less than the raw gap
  local first = Solve.peaking(500, 6.0, -6.0, RATE)
  local g3 = Solve.solve_cut({ first }, 500, 6.0, RATE, -6.0, 12.0)
  ok(math.abs(g3) < 0.05, "an overlapping cut accounts for the one already there", g3)

  local cands = { { accepted = true, hz = 500, q = 20, kind = "mode" } }
  local humps = { { hz = 900, q = 1.5, db = 4.0, source = "room" } }
  local level = function(f) return -60.0 end
  local target = function(f) return -66.0 end
  local plan = Solve.plan(cands, humps, level, target, Config.new(), RATE)
  ok(#plan == 2, "plan places one filter per accepted finding", #plan)
  ok(plan[1].db < 0 and plan[2].db < 0, "and every one of them cuts")
  -- REGRESSION: a broad hump is solved against its OWN measurement, not the
  -- 1/3-octave envelope, which follows a hump that wide and yields no cut
  local broadonly = Solve.plan(nil, humps, level, target, Config.new(), RATE)
  ok(#broadonly == 1, "a broad hump alone still produces a filter", #broadonly)
  near(broadonly[1].db, -4.0, 0.1, "cut by the hump's measured height, not by zero")
  -- and a three-figure Q is capped to something a biquad can actually be
  local wildq = { { accepted = true, hz = 500, q = 400, kind = "line" } }
  local pq = Solve.plan(wildq, nil, level, target, Config.new(), RATE)
  ok(#pq == 1 and pq[1].q <= 60, "an absurd measured Q is capped", pq[1] and pq[1].q)
end

---------------------------------------------------------------------- gains
section("gains")
do
  local Gains = require "dr.gains"
  near(10 * math.log(Gains.decay(0.4, 0.4), 10), -60.0, 1e-9,
       "decay over exactly T60 is -60 dB, which is what T60 means")
  near(10 * math.log(Gains.decay(0.2, 0.4), 10), -30.0, 1e-9, "and half of it is -30 dB")
  ok(Gains.decay(1.0, 0) == 0, "a zero T60 means no late estimate at all")

  near(Gains.alpha(-20, 4), 4, 1e-9, "alpha saturates at amax below the low knee")
  near(Gains.alpha(30, 4), 1, 1e-9, "and at 1 above the high knee")
  ok(Gains.alpha(0, 4) < 4 and Gains.alpha(0, 4) > 1, "and ramps between them")

  near(Gains.wiener(1, 1, 4), 0, 1e-9, "a bin that is all reverb is cut to nothing")
  ok(Gains.wiener(1000, 1, 4) > 0.99, "a bin that is all signal passes")
  near(Gains.wiener(1, 0, 4), 1, 1e-9, "and with no reverb estimate nothing is cut")

  near(Gains.floor_gain(0.0, 1.0), 1, 1e-9,
       "at 0 dB reduction gains are forced to 1 -- the transparency guard")
  near(Gains.floor_gain(0.0, 0.25), 0.25, 1e-9, "12 dB reduction floors at 0.25")
  near(Gains.floor_gain(0.9, 0.25), 0.9, 1e-9, "and leaves a passing bin alone")

  local n = 8
  local spec, prev = {}, {}
  for i = 1, n do spec[i] = 1.0; prev[i] = 1.0 end
  spec[4] = 1000.0                        -- one bin carrying real signal
  local cfg2 = Config.new(); cfg2.reduction = 12; cfg2.strength = 100
  local g = Gains.curve(spec, prev, n, 0.0, 1.0, cfg2)
  ok(g[4] > 0.9, "the loud bin passes through the dereverb", g[4])
  near(g[1], 10 ^ (-12 / 20), 1e-6, "and reverb-dominated bins sit on the floor")
  cfg2.reduction = 0
  local g0 = Gains.curve(spec, prev, n, 0.0, 1.0, cfg2)
  for i = 1, n do
    if g0[i] ~= 1 then ok(false, "0 dB reduction is transparent", g0[i]); break end
  end
  ok(true, "0 dB reduction is transparent everywhere")
end

----------------------------------------------------------------------- gate
section("gate")
do
  local G = require "dr.gate"

  -- band geometry
  ok(G.NBANDS == #G.EDGES + 1, "eight bands from seven crossovers", G.NBANDS)
  ok(G.band_of(50) == 1, "below the first edge is band 1")
  ok(G.band_of(10000) == G.NBANDS, "above the last edge is the top band")
  ok(G.band_of(G.EDGES[1]) == 2, "an edge belongs to the band above it")

  local b, m = G.bin_band(40)
  ok(b == 1 and m == 0, "well below an edge a bin is wholly in one band")
  b, m = G.bin_band(G.EDGES[1])
  near(m, 0.5, 1e-9, "at the edge itself the crossfade is exactly half")
  ok(b == 1, "and it is expressed as band 1 leaning into band 2")
  b, m = G.bin_band(G.EDGES[1] * 2 ^ (G.CROSS_OCT + 0.01))
  ok(b == 2 and m == 0, "past the transition it is wholly the next band")
  local lastb, bad = 1, 0
  for f = 30, 15000, 7 do
    local bb, mm = G.bin_band(f)
    if mm < 0 or mm > 1 or bb < lastb then bad = bad + 1 end
    lastb = bb
  end
  ok(bad == 0, "the map is monotone and its weights stay in [0,1]", bad)

  -- the fold is a POWER SUM. A median of dB reads ~10.8 dB low here, and
  -- every suggested threshold would go with it, plausibly.
  local hz, db = {}, {}
  for i = 1, 12 do
    hz[i] = 185 * 2 ^ ((i - 1) / 12)      -- twelve bands, all inside 180..360
    db[i] = -60.0
  end
  local F = G.fold(db, hz, 12)
  near(F[3], -60.0 + 10 * math.log(12, 10), 1e-6,
       "twelve equal bands fold to 10.79 dB above one of them, not to one")
  ok(F[1] == nil, "a gate band no analysis band reaches folds to nil")

  -- the law
  near(G.gain_db(-40, -60, 3, 30), 0, 1e-12, "above threshold the law is 0 dB")
  near(G.gain_db(-70, -60, 1, 30), 0, 1e-12,
       "ratio 1 is transparent everywhere -- the cheapest guard there is")
  near(G.gain_db(-70, -60, 3, 30), -20, 1e-9, "10 dB under at 3:1 is -20 dB")
  near(G.gain_db(-90, -60, 3, 30), -30, 1e-9, "and the range clamps it")
  near(G.gain_db(-61, -60, math.huge, 30), -30, 1e-9,
       "a gate is the ratio -> infinity limit of the same expression")

  -- the envelope
  local dt = 2048 / 4 / 48000
  local st = { g = 0.0, held = 0.0 }
  G.step(st, -70, -60, 3, 30, 0.1, dt)
  near(st.g, 0.0, 1e-12, "the first frame below threshold does not move yet")
  ok(st.held > 0, "it starts the hold instead")
  local steps = 0
  while st.g == 0.0 and steps < 100 do G.step(st, -70, -60, 3, 30, 0.1, dt); steps = steps + 1 end
  near((steps + 1) * dt, G.HOLD_S, dt + 1e-9, "release begins after the hold, not before")
  ok(st.g < 0, "and then it closes", st.g)
  local closed = st.g
  G.step(st, -40, -60, 3, 30, 0.1, dt)
  near(st.g, 0.0, 1e-12, "opening is instant: a 43 ms window cannot clip an onset")
  ok(closed < 0, "(it really had closed first)", closed)

  local sg = { g = -10.0, held = 1.0 }
  G.step(sg, -59, -60, math.huge, 30, 0.1, dt)
  ok(sg.g < 0, "in gate mode hysteresis keeps a band on its threshold shut")
  local se = { g = -10.0, held = 1.0 }
  G.step(se, -59, -60, 3, 30, 0.1, dt)
  near(se.g, 0.0, 1e-12, "an expander is continuous and takes no hysteresis")

  -- the filterbank's crossovers
  local RATE = 48000
  local xo = G.crossover(1000.0, RATE)
  local function cx(c, f)
    local re, im = G.biquad_at(c, f, RATE)
    return re, im
  end
  -- LR4 is Butterworth squared, so each half is -6 dB at the crossover. That
  -- is the property that makes the two sum to unity rather than to +3 dB.
  local lr, li = cx(xo.lp, 1000.0)
  local m = 10 * math.log((lr*lr + li*li) ^ 2, 10)     -- squared: applied twice
  near(m, -6.0206, 0.01, "an LR4 lowpass is -6 dB at its own crossover")
  local hr, hi2 = cx(xo.hp, 1000.0)
  near(10 * math.log((hr*hr + hi2*hi2) ^ 2, 10), -6.0206, 0.01,
       "and so is the highpass")

  -- LP^2 + HP^2 == AP, as COMPLEX sums. This is the identity the whole
  -- eight-band tree reconstructs on: without it each band carries the wrong
  -- phase for the splits that came after it and the bank sums with ripple at
  -- every crossover instead of flat.
  local worst, wf = 0, 0
  for _, f in ipairs({ 20, 50, 100, 250, 500, 900, 1000, 1100, 2000, 5000, 12000, 20000 }) do
    local a, b = cx(xo.lp, f)
    local c, d = cx(xo.hp, f)
    local l2r, l2i = a*a - b*b, 2*a*b        -- squared, applied twice
    local h2r, h2i = c*c - d*d, 2*c*d
    local pr2, pi2 = cx(xo.ap, f)
    local dr, di = (l2r + h2r) - pr2, (l2i + h2i) - pi2
    local e = math.sqrt(dr*dr + di*di)
    if e > worst then worst, wf = e, f end
  end
  ok(worst < 1e-9, "LP^2 + HP^2 is exactly the allpass, in phase as well as level",
     string.format("%.2e at %d Hz", worst, wf))

  local apm = 0
  for _, f in ipairs({ 20, 100, 1000, 5000, 20000 }) do
    local a, b = cx(xo.ap, f)
    apm = math.max(apm, math.abs(math.sqrt(a*a + b*b) - 1))
  end
  ok(apm < 1e-12, "and the allpass really is one", apm)

  -- the whole bank of seven, evaluated as the tree runs it
  local xos = G.crossovers(RATE)
  ok(#xos == G.NBANDS - 1, "one crossover per band boundary", #xos)
  local bworst, bwf = 0, 0
  for f = 30, 18000, 37 do
    -- band k = LP_k applied to the running highpass, corrected by every LATER
    -- allpass; sum must be unity magnitude
    local sr, si = 0, 0
    local rr, ri = 1, 0                       -- the running highpass branch
    for kx = 1, #xos do
      local a, b = cx(xos[kx].lp, f)
      local l2r, l2i = a*a - b*b, 2*a*b
      local br, bi = rr*l2r - ri*l2i, rr*l2i + ri*l2r
      for j = kx + 1, #xos do                 -- the allpass correction
        local pr2, pi2 = cx(xos[j].ap, f)
        br, bi = br*pr2 - bi*pi2, br*pi2 + bi*pr2
      end
      sr, si = sr + br, si + bi
      local c, d = cx(xos[kx].hp, f)
      local h2r, h2i = c*c - d*d, 2*c*d
      rr, ri = rr*h2r - ri*h2i, rr*h2i + ri*h2r
    end
    sr, si = sr + rr, si + ri                 -- the top band
    local e = math.abs(math.sqrt(sr*sr + si*si) - 1)
    if e > bworst then bworst, bwf = e, f end
  end
  ok(bworst < 1e-9,
     "and all eight bands sum to unity magnitude across the spectrum",
     string.format("%.2e at %d Hz", bworst, bwf))

  -- the detector floors: a one-pole shorter than the period it watches tracks
  -- the waveform rather than the envelope, and the band buzzes
  local d1 = G.detect_times(1)
  local d8 = G.detect_times(G.NBANDS)
  ok(d1 > d8, "a low band gets a slower detector than a high one",
     string.format("%.3f vs %.3f", d1, d8))
  ok(d1 >= 3.0 / G.EDGES[1] - 1e-9,
     "and band 1 is referred to its upper edge, having no lower one", d1)

  -- attack: the spectral path opens instantly, the filterbank through a pole
  local si1 = { g = -20.0, held = 1.0 }
  G.step(si1, -10, -60, 3, 30, 0.1, dt)
  near(si1.g, 0.0, 1e-12, "with no attack given, opening is instant as before")
  local sa = { g = -20.0, held = 1.0 }
  G.step(sa, -10, -60, 3, 30, 0.1, 1 / 48000, 0.010)
  ok(sa.g > -20.0 and sa.g < -19.0,
     "and with one, it ramps instead of stepping -- a step here is a click", sa.g)

  near(G.FB_OFFSET_DB, 4.7712, 1e-4,
       "the filterbank detector carries the 10*log10(0.375/0.125) unit offset")

  near(G.release_of(0.40), 0.10, 1e-9, "release is T60/4")
  near(G.release_of(4.0), G.REL_MAX, 1e-9, "clamped at the top")
  near(G.release_of(0.01), G.REL_MIN, 1e-9, "and at the bottom")

  -- the suggestion
  local n = 60
  local ghz, pause, voice, floor, t60 = {}, {}, {}, {}, {}
  for i = 1, n do
    ghz[i] = 30 * 2 ^ ((i - 1) / 12)       -- 30 Hz .. ~1.9 kHz, as the ring pass
    pause[i], voice[i], floor[i], t60[i] = -80.0, -40.0, -95.0, 0.40
  end
  local sug, why, nm = G.suggest(pause, voice, floor, ghz, t60, n, false)
  ok(sug ~= nil, "a separated take produces a suggestion", why)
  ok(nm and nm >= 5, "and measures the bands the analysis reaches", nm)
  local e = sug[3]
  ok(e.measured, "band 3 is measured", e.why)
  ok(e.thr > e.pause and e.thr < e.voice,
     "its threshold lands between the tail and the voice", e.thr)
  near(e.thr, e.voice - G.GATE_BELOW_DB, 1e-9,
       "and it is set from the band's working level, not from the pause: the "
       .. "pause cube's own gate fires too late to be a threshold")
  near(e.range_cap, e.thr - e.floor, 1e-9,
       "a band at its threshold is never pushed below its measured noise floor")
  near(e.release, 0.10, 1e-9, "release comes from the band's own T60")
  ok(sug[G.NBANDS].measured == false,
     "the top band is refused: the ring pass never reaches it")
  ok((sug[G.NBANDS].why or ""):find("not measured") ~= nil,
     "and it says so rather than extrapolating a number", sug[G.NBANDS].why)

  -- flatten ONE band: its pauses sit 2 dB under its voice, the rest unchanged
  local vflat = {}
  for i = 1, n do
    vflat[i] = (G.band_of(ghz[i]) == 3) and (pause[i] + 2.0) or voice[i]
  end
  local flat = G.suggest(pause, vflat, floor, ghz, t60, n, false)
  ok(flat ~= nil and flat[3].measured == false,
     "a band whose pauses do not separate from the voice is refused")
  ok((flat[3].why or ""):find("not gateable") ~= nil, "and says why", flat[3].why)
  ok(flat[4].measured == true, "while its neighbours are unaffected")

  local vdead = {}
  for i = 1, n do vdead[i] = pause[i] + 2.0 end
  local dead, dwhy = G.suggest(pause, vdead, floor, ghz, t60, n, false)
  ok(dead == nil, "and a take where NO band separates refuses outright")
  ok(dwhy ~= nil and dwhy:find("separated") ~= nil, "naming that", dwhy)

  local none, pwhy = G.suggest(pause, voice, floor, ghz, t60, n, true)
  ok(none == nil, "a pinned level statistic refuses outright")
  ok(pwhy ~= nil and pwhy:find("pinned") ~= nil, "and names the reason", pwhy)

  -- what the render actually runs with
  local c = Config.new()
  c.gate_amount, c.gate_offset_db, c.gate_release = 100, 0, 100
  local thr, rng, rel = G.effective_band(c, sug, 3)
  near(thr, sug[3].thr, 1e-9, "under auto the threshold is the suggestion")
  near(rng, math.min(G.RANGE_MAX, sug[3].range_cap), 1e-9,
       "and the depth is clamped by what the measurement says is there")
  c.gate_offset_db = -6
  local thr2 = G.effective_band(c, sug, 3)
  near(thr2, thr - 6, 1e-9, "the offset shifts every band at once")
  c.gate_offset_db, c.gate_amount = 0, 50
  local _, rng2 = G.effective_band(c, sug, 3)
  ok(rng2 <= rng, "amount scales depth and only depth", rng2)
  c.gate_auto = false
  c.gate_thr3 = -55.5
  local thr3 = G.effective_band(c, sug, 3)
  near(thr3, -55.5, 1e-9, "unticking auto hands back the hand-set key")

  -- config wiring
  local cc = Config.new()
  ok(Config.latency(cc) == 0, "latency is 0 with both stages off")
  cc.gate_on = true
  ok(Config.latency(cc) == cc.rfft_size,
     "the spectral gate alone still costs one window -- it shares the STFT")
  ok(Config.spectral_gate(cc), "and it is the spectral one by default")
  cc.gate_domain = "filterbank"
  ok(Config.latency(cc) == 0,
     "the filterbank gate adds NONE: it is IIR, in the time domain, after it")
  ok(not Config.spectral_gate(cc), "and does not put the STFT in the chain")
  cc.dereverb_on = true
  ok(Config.latency(cc) == cc.rfft_size,
     "though the dereverb still does, whichever gate is selected")
  cc.dereverb_on = false
  cc.gate_domain = "spectral"
  local base = Config.gate_sig(cc)
  local moved = 0
  for _, key in ipairs(Config.GATE_KEYS) do
    local c2 = Config.new(); c2.gate_on = true
    -- NOT an and/or chain: `(type(v)=="boolean") and (not v)` yields false
    -- when v is true and falls through to the next branch, which then
    -- concatenates a boolean. The same shape killed a control in dr/ui.lua.
    local v = c2[key]
    if type(v) == "boolean" then c2[key] = not v
    elseif type(v) == "number" then c2[key] = v + 1
    else c2[key] = v .. "x" end
    if Config.gate_sig(c2) ~= Config.gate_sig(cc) then moved = moved + 1 end
    ok(Config.analysis_sig(c2) == Config.analysis_sig(cc),
       "'" .. key .. "' does not force a re-read of the audio")
  end
  ok(moved == #Config.GATE_KEYS, "every GATE_KEYS entry moves the gate signature",
     moved .. "/" .. #Config.GATE_KEYS)
  ok(base ~= nil, "(gate_sig is defined)")

  local ce = Config.new(); ce.gate_on = true
  local eff = Config.effective(ce, nil, sug)
  ok(eff ~= ce, "effective() copies when there is a suggestion to attach")
  ok(eff._gate == sug, "and attaches it for the kernel")
  ok(ce._gate == nil, "without writing anything into the user's config")
  local ce2 = Config.new()
  ok(Config.effective(ce2, nil, sug) == ce2,
     "with the gate off nothing is copied")
end

----------------------------------------------------------------------- auto
section("auto")
do
  local Auto = require "dr.auto"

  -- The law, against the points it was fitted to in
  -- test/t60_calib_in_reaper.lua. These are the calibration: if the constants
  -- move without that suite being re-run, this is what says so.
  local CALIB = {
    { ring = 0.108, t60 = 0.15 }, { ring = 0.133, t60 = 0.20 },
    { ring = 0.164, t60 = 0.30 }, { ring = 0.176, t60 = 0.40 },
    { ring = 0.202, t60 = 0.55 }, { ring = 0.216, t60 = 0.90 },
    { ring = 0.232, t60 = 1.10 }, { ring = 0.248, t60 = 1.60 },
  }
  local worst, worst_at = 0, nil
  for _, c in ipairs(CALIB) do
    -- the safety factor is deliberate bias, so compare the law without it
    local est = Auto.t60_from_ring(c.ring) / Auto.SAFETY
    local err = math.abs(est / c.t60 - 1)
    if err > worst then worst, worst_at = err, c.t60 end
  end
  ok(worst < 0.35, "the calibrated law fits every measured point to 35%",
     string.format("worst %.0f%% at T60 %.2f", worst * 100, worst_at or 0))

  ok(Auto.SAFETY < 1.0, "and is biased DOWN, because the error is asymmetric")
  ok(Auto.t60_from_ring(0.30) > Auto.t60_from_ring(0.20),
     "a longer ring figure means a longer T60")
  ok(Auto.t60_from_ring(nil) == nil, "no ring figure means no estimate")

  -- Measured: with no reverberation at all every band reports 0.041 s, and
  -- that floor does not move with T60. A take there must get the bottom of
  -- the range, not a number derived from the window's own smear.
  local dry = Auto.estimate(0.041, 50, false)
  ok(dry and dry.dry, "a ring figure at the dry floor is reported as dry")
  ok(dry and dry.t60 == Auto.T60_MIN, "and pinned to the minimum T60")
  ok(dry and dry.reduction == Auto.RED_MIN, "and the minimum reduction")

  local wet = Auto.estimate(0.232, 50, false)
  ok(wet and not wet.dry, "a ring figure well above it is not")
  ok(wet and wet.t60 > 0.8 and wet.t60 < 1.1,
     "1.10 s of real decay comes back near 0.93 s after the safety factor",
     wet and wet.t60)
  ok(wet and wet.reduction > Auto.reduction_from_t60(0.2),
     "a liver room is offered more reduction than a dry one")
  ok(Auto.reduction_from_t60(5.0) <= Auto.RED_MAX, "reduction is clamped above")
  ok(Auto.reduction_from_t60(0.01) >= Auto.RED_MIN, "and below")

  -- Refusing is the safe failure, and the panel must be able to say so.
  ok(Auto.estimate(0.2, 50, true) == nil, "a pinned level statistic refuses")
  ok(Auto.estimate(0.2, 2, false) == nil, "and so does too few bands")
  ok(Auto.estimate(nil, 50, false) == nil, "and no ring figure at all")
  local _, why = Auto.estimate(nil, 50, false)
  ok(type(why) == "string" and #why > 0, "each refusal says why")

  -- Applying the law per band is only equivalent to applying it to the median
  -- because it is monotone. Assert the monotonicity that rests on.
  local a, b = Auto.band_t60(0.15, 1.0), Auto.band_t60(0.25, 1.0)
  ok(a and b and b > a, "band_t60 is monotone in the band's ring figure")
  ok(Auto.band_t60(0.05, 1.0) >= 0.05 and Auto.band_t60(3.0, 1.0) <= 4.0,
     "and clamped to the range the kernel is handed")
  near(Auto.band_t60(0.176, 2.0), 2.0 * Auto.band_t60(0.176, 1.0), 1e-9,
       "the T60 scale trims the automatic figure, it does not replace it")

  -- The effective config: cfg keeps meaning what the user set.
  local c = Config.new()
  c.auto_reverb, c.t60, c.reduction = true, 0.40, 12.0
  local e = Config.effective(c, { t60 = 0.90, reduction = 15.0 })
  ok(e.t60 == 0.90 and e.reduction == 15.0, "the render runs on the estimate")
  ok(c.t60 == 0.40 and c.reduction == 12.0, "and the hand-set values survive it")
  c.auto_reverb = false
  ok(Config.effective(c, { t60 = 0.90 }).t60 == 0.40,
     "unticking the box gives them straight back")
  ok(Config.effective(c, nil) == c, "and with no estimate nothing is copied")
end

------------------------------------------------------------------------ edc
section("edc")
do
  local Edc = require "dr.edc"
  local Kernel = require "dr.kernel"
  local cfg2 = Config.new()
  local function hist(pairs_)
    local h = {}
    for i = 1, 80 do h[i] = 0 end
    for _, pr in ipairs(pairs_) do
      -- put `count` fits in the bucket whose centre is nearest `t`
      local best, bd = 1, math.huge
      for i = 1, 80 do
        local d = math.abs(Kernel.ring_time_of(i - 1) - pr[1])
        if d < bd then best, bd = i, d end
      end
      h[best] = h[best] + pr[2]
    end
    return h
  end

  local h = hist({ { 0.50, 10 } })
  local t, n = Edc.t60_from_hist(h, cfg2, Kernel.ring_time_of)
  ok(t and math.abs(t - 0.50) < 0.05, "a band's T60 is the median of its fits", t)
  ok(n == 10, "and the count comes back with it", n)

  ok(Edc.t60_from_hist(hist({ { 0.5, 3 } }), cfg2, Kernel.ring_time_of) == nil,
     "too few fits is refused, not averaged")

  -- The reason the median is used and not the mean: one pause that held a
  -- breath or a door must not move the answer.
  local skew = hist({ { 0.40, 9 }, { 4.0, 2 } })
  local tm = Edc.t60_from_hist(skew, cfg2, Kernel.ring_time_of)
  ok(tm and tm < 0.6, "and two wild fits cannot drag the median", tm)

  local times = { 0.3, 0.5, 0.7, nil, 0.9 }
  local med, nb = Edc.median(times, 5)
  -- the lower median, the same convention ring_p50 uses, so the two figures
  -- the panel prints side by side are taken the same way
  ok(med == 0.5 and nb == 4, "the median across bands skips the ones that refused",
     tostring(med) .. "/" .. tostring(nb))
  ok(select(2, Edc.median({}, 0)) == 0, "and an empty cube reports no bands")

  -- Auto must PREFER the direct measurement and fall back to the ring law.
  local Auto = require "dr.auto"
  local a = Auto.from_decay(0.62, 30, false)
  ok(a and a.measured, "a decay measurement is marked as measured")
  ok(a and math.abs(a.t60 - 0.62) < 1e-9,
     "and is used as-is: no proxy bias left to absorb", a and a.t60)
  ok(Auto.from_decay(0.62, 1, false) == nil, "too few bands falls through")
  ok(Auto.from_decay(0.62, 30, true) == nil, "and so does a pinned statistic")
  local _, why = Auto.from_decay(nil, 30, false)
  ok(type(why) == "string" and #why > 0, "each refusal says why")
  local r = Auto.estimate(0.176, 50, false)
  ok(r and not r.measured, "the ring law's answer is not marked measured")
end

------------------------------------------------------------------------ wav
section("wav")
do
  local Wav = require "dr.wav"
  local path = os.tmpname() .. ".wav"
  local w, werr = Wav.create(path, 1, 48000)
  ok(w ~= nil, "writer opens", werr)
  if w then
    local t = {}
    for i = 1, 10000 do t[i] = math.sin(i * 0.01) end
    w:write(t, 1, #t)
    w:close()
    local fh = io.open(path, "rb")
    local hdr = fh:read(44)
    local sz = fh:seek("end"); fh:close()
    ok(hdr:sub(1, 4) == "RIFF" and hdr:sub(9, 12) == "WAVE", "RIFF/WAVE magic")
    local fmt = string.unpack("<I2", hdr, 21)
    ok(fmt == 3, "format tag 3 -- 32-bit float", fmt)
    local ch = string.unpack("<I2", hdr, 23)
    local sr = string.unpack("<I4", hdr, 25)
    ok(ch == 1 and sr == 48000, "channels and rate round-trip")
    ok(sz == 44 + 10000 * 4, "and the data chunk is the right length", sz)
    os.remove(path)
  end
  ok(Wav.will_overflow(2 ^ 30, 2), "the 4 GB guard trips on a huge file")
  ok(not Wav.will_overflow(48000 * 60, 1), "and not on a normal one")
end

------------------------------------------------------------------- panel
section("panel")
do
  local UIF = require "ui_frame"
  local UI  = require "dr.ui"
  -- every state twice: once quiet, once with every control reporting "moved"
  for _, changed in ipairs({ false, true }) do
    local tag = changed and " (controls moved)" or " (quiet)"
    local ok1, err1, S1 = UIF.run(UI, root, nil, changed)
    ok(ok1, "empty panel frame renders" .. tag, err1)
    ok(S1.dis == 0, "disabled stack balances, empty" .. tag, S1.dis)
    ok(S1.push == 0, "style stack balances, empty" .. tag, S1.push)
    local ok2, err2, S2, ST2, cfg2 = UIF.run(UI, root, UIF.stub_state, changed)
    ok(ok2, "populated panel frame renders" .. tag, err2)
    ok(S2.dis == 0, "disabled stack balances, populated" .. tag, S2.dis)
    ok(UI._disabled_depth() == 0, "no disabled depth left behind" .. tag)
    ok(ST2.gate ~= nil and cfg2.gate_on,
       "and it rendered with the gate engaged" .. tag)
    -- gate mode takes a different branch: the ratio slider is disabled and
    -- the hysteresis note is drawn
    local ok3, err3, S3 = UIF.run(UI, root, function(ST3, c3)
      UIF.stub_state(ST3, c3); c3.gate_mode = "gate"
    end, changed)
    ok(ok3, "panel frame renders in gate mode" .. tag, err3)
    ok(S3.dis == 0, "disabled stack balances in gate mode" .. tag, S3.dis)
    -- the filterbank branch of the domain switch draws different text
    local ok5, err5, S5 = UIF.run(UI, root, function(ST5, c5)
      UIF.stub_state(ST5, c5); c5.gate_domain = "filterbank"
    end, changed)
    ok(ok5, "panel frame renders in the filterbank domain" .. tag, err5)
    ok(S5.dis == 0, "disabled stack balances in the filterbank domain" .. tag, S5.dis)
    -- and with the suggestion refused, which is the branch a take with no
    -- pauses takes
    local ok4, err4, S4 = UIF.run(UI, root, function(ST4, c4)
      UIF.stub_state(ST4, c4); ST4.gate, ST4.gate_why = nil, "no pauses to measure"
    end, changed)
    ok(ok4, "panel frame renders with the gate refused" .. tag, err4)
    ok(S4.dis == 0, "disabled stack balances with the gate refused" .. tag, S4.dis)
  end
end

----------------------------------------------------------------- coverage
section("control coverage")
do
  local fh = io.open(root .. "dr/ui.lua", "r")
  if not fh then bail("cannot read dr/ui.lua")
  else
    local srctext = fh:read("*a"); fh:close()
    local seen = {}
    -- [%w_] not %w, or `input_double` scans as `double`
    for _, key in srctext:gmatch('([%w_]+)%("[^"]*",%s*"([%w_]+)"') do
      seen[key] = true
      ok(Config.defaults[key] ~= nil,
         "control '" .. key .. "' names a real config key")
    end
    -- A control in a loop builds its key: `slider(label, "gate_thr" .. g, ...)`.
    -- Scan for the prefix as well, or eight real controls read as eight
    -- settings nothing touches and the note stops meaning anything.
    for prefix in srctext:gmatch('"([%w_]+)"%s*%.%.%s*[%w_]+') do
      local n = 0
      for k in pairs(Config.defaults) do
        if k:sub(1, #prefix) == prefix then seen[k] = true; n = n + 1 end
      end
      ok(n > 0, "computed control '" .. prefix .. "*' names real config keys", n)
    end
    local missing = {}
    for k in pairs(Config.defaults) do
      if not seen[k] then missing[#missing + 1] = k end
    end
    table.sort(missing)
    print("  note: settings with no control yet: " .. table.concat(missing, ", "))
  end
end

print(string.format("\nheadless: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
