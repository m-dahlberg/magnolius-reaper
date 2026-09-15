-- Does the multiband gate actually CUT THE TAIL, and what does it cost?
--
-- The sibling suites establish that the stage is transparent when inert, that
-- its latency is exact and that its band levels are in the units the analysis
-- reports. None of that says it does its job. The repository's own history is
-- the argument for this file: `inject_in_reaper.lua` found that the ring test
-- could not see a resonance it was handed, and `dereverb_in_reaper.lua` found
-- that the dereverb removed no reverb at all -- both after every other suite
-- was green, and both of the same shape, a stage healthy on every measurement
-- except the one that matters. This file found the same thing twice while it
-- was being written: first a threshold rule that produced a 0.0 dB change, and
-- then the reason for it.
--
-- The fixture is `dereverb_in_reaper.lua`'s: harmonic bursts with generous
-- silent gaps, plus parallel feedback combs of a known T60, so the gaps hold
-- only tail. It also drives the AUTO path end to end -- the analysis passes run
-- over the fixture, the thresholds come out of `Gate.suggest`, and the render
-- uses them -- so a suggestion that lands in the wrong place fails here rather
-- than in somebody's session.
--
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/gate_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. (reaper.ImGui_GetBuiltinPath() and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "") .. package.path

local pass, fail = 0, 0
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function bail(m)
  fail = fail + 1; print("  FAIL " .. m)
  print(string.format("\ngate: %d passed, %d failed", pass, fail))
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui") end
local ImGui  = require "imgui" "0.9"
local Config = require "dr.config"
local Kernel = require "dr.kernel"
local Gate   = require "dr.gate"
local Ring   = require "dr.ring"
local Edc    = require "dr.edc"
local Auto   = require "dr.auto"

local RATE = 48000
local ctx = ImGui.CreateContext("gate test")

-- ---------------------------------------------------------------- fixture
local BURST, GAP = 0.45, 0.55
local NREP = 14
local T60  = 0.60

-- Generated at a given rate, because the two passes read at different ones:
-- the render at the take's rate, the ring and decay cubes at `pitch_rate`,
-- which is what the accessor decimates to. Driving the ring pass at 48 kHz
-- puts every partial at a sixth of its frequency, and the analysis then
-- describes a different signal from the one being rendered.
local function make_dry(rate)
  local n = math.floor((BURST + GAP) * NREP * rate)
  local x = {}
  for i = 1, n do x[i] = 0 end
  local marks = {}
  local hmax = rate / 2.2          -- stands in for the accessor's anti-aliasing
  for r = 0, NREP - 1 do
    local t0 = math.floor(r * (BURST + GAP) * rate)
    local len = math.floor(BURST * rate)
    local f0 = 180 + 40 * (r % 4)
    for i = 0, len - 1 do
      local env = math.min(1, i / (0.02 * rate), (len - i) / (0.02 * rate))
      local s = 0
      for h = 1, 10 do
        if f0 * h < hmax then s = s + (1 / h) * math.sin(2 * math.pi * f0 * h * i / rate) end
      end
      x[t0 + i + 1] = 0.15 * env * s
    end
    marks[#marks + 1] = { b0 = t0, b1 = t0 + len,
                          g0 = t0 + len, g1 = t0 + len + math.floor(GAP * rate) }
  end
  return x, marks
end

-- Parallel feedback combs at the stated T60 and nothing else. An allpass
-- diffuser would add a decay of its own and make the fixture lie about its T60.
local function reverberate(x, t60, wet, rate)
  local combs = { 1687, 1601, 2053, 2251, 2399, 2731 }
  local y = {}
  for i = 1, #x do y[i] = 0 end
  for _, D0 in ipairs(combs) do
    local D = math.max(8, math.floor(D0 * rate / 48000))
    local g = 10 ^ (-3.0 * D / (t60 * rate))
    local buf, p = {}, 1
    for i = 1, D do buf[i] = 0 end
    for n = 1, #x do
      local v = buf[p]
      y[n] = y[n] + v / #combs
      buf[p] = x[n] + g * v
      p = p + 1; if p > D then p = 1 end
    end
  end
  local out = {}
  for i = 1, #x do out[i] = (1 - wet) * x[i] + wet * y[i] * 3.0 end
  return out
end

