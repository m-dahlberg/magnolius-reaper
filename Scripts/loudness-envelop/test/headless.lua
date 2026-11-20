-- Loudness Envelope -- headless suite. Pure Lua, no REAPER API.
--
-- Run through reascript_test.py (REAPER's embedded Lua stands in for the
-- missing system interpreter), or from the Actions list.
--
-- The first block is the one that matters: it states the script's JOB as a
-- measurable contrast -- syllables in, phrases out -- and asserts it at the
-- shipped defaults. Everything after it checks one stage at a time.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;" .. package.path

local saved_reaper = reaper
reaper = nil                      -- prove the pure stages need none of it
local Config = require "le.config"
local Curve  = require "le.curve"
reaper = saved_reaper

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function report()
  say(string.format("headless: %d passed, %d failed", pass, fail))
  local text = table.concat(out, "\n") .. "\n"
  if reaper and reaper.ShowConsoleMsg then reaper.ShowConsoleMsg(text) else print(text) end
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %.4g (tol %.3g)", tostring(a), b, tol))
end

local HOP = Config.FRAME_S
local function e_of(db) return 10 ^ (db / 10) end

-- A sung phrase as 10 ms frame energies: vowels around `base`, a consonant
-- dip every syllable, and an accented burst every third one. The modulation
-- is the thing the curve must NOT follow, so it is deliberately large:
-- +3 / -10 / +7 dB, 20 dB peak to peak in the raw frames.
local function phrase(E, base, secs)
  local nf = math.floor(secs / HOP + 0.5)
  local syl = 0
  local i = 0
  while i < nf do
    syl = syl + 1
    local vowel = (syl % 3 == 0) and 7 or 3
    for _ = 1, 17 do if i < nf then i = i + 1 E[#E + 1] = e_of(base + vowel) end end
    for _ = 1, 8  do if i < nf then i = i + 1 E[#E + 1] = e_of(base - 10) end end
  end
end
local function gap(E, secs, db)
  for _ = 1, math.floor(secs / HOP + 0.5) do E[#E + 1] = e_of(db or -75) end
end

local function stats(res, ta, tb)
  local lo, hi, sum, n = math.huge, -math.huge, 0, 0
  for j, t in ipairs(res.t) do
    if t >= ta and t <= tb then
      local v = res.curve[j]
      if v < lo then lo = v end
      if v > hi then hi = v end
      sum, n = sum + v, n + 1
    end
  end
  return hi - lo, sum / math.max(n, 1), lo, hi
end
local function level_stats(res, ta, tb)
  local lo, hi = math.huge, -math.huge
  for j, t in ipairs(res.t) do
    if t >= ta and t <= tb then
      local v = res.level[j]
      if v < lo then lo = v end
      if v > hi then hi = v end
    end
  end
  return hi - lo
end

------------------------------------------------- the job, at shipped defaults

do
  say("effectiveness (shipped defaults)")
  -- 1 s room tone | 8 s phrase at -24 | 1.5 s breath gap | 8 s phrase at -18 | 1 s
  local E = {}
  gap(E, 1.0)
  phrase(E, -24, 8.0)
  gap(E, 1.5, -60)
  phrase(E, -18, 8.0)
  gap(E, 1.0)
  local F = { t0 = 10.0, hop = HOP, n = #E, E = E }
  local cfg = Config.new()
  local res, err = Curve.build(F, cfg)
  ok(res ~= nil, "builds", err)

  -- Phrase interiors, clear of the outline window at either edge.
  local A0, A1 = 10 + 1 + 2.5, 10 + 1 + 5.5
  local B0, B1 = 10 + 10.5 + 2.5, 10 + 10.5 + 5.5

  -- 20 dB in the raw frames; the rider's 50 ms one-pole smooths an 80 ms
  -- consonant to about 8, and that is the movement the rider would chase.
  local raw = level_stats(res, A0, A1)
  ok(raw > 6, "the fixture really does carry syllable movement",
     string.format("%.1f dB peak to peak in the detector", raw))

  local ptpA, meanA = stats(res, A0, A1)
  local ptpB, meanB = stats(res, B0, B1)
  ok(ptpA < 1.5, "inside a phrase the curve ignores the syllables",
     string.format("%.2f dB peak to peak against %.1f in the level", ptpA, raw))
  ok(ptpB < 1.5, "and in the second phrase", string.format("%.2f dB", ptpB))
  near(meanB - meanA, 6.0, 1.0, "the 6 dB phrase-to-phrase step survives")
  ok(ptpA < raw / 8, "the curve moves less than an eighth as much as the level",
     string.format("%.2f vs %.1f", ptpA, raw))

  -- The gap between phrases must not dip toward the breath level.
  local _, _, gap_lo = stats(res, 10 + 9.0, 10 + 10.5)
  ok(gap_lo >= meanA - 0.75, "no dip in the gap between phrases",
     string.format("lowest %.2f, phrase A %.2f", gap_lo, meanA))

  -- Room tone before the first phrase holds the first phrase's level.
  local _, lead = stats(res, 10.0, 10.5)
  near(lead, res.curve[math.floor(3.0 / res.grid)], 1.0,
       "the lead-in holds the first phrase's level")

  -- Calibration: the curve during a phrase sits at that phrase's median
  -- detector level, in the rider's units. Worked out from the fixture: 17
  -- frames at +3 or +7 and 8 at -10 per syllable, so the median frame is a
  -- vowel -- the one-pole blurs this, so allow a couple of dB.
  local med = Curve.median((function()
    local t = {}
    for j, tt in ipairs(res.t) do if tt >= A0 and tt <= A1 then t[#t + 1] = res.level[j] end end
    return t
  end)())
  near(meanA, med, 1.0, "the phrase level is the median of the rider's detector")

  ok(#res.points < 80, "simplified to a sensible point count",
     string.format("%d points for %d grid points", #res.points, #res.curve))
end

----------------------------------------------------------------- the stages

do
  say("db10 / median")
  near(Curve.db10(1), 0, 1e-12, "db10(1) = 0")
  near(Curve.db10(0.01), -20, 1e-9, "db10(0.01) = -20")
  ok(Curve.db10(0) == Curve.FLOOR_DB, "db10(0) is the floor")
  ok(Curve.median({ 3, 1, 2 }) == 2, "odd median")
  ok(Curve.median({ 4, 1, 3, 2 }) == 2.5, "even median")
end

do
  say("merge")
  local F = Curve.merge({ { t = 1.004, e = { 1, 1, 1 } },     -- rounds to frame 0
                          { t = 1.016, e = { 2, 2 } } },      -- rounds to frame 2
                        1.0, 1.1, 0.01)
  ok(F.n == 10, "span 0.1 s at 10 ms is 10 frames", tostring(F.n))
  ok(F.E[1] == 1 and F.E[2] == 1, "a clip's offset is rounded, not truncated",
     table.concat(F.E, ","))
  ok(F.E[3] == 3, "overlapping clips sum", tostring(F.E[3]))
  ok(F.E[5] == 0 and F.E[10] == 0, "uncovered frames are silent")
  local G = Curve.merge({ { t = 0.95, e = { 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 } } },
                        1.0, 1.05, 0.01)
  ok(#G.E == 5 and G.E[1] == 5, "frames outside the span are dropped")
end

do
  say("detector")
  local E = {}
  for i = 1, 200 do E[i] = e_of(-20) end
  local L = Curve.detector(E, 0.01, 0.05)
  near(L[200], -20, 1e-6, "settles on the steady level")
  -- One-pole from zero: after one time constant, 1 - 1/e of the way in energy.
  near(10 ^ (L[5] / 10) / e_of(-20), 1 - math.exp(-1), 1e-9,
       "reaches 63% of the energy after one time constant")
end

do
  say("gate")
  local L = {}
  for i = 1, 50 do L[i] = -20 end
  for i = 51, 60 do L[i] = -45 end        -- a breath, above the absolute gate
  for i = 61, 70 do L[i] = -90 end        -- silence
  local act, med, thresh = Curve.gate(L, -50, 20)
  near(med, -20, 1e-9, "median over frames above the absolute gate")
  near(thresh, -40, 1e-9, "relative gate sits 20 dB under it")
  ok(act[1] and not act[55] and not act[65], "voice in, breath and silence out")
  local none, msg = Curve.gate({ -90, -90 }, -50, 20)
  ok(none == nil and msg ~= nil, "nothing above the gate is an error, not a flat curve")
end

do
  say("outline")
  local Ld, Ad = {}, {}
  for j = 1, 41 do Ld[j] = (j % 2 == 0) and -10 or -30 Ad[j] = true end
  Ld[20] = 0                               -- a single burst
  local med, cov = Curve.outline(Ld, Ad, 10)
  ok(med[21] == -10 or med[21] == -30 or (med[21] > -30 and med[21] < -10),
     "the median lands inside the body of the distribution")
  ok(med[20] ~= 0, "a single burst does not move the median")
  near(cov[21], 1, 1e-12, "full coverage where every point is singing")
  local Bd = {}
  for j = 1, 41 do Bd[j] = j <= 3 end
  local med2 = Curve.outline(Ld, Bd, 10)
  ok(med2[30] == false, "a window with too little singing says nothing")
end

do
  say("smooth")
  local med, cov = {}, {}
  for j = 1, 100 do med[j] = (j <= 50) and -20 or -10 cov[j] = 1 end
  local s = Curve.smooth(med, cov, 5)
  near(s[1], -20, 1e-6, "flat stays flat")
  near(s[50] + s[51], -30, 1e-6, "zero phase: symmetric about the step")
  local hole = {}
  for j = 1, 100 do hole[j] = med[j] end
  for j = 40, 60 do hole[j] = false end
  local h = Curve.smooth(hole, cov, 2)
  near(h[42], -20, 0.01, "a gap is not pulled toward silence")
  ok(h[50] == false, "far inside a gap there is nothing to smooth")
  local s0 = Curve.smooth(med, cov, 0)
  ok(s0[50] == -20 and s0 ~= med, "sigma 0 is a copy")
end

do
  say("fill")
  local c = { false, -20, false, false, false, -10, false }
  Curve.fill(c)
  ok(c[1] == -20 and c[7] == -10, "the ends hold")
  near(c[4], -15, 1e-12, "a gap is a straight line")
  local none, msg = Curve.fill({ false, false })
  ok(none == nil and msg ~= nil, "nothing at all is an error")
end

do
  say("shape")
  local c = { -30, -20, -10 }
  local valid = { true, true, true }
  local s, mid = Curve.shape(c, valid, 50, 20, 0)
  ok(mid == -20, "pivot is the median")
  near(s[1], -25, 1e-12, "depth 50% halves the deviation below")
  near(s[3], -15, 1e-12, "and above")
  local r = Curve.shape(c, valid, 100, 4, 0)
  near(r[1], -24, 1e-12, "range caps the deviation")
  near(r[3], -16, 1e-12, "both ways")
  local o = Curve.shape(c, valid, 100, 20, 3)
  near(o[2], -17, 1e-12, "offset shifts everything")
  local z = Curve.shape({ -60, -50 }, { true, true }, 100, 20, 0)
  ok(z[1] == Config.TARGET_MIN, "clamped to the rider's target range")
  local d0 = Curve.shape(c, valid, 0, 20, 0)
  ok(d0[1] == -20 and d0[3] == -20, "depth 0 is flat at the median")
  local pv = Curve.shape({ -10, -10, -30 }, { false, false, true }, 0, 20, 0)
  ok(pv[1] == -30, "the pivot comes from the singing points only")
end

do
  say("simplify")
  local t, v = {}, {}
  for i = 1, 101 do t[i] = i * 0.05 v[i] = -20 + 0.1 * i end
  ok(#Curve.simplify(t, v, 0.01) == 2, "a straight line is two points")
  for i = 1, 101 do v[i] = -20 + 3 * math.sin(i / 7) end
  local tol = 0.1
  local idx = Curve.simplify(t, v, tol)
  local pts = {}
  for k, i in ipairs(idx) do pts[k] = { t = t[i], v = v[i] } end
  local worst = 0
  for i = 1, 101 do
    worst = math.max(worst, math.abs(Curve.eval_points(pts, t[i]) - v[i]))
  end
  ok(worst <= tol + 1e-9, "the written envelope stays within tolerance",
     string.format("worst %.4f dB with %d points", worst, #idx))
  ok(idx[1] == 1 and idx[#idx] == 101, "ends kept")
end

do
  say("build: a whole curve at the edges of the settings")
  local E = {}
  gap(E, 0.5)
  phrase(E, -22, 3)
  local F = { t0 = 0, hop = HOP, n = #E, E = E }
  local cfg = Config.new()
  cfg.outline_s, cfg.smooth_s = 0.5, 0
  local r = Curve.build(F, cfg)
  ok(r ~= nil and #r.points >= 2, "shortest outline, no smoothing")
  cfg.outline_s, cfg.smooth_s, cfg.depth_pct = 8, 5, 0
  local r2 = Curve.build(F, cfg)
  local ptp = stats(r2, 0, 4)
  ok(r2 ~= nil and ptp < 1e-9, "depth 0 writes a flat line")
  ok(#r2.points == 2, "and a flat line is two points", tostring(#r2.points))
  local silent = { t0 = 0, hop = HOP, n = 100, E = {} }
  for i = 1, 100 do silent.E[i] = 0 end
  local r3, msg = Curve.build(silent, Config.new())
  ok(r3 == nil and msg ~= nil, "silence is an error, not a curve")
end

do
  say("config")
  for _, list in ipairs({ Config.ANALYSIS_KEYS, Config.CURVE_KEYS, Config.OUTPUT_KEYS }) do
    for _, k in ipairs(list) do
      ok(Config.defaults[k] ~= nil, "class key '" .. k .. "' has a default")
    end
  end
  local a, b = Config.new(), Config.new()
  b.depth_pct = 50
  ok(Config.analysis_sig(a) == Config.analysis_sig(b), "depth does not invalidate the read")
  ok(Config.curve_sig(a) ~= Config.curve_sig(b), "but does change the curve")
  b.use_timesel = true
  ok(Config.analysis_sig(a) ~= Config.analysis_sig(b), "the time selection does invalidate it")

  -- Every key a control names must exist; every setting should have a control.
  local fh = io.open(script_dir .. "le/ui.lua", "rb")
  local srcui = fh and fh:read("a") or ""
  if fh then fh:close() end
  local seen = {}
  for key in srcui:gmatch('slider%(%b"",%s*"([%w_]+)"') do seen[key] = true end
  for key in srcui:gmatch('checkbox%(%b"",%s*"([%w_]+)"') do seen[key] = true end
  local n = 0
  for key in pairs(seen) do
    n = n + 1
    ok(Config.defaults[key] ~= nil, "control key '" .. key .. "' exists in the defaults")
  end
  ok(n >= 10, "the source scan found the controls", tostring(n))
  for key in pairs(Config.defaults) do
    if not key:match("^dest_") then
      ok(seen[key], "setting '" .. key .. "' has a control")
    end
  end
end

report()
