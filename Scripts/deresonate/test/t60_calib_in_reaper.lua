-- CALIBRATION: what does the band ring statistic report for a KNOWN T60?
--
-- `t60_of` in the panel uses the measured per-band ring times for their SHAPE
-- and takes the absolute level from a hand-set control, because the README
-- says the ring figure reads 0.14-0.18 s where the true T60 is nearer 0.44 s.
-- That factor was read off two reference takes. Before any auto mode can set
-- T60 from the measurement, the factor has to be measured against ground
-- truth, and it has to be known whether it is a CONSTANT or whether it moves
-- with the material.
--
-- The instrument: a dry signal with gaps, plus parallel feedback combs set to
-- an exact T60 (the same reverberator `dereverb_in_reaper.lua` uses -- combs
-- only, no allpass, because a g=0.7 allpass rings for 0.8 s of its own accord
-- and would make the fixture lie about its own decay). Sweep T60 AND the
-- wet/dry mix, because the ring statistic is the FASTEST decay a band
-- achieves, and a dry-dominated recording hands it the direct sound stopping
-- rather than the room decaying. If k moves with the mix, an auto T60 needs a
-- direct-to-reverberant term and not just a constant.
--
-- This is a measurement script. It prints a table and asserts only what must
-- hold for the measurement to mean anything.
--
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/t60_calib_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "") .. package.path

local pass, fail = 0, 0
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function report()
  print(string.format("\nt60_calib: %d passed, %d failed", pass, fail))
end
local function bail(m)
  fail = fail + 1; print("  FAIL " .. m)
  report()
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui") end
local ImGui    = require "imgui" "0.9"
local Config   = require "dr.config"
local Kernel   = require "dr.kernel"
local Analyze  = require "dr.analyze"
local Ring     = require "dr.ring"
local Edc      = require "dr.edc"
local Fixture  = require "fixture"

local ctx = ImGui.CreateContext("DeResonate t60 calib")
local cfg = Config.new()
local RATE = cfg.pitch_rate            -- the ring pass reads here; the band
                                       -- map is built from _PRATE

-- ------------------------------------------------------------------ fixture

-- Deterministic noise, so two runs of this script are comparable.
local seed = 12345
local function rnd()
  seed = (1103515245 * seed + 12345) % 2147483648
  return seed / 2147483648 * 2 - 1
end

-- Bursts with generous gaps. `kind` picks what fills a burst: noise excites
-- every ring band, a harmonic stack is what a voice actually hands it.
local BURST = 0.30
local function make_dry(t60, kind)
  local gap  = math.max(0.70, 2.0 * t60)
  local nrep = 12
  local per  = math.floor((BURST + gap) * RATE)
  local blen = math.floor(BURST * RATE)
  local x = {}
  for i = 1, per * nrep do x[i] = 0 end
  for r = 0, nrep - 1 do
    local t0 = r * per
    local f0 = 150 + 35 * (r % 4)
    for i = 0, blen - 1 do
      local env = math.min(1, i / (0.02 * RATE), (blen - i) / (0.02 * RATE))
      local s
      if kind == "noise" then
        s = rnd()
      else
        s = 0
        for h = 1, 12 do s = s + (1 / h) * math.sin(2 * math.pi * f0 * h * i / RATE) end
        s = s / 2
      end
      x[t0 + i + 1] = 0.30 * env * s
    end
  end
  return x
end

-- Parallel feedback combs, each set to the same T60. Delays scaled to this
-- rate and kept mutually prime.
local COMBS = { 281, 269, 347, 379, 401, 457 }
local function tail_of(x, t60)
  local y = {}
  for i = 1, #x do y[i] = 0 end
  for _, D in ipairs(COMBS) do
    local g = 10 ^ (-3.0 * D / (t60 * RATE))
    local buf, p = {}, 1
    for i = 1, D do buf[i] = 0 end
    for n = 1, #x do
      local v = buf[p]
      y[n] = y[n] + v / #COMBS
      buf[p] = x[n] + g * v
      p = p + 1; if p > D then p = 1 end
    end
  end
  return y