local function energy(sig, a, b)
  local e = 0
  for i = math.max(1, a), math.min(#sig, b) do e = e + sig[i] * sig[i] end
  return e
end

-- Gap energy against burst energy, in dB. Lower = less tail for the same voice.
--
-- `skip` is how much of each gap to leave out, and TWO figures are taken,
-- because they answer different questions.
--
--   80 ms   the whole tail. Energy-weighted it is dominated by its own first
--           150 ms -- measured on this fixture the two frames either side of
--           +80 ms carry about two thirds of it -- and no gate can touch that
--           without eating note releases. A gate is NOT expected to move this.
--   250 ms  the exposed tail: the part a gate exists for, and the part the
--           spectral stage is weakest on.
local EARLY, LATE = 0.08, 0.25
local function tail_ratio(sig, marks, rate, skip)
  local g, b = 0, 0
  for _, m in ipairs(marks) do
    g = g + energy(sig, m.g0 + math.floor(skip * rate), m.g1)
    b = b + energy(sig, m.b0, m.b1)
  end
  return 10 * math.log(g / b + 1e-30, 10), b
end

local dry, marks = make_dry(RATE)
local wet = reverberate(dry, T60, 0.5, RATE)
local rdry = tail_ratio(dry, marks, RATE, EARLY)
local rwet, bwet = tail_ratio(wet, marks, RATE, EARLY)
local lwet = tail_ratio(wet, marks, RATE, LATE)
print(string.format("  fixture: dry %.1f dB, wet %.1f dB, exposed tail %.1f dB (T60 %.2f s)",
                    rdry, rwet, lwet, T60))
ok(rwet > rdry + 15, "the fixture has reverb in its gaps",
   string.format("dry %.1f -> wet %.1f", rdry, rwet))

local cfgbase = Config.new()
local k = Kernel.new(ImGui, ctx, root, 1, cfgbase)
if not k then bail("kernel would not build") end

-- ------------------------------------------------------- the auto suggestion
-- Exactly what dr/ui.lua's rederive() does, on the same fixture at the rate
-- the analysis reads.
local function analyse(signal_at_prate, cfg)
  k:rewind()
  local done = 0
  while done < #signal_at_prate do
    local n = math.min(k.block, #signal_at_prate - done)
    for i = 1, n do k.inbuf[i] = signal_at_prate[done + i] end
    k:ring(n); done = done + n
  end
  local hists = k:ring_hist(cfg)
  local rhz   = k:ring_hz()
  local times = {}
  for b = 1, k.nband do
    times[b] = Ring.time_from_hist(hists[b], cfg, Kernel.ring_time_of)
  end
  local et = Edc.run(k:edc_hist(), cfg, Kernel.ring_time_of, k.nband)
  local gp, gv, gf, gn = k:gate_levels(cfg)
  local t60s = {}
  for b = 1, k.nband do t60s[b] = et[b] or Auto.band_t60(times[b], 1.0) end
  return Gate.suggest(gp, gv, gf, rhz, t60s, k.nband, false, gn)
end

local PRATE = cfgbase.pitch_rate
local pdry = make_dry(PRATE)
local pwet = reverberate(pdry, T60, 0.5, PRATE)

local sug, why, nmeas = analyse(pwet, cfgbase)
ok(sug ~= nil, "the analysis suggests thresholds for the reverberant fixture", why)
if not sug then bail("no suggestion; nothing further can be measured") end
ok(nmeas >= 4, "and measures at least four bands", nmeas)
print("\n  " .. string.format("%-14s %-9s %-9s %-9s %-9s %s",
      "band", "pause", "voice", "floor", "thr", "release"))
print("  " .. string.rep("-", 68))
for g = 1, Gate.NBANDS do
  local e = sug[g]
  if e.measured then
    print(string.format("  %-14s %-9.1f %-9.1f %-9.1f %-9.1f %.0f ms",
      Gate.band_label(g), e.pause, e.voice, e.floor, e.thr, e.release * 1000))
  else
    print(string.format("  %-14s %s", Gate.band_label(g), e.why or "-"))
  end
end

-- ------------------------------------------------------------------- render
local function run(signal, cfg, gate)
  cfg._gate = gate
  k:begin_render(cfg, RATE, {}, cfg.dereverb_on and T60 or nil)
  local lat = Config.latency(cfg)
  local out, done = {}, 0
  local total = #signal + lat
  while done < total do
    local n = math.min(k.block, total - done)
    for i = 1, n do
      local j = done + i
      k.inbuf[i] = (j <= #signal) and signal[j] or 0
    end
    k:render(n)
    local o = k.outbuf.table(1, n)
    for i = 1, n do out[done + i] = o[i] end
    done = done + n
  end
  local shifted = {}
  for i = 1, #signal do shifted[i] = out[i + lat] or 0 end
  local r, b = tail_ratio(shifted, marks, RATE, EARLY)
  local l = tail_ratio(shifted, marks, RATE, LATE)
  return r, 10 * math.log(b / bwet + 1e-30, 10), l
end

local function shipped(domain)
  local c = Config.new()
  c.suppress_on = false
  c.dereverb_on = false
  c.gate_on = true
  c.gate_domain = domain
  return c
end

local function report(name, r, l, v)
  print(string.format("  %-26s %-10.1f %-10.1f %-10.2f", name, r, l, v))
end

-- Both domains, on the same fixture and the same suggested thresholds. They
-- are different machines -- one multiplies band gains onto STFT frames, the
-- other runs a Linkwitz-Riley tree at sample rate -- and the point of the
-- switch is that either can do the job, so both are held to it.
for _, domain in ipairs({ "spectral", "filterbank" }) do
  print(string.format("\n  -- %s", domain))
  print(string.format("  %-26s %-10s %-10s %-10s",
                      "setting", "tail dB", "exposed dB", "voice dB"))
  print("  " .. string.rep("-", 60))
  report("input (no processing)", rwet, lwet, 0.0)

  -- The BASELINE is the same chain at amount 0, and every claim below is made
  -- against it rather than against the untouched file. Neither domain is a
  -- null at unity gain and they are not-a-null in different ways: the STFT has
  -- a reconstruction floor, and the filterbank's allpass tree disperses energy
  -- in time -- magnitude-flat, as the selftest proves on steady tones, but it
  -- slightly flattens a decay, which reads as 0.4 dB MORE gap energy while the
  -- bursts do not move at all. Measuring the gate against the raw input would
  -- charge it for that.
  local cZ = shipped(domain); cZ.gate_amount = 0
  local r0, v0, l0 = run(wet, cZ, sug)
  report("baseline (amount 0)", r0, l0, v0)
  ok(math.abs(v0) < 0.3,
     domain .. ": at amount 0 the bursts are untouched -- no depth, no gain",
     string.format("%.2f dB", v0))

  -- 1. the gate alone, AT THE SHIPPED DEFAULT: expander, ratio 3, amount 60
  local rG, vG, lG = run(wet, shipped(domain), sug)
  report("gate (shipped default)", rG, lG, vG)
  ok(lG < l0 - 4.0,
     domain .. ": at the shipped default the gate takes the exposed tail off",
     string.format("%.1f -> %.1f dB", l0, lG))
  ok(vG - v0 > -0.5,
     domain .. ": and leaves the bursts alone -- not a broadband attenuator",
     string.format("%.2f dB on the voice", vG - v0))
  ok((lG - l0) < (vG - v0) - 4.0,
     domain .. ": so the tail falls far further than the voice does",
     string.format("tail %.1f dB, voice %.2f dB", lG - l0, vG - v0))
  ok(rG <= r0 + 0.1,
     domain .. ": and the whole-gap figure does not get worse",
     string.format("%.1f -> %.1f", r0, rG))

  -- 2. gate mode rather than expander
  local cH = shipped(domain); cH.gate_mode = "gate"
  local rH, vH, lH = run(wet, cH, sug)
  report("gate mode", rH, lH, vH)
  ok(lH < l0 - 4.0, domain .. ": gate mode removes the exposed tail too",
     string.format("%.1f dB", lH))
  ok(vH - v0 > -0.5, domain .. ": without taking the voice either",
     string.format("%.2f dB", vH - v0))

  -- 3. with the dereverb as well
  local cB = shipped(domain); cB.dereverb_on = true; cB.t60 = T60
  local rB, vB, lB = run(wet, cB, sug)
  report("dereverb + gate", rB, lB, vB)
  ok(lB < lG - 2.0,
     domain .. ": the two together beat the gate alone -- different failures",
     string.format("gate %.1f, both %.1f", lG, lB))

  -- 4. the baseline itself must be close to the input: whatever each domain
  --    does at unity gain has to be small, or "measured against baseline"
  --    would be hiding something rather than isolating the gate.
  ok(math.abs(l0 - lwet) < 1.0,
     domain .. ": and the baseline itself is within 1 dB of the untouched file",
     string.format("%.1f vs %.1f", l0, lwet))
end

-- the dereverb alone, for the comparison the two domains are read against
local cD = Config.new(); cD.suppress_on = false
cD.dereverb_on = true; cD.t60 = T60
local rD, vD, lD = run(wet, cD, nil)
print("")
report("dereverb alone", rD, lD, vD)

-- 5. On DRY material there is nothing to remove, and it must not invent any.
--    The reference is the SAME chain at amount 0, not the untouched file: both
--    domains do something to a signal even at unity gain -- the STFT has a
--    reconstruction floor, the filterbank an allpass -- and measuring either
--    against digital silence measures that instead of the gate.
local sugd, dwhy, dmeas = analyse(pdry, cfgbase)
print(string.format("\n  dry fixture: %s", sugd
  and string.format("%d bands suggested", dmeas or 0)
  or ("refused -- " .. tostring(dwhy))))

for _, domain in ipairs({ "spectral", "filterbank" }) do
  local cD0 = shipped(domain); cD0.gate_amount = 0
  local _, vD0, lD0 = run(dry, cD0, sugd)
  local _, vD1, lD1 = run(dry, shipped(domain), sugd)
  print(string.format("  dry %-11s exposed tail %.1f -> %.1f dB, voice %.2f dB",
                      domain, lD0, lD1, vD1 - vD0))
  ok(vD1 - vD0 > -0.5, domain .. ": on dry material the gate leaves the voice alone",
     string.format("%.2f dB", vD1 - vD0))
  ok(lD1 < -60.0,
     domain .. ": and what it adds to a silent gap sits far below the programme",
     string.format("%.1f dB", lD1))
end

print(string.format("\ngate: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