end

-- A recording's own noise floor is continuous with the material above it --
-- that is what `spectrum.floor_bin` uses to tell it from edited silence. A
-- fixture whose gaps decay into DIGITAL silence would trip that guard and be
-- measuring something else entirely.
local FLOOR_DB = -85
local function mix(dry, tail, wet)
  local a = 10 ^ (FLOOR_DB / 20)
  local out = {}
  for i = 1, #dry do
    out[i] = (1 - wet) * dry[i] + wet * tail[i] * 3.0 + a * rnd()
  end
  return out
end

-- How wet the mix actually came out, in the only terms that matter to a
-- listener: energy in the gaps against energy in the bursts. `wet` is a mix
-- coefficient; this is the direct-to-reverberant ratio it produced.
local function gap_ratio(sig, t60)
  local gap  = math.max(0.70, 2.0 * t60)
  local per  = math.floor((BURST + gap) * RATE)
  local blen = math.floor(BURST * RATE)
  local g, b = 0, 0
  for r = 0, 11 do
    local t0 = r * per
    for i = t0 + 1, math.min(#sig, t0 + blen) do b = b + sig[i] * sig[i] end
    -- skip the first 80 ms of the gap: that is the burst's own release
    for i = t0 + blen + math.floor(0.08 * RATE) + 1, math.min(#sig, t0 + per) do
      g = g + sig[i] * sig[i]
    end
  end
  return 10 * math.log(g / (b + 1e-30) + 1e-30, 10)
end

-- ------------------------------------------------------------------- kernel

local k = Kernel.new(ImGui, ctx, root, 1, cfg)
if not k then bail("kernel would not build") end

local function feed_ring(sig)
  k:rewind()
  local n, i = #sig, 1
  while i <= n do
    local m = math.min(k.block, n - i + 1)
    for j = 1, m do k.inbuf[j] = sig[i + j - 1] end
    k:ring(m)
    i = i + m
  end
end

-- The decay cube's answer: T60 fitted in the pauses, medianed over the bands
-- that collected enough fits. This is the estimator the auto mode prefers.
local function decay_t60()
  local hists, gaps = k:edc_hist()
  local times = Edc.run(hists, cfg, Kernel.ring_time_of, k.nband)
  local med, nb = Edc.median(times, k.nband)
  return med, nb, gaps
end

-- The ring figure the panel reports: median over the bands that have a
-- statistic at all.
local function ring_p50()
  local hists = k:ring_hist(cfg)
  local all, times = {}, {}
  for b = 1, k.nband do
    times[b] = Ring.time_from_hist(hists[b], cfg, Kernel.ring_time_of)
    if times[b] then all[#all + 1] = times[b] end
  end
  table.sort(all)
  if #all == 0 then return nil, 0, times end
  return all[math.max(1, math.floor(0.5 * #all))], #all, times
end

-- Direct-to-reverberant proxy, from the per-band level histogram the same
-- pass already built: how far the tail-dominated percentile sits under the
-- direct-dominated one. This is the band-resolution form of what
-- `Spectrum.room_balance` computes from the modal cube.
local function drr_proxy()
  local lev = k:read(k.addr.rlev, k.nband * k.nlev)
  local gaps = {}
  for b = 1, k.nband do
    local base, total = (b - 1) * k.nlev, 0
    for i = 1, k.nlev do total = total + lev[base + i] end
    if total > 0 then
      local function pct(p)
        local want, run = p * total, 0
        for i = 1, k.nlev do
          run = run + lev[base + i]
          if run >= want then return k.lev0 + (i - 1) end
        end
        return k.lev0 + k.nlev - 1
      end
      gaps[#gaps + 1] = pct(0.90) - pct(0.20)
    end
  end
  table.sort(gaps)
  if #gaps == 0 then return nil end
  return gaps[math.max(1, math.floor(0.5 * #gaps))]
end

-- --------------------------------------------------------------- the sweep

print("\n  synthetic: noise bursts + combs of known T60")
print("  true T60   wet   gap/burst   ring p50   bands   k = T60/ring   p90-p20"
      .. "   decay T60  bands  pauses")

local T60S = { 0.15, 0.20, 0.30, 0.40, 0.55, 0.70, 0.90, 1.10, 1.60 }
local WETS = { 0.00, 0.35 }
local rows = {}

for _, t60 in ipairs(T60S) do
  local dry  = make_dry(t60, "noise")
  local tail = tail_of(dry, t60)
  for _, wet in ipairs(WETS) do
    local sig = mix(dry, tail, wet)
    local gr  = gap_ratio(sig, t60)
    feed_ring(sig)
    local p50, nb = ring_p50()
    local drr = drr_proxy()
    local dt, dnb, dgaps = decay_t60()
    rows[#rows + 1] = { t60 = t60, wet = wet, p50 = p50, nb = nb, drr = drr,
                        gr = gr, dt = dt, dnb = dnb }
    print(string.format("  %7.2f  %5.2f   %8.1f   %8s  %5d   %12s  %7s   %9s  %5d  %6d",
      t60, wet, gr,
      p50 and string.format("%.3f", p50) or "-", nb,
      (p50 and wet > 0) and string.format("%.2f", t60 / p50) or "-",
      drr and string.format("%.1f", drr) or "-",
      dt and string.format("%.2f", dt) or "-", dnb or 0, dgaps or 0))
  end
end

print("\n  synthetic: harmonic bursts (a voice's sparse spectrum) + the same combs")
print("  true T60   wet    ring p50   bands   k = T60/ring   p90-p20")
local hrows = {}
for _, t60 in ipairs({ 0.40, 0.70 }) do
  local dry  = make_dry(t60, "harm")
  local tail = tail_of(dry, t60)
  for _, wet in ipairs({ 0.35, 0.70 }) do
    local sig = mix(dry, tail, wet)
    feed_ring(sig)
    local p50, nb = ring_p50()
    local drr = drr_proxy()
    hrows[#hrows + 1] = { t60 = t60, wet = wet, p50 = p50, nb = nb, drr = drr }
    print(string.format("  %7.2f  %5.2f   %8s  %5d   %12s  %7s",
      t60, wet,
      p50 and string.format("%.3f", p50) or "-", nb,
      p50 and string.format("%.2f", t60 / p50) or "-",
      drr and string.format("%.1f", drr) or "-"))
  end
end

-- ------------------------------------------------------- the real reference

-- Anchor the synthetic numbers to the two takes the README quotes: if these
-- do not reproduce 0.14-0.18 s, the fixture is measuring something else.
local TAKES = {
  { name = "Room resonance example.wav", len = 54.0 },
  { name = "Room reverb example.wav",    len = 31.0 },
}

local function ring_of_take(track, path, len)
  local _, take = Fixture.add_item(track, path, 0, len, 1.0)
  if not take then return nil, "could not build the item" end
  local geo = Analyze.geometry(take)
  local aa  = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil, "no accessor" end
  local span = math.min(reaper.GetAudioAccessorEndTime(aa) - reaper.GetAudioAccessorStartTime(aa),
                        geo.item_len)
  -- a second kernel, because this take's channel count need not be 1
  local kk = Kernel.new(ImGui, ctx, root, geo.nchan, cfg)
  if not kk then reaper.DestroyAudioAccessor(aa); return nil, "kernel" end
  kk:rewind()
  local total, done = math.floor(span * RATE), 0
  local buf = reaper.new_array(kk.block * geo.nchan)
  while done < total do
    local n = math.min(kk.block, total - done)
    buf.clear(0)
    local got = reaper.GetAudioAccessorSamples(aa, RATE, geo.nchan, done / RATE, n, buf)
    if got == nil then
      reaper.DestroyAudioAccessor(aa)
      return nil, "accessor read failed on the main thread"
    end
    local t = buf.table(1, n * geo.nchan)
    for i = 1, n * geo.nchan do kk.inbuf[i] = t[i] end
    kk:ring(n)
    done = done + n
  end
  reaper.DestroyAudioAccessor(aa)

  local hists = kk:ring_hist(cfg)
  local all = {}
  for b = 1, kk.nband do
    local t = Ring.time_from_hist(hists[b], cfg, Kernel.ring_time_of)
    if t then all[#all + 1] = t end
  end
  table.sort(all)
  local p50 = (#all > 0) and all[math.max(1, math.floor(0.5 * #all))] or nil

  local eh, egaps = kk:edc_hist()
  local et = Edc.run(eh, cfg, Kernel.ring_time_of, kk.nband)
  local emed, enb = Edc.median(et, kk.nband)
  pcall(ImGui.Detach, ctx, kk.func)
  return p50, #all, emed, enb, egaps
end

local real = {}
local _, _, clean = Fixture.run(function(track)
  for _, t in ipairs(TAKES) do
    local path = root .. t.name
    local fh = io.open(path, "r")
    if fh then
      fh:close()
      local p50, nb, dt, dnb, dgaps = ring_of_take(track, path, t.len)
      real[#real + 1] = { name = t.name, p50 = p50, nb = nb,
                          dt = dt, dnb = dnb, dgaps = dgaps }
    else
      real[#real + 1] = { name = t.name, err = "missing" }
    end
  end
end)

print("\n  the reference takes (README quotes 0.14-0.18 s for these)")
for _, r in ipairs(real) do
  print(string.format("  %-32s ring %s (%s bands)   decay T60 %s (%s bands, %s pauses)",
    r.name,
    r.p50 and string.format("%.3f s", r.p50) or ("-- " .. tostring(r.err)),
    tostring(r.nb or 0),
    r.dt and string.format("%.2f s", r.dt) or "--",
    tostring(r.dnb or 0), tostring(r.dgaps or 0)))
end

-- ------------------------------------------------------------- assertions

-- These are what make the table above a measurement rather than a printout.
local measured = 0
for _, r in ipairs(rows) do if r.p50 then measured = measured + 1 end end
ok(measured == #rows, "every synthetic case produced a ring figure",
   string.format("%d of %d", measured, #rows))

-- Monotonic in T60 at a fixed mix: if the statistic does not move with the
-- room's actual decay, nothing can be calibrated from it.
for _, wet in ipairs(WETS) do
  if wet > 0 then
    local seq = {}
    for _, r in ipairs(rows) do if r.wet == wet and r.p50 then seq[#seq + 1] = r end end
    local mono = #seq > 1
    for i = 2, #seq do if seq[i].p50 < seq[i - 1].p50 then mono = false end end
    ok(mono, string.format("ring figure rises with true T60 at wet %.2f", wet))
  end
end

-- The dry floor. With no reverb at all the statistic measures the burst's own
-- release through the ring window, so it cannot read below this whatever the
-- material -- which is the number that bounds how dry an auto T60 can claim a
-- room is.
local dry_floor, dry_spread = nil, 0
do
  local vals = {}
  for _, r in ipairs(rows) do if r.wet == 0 and r.p50 then vals[#vals + 1] = r.p50 end end
  table.sort(vals)
  if #vals > 0 then
    dry_floor = vals[1]
    dry_spread = vals[#vals] - vals[1]
  end
end
ok(dry_floor ~= nil, "the dry case reports a floor")
ok(dry_spread <= 0.02, "the dry floor does not move with the (absent) reverb",
   dry_floor and string.format("%.3f .. %.3f s", dry_floor, dry_floor + dry_spread))

-- The calibration itself: least squares on log(T60) against log(ring), which
-- is the form the table above is in -- the statistic compresses the range
-- badly, so a constant factor cannot fit it and a power law can.
local fit_a, fit_b
do
  local xs, ys = {}, {}
  for _, r in ipairs(rows) do
    if r.wet > 0 and r.p50 then
      xs[#xs + 1] = math.log(r.p50); ys[#ys + 1] = math.log(r.t60)
    end
  end
  local n = #xs
  if n >= 3 then
    local mx, my = 0, 0
    for i = 1, n do mx = mx + xs[i]; my = my + ys[i] end
    mx, my = mx / n, my / n
    local sxy, sxx = 0, 0
    for i = 1, n do
      sxy = sxy + (xs[i] - mx) * (ys[i] - my)
      sxx = sxx + (xs[i] - mx) ^ 2
    end
    fit_b = sxy / sxx
    fit_a = math.exp(my - fit_b * mx)
    print(string.format("\n  fit over %d wet cases:  T60 = %.1f * ring^%.2f", n, fit_a, fit_b))
    print("  true T60   fitted    error")
    local worst = 0
    for _, r in ipairs(rows) do
      if r.wet > 0 and r.p50 then
        local est = fit_a * r.p50 ^ fit_b
        local err = est / r.t60 - 1
        if math.abs(err) > worst then worst = math.abs(err) end
        print(string.format("  %7.2f   %6.2f   %+6.0f%%", r.t60, est, err * 100))
      end
    end
    print(string.format("  worst error %.0f%%", worst * 100))
    ok(worst < 0.35, "the fit is within 35% everywhere it was measured",
       string.format("worst %.0f%%", worst * 100))
    for _, r in ipairs(real) do
      if r.p50 then
        print(string.format("  -> %-32s ring %.3f s  =>  T60 %.2f s",
          r.name, r.p50, fit_a * r.p50 ^ fit_b))
      end
    end
  end
end

-- ---- the decay cube, which is what the auto mode actually prefers ----
-- Its whole claim is that conditioning on "the voice has stopped" measures the
-- ROOM, where the ring statistic measures whichever of the two stops faster.
-- These are the assertions that hold it to that.
do
  local worst, worst_at = 0, nil
  local measured = 0
  for _, r in ipairs(rows) do
    if r.wet > 0 then
      if r.dt then
        measured = measured + 1
        local err = math.abs(r.dt / r.t60 - 1)
        if err > worst then worst, worst_at = err, r.t60 end
      end
    end
  end
  ok(measured == 9, "the decay cube measured every reverberant case",
     string.format("%d of 9", measured))
  ok(worst < 0.25, "and lands within 25% of the known T60 everywhere",
     string.format("worst %.0f%% at T60 %.2f", worst * 100, worst_at or 0))

  -- Biased low is the safe direction: too short a T60 only means the dereverb
  -- does less, too long means it subtracts the singer's own sustain.
  local high = 0
  for _, r in ipairs(rows) do
    if r.wet > 0 and r.dt and r.dt > r.t60 * 1.10 then high = high + 1 end
  end
  ok(high == 0, "and never more than 10% high", high .. " case(s) were")

  -- The ring law saturates and the decay cube must not: over this span the
  -- ring figure moves 2.3x while the real decay moves 10.7x.
  local lo, hi = nil, nil
  for _, r in ipairs(rows) do
    if r.wet > 0 and r.dt then
      if not lo or r.t60 < 0.16 then lo = lo or r.dt end
      hi = r.dt
    end
  end
  ok(lo and hi and (hi / lo) > 6.0,
     "and spans the range instead of compressing it like the ring figure",
     lo and hi and string.format("%.1fx", hi / lo))

  local dry_measured = 0
  for _, r in ipairs(rows) do
    if r.wet == 0 and r.dt then dry_measured = dry_measured + 1 end
  end
  ok(dry_measured == 0, "and refuses the dry cases outright rather than guessing",
     dry_measured .. " reported a T60")
end

-- The reference takes carry an independent figure: the README quotes ~0.44 s.
for _, r in ipairs(real) do
  if r.dt then
    ok(r.dt > 0.30 and r.dt < 0.60,
       "decay T60 agrees with the independent ~0.44 s on " .. r.name,
       string.format("%.2f s", r.dt))
  end
end

ok(clean ~= false, "the project was left as it was found")

report()
if os.exit then os.exit(fail == 0 and 0 or 1) end
