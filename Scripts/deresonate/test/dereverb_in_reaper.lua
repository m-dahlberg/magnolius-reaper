-- Does the dereverb actually REDUCE REVERB?
--
-- Every other test of this stage checked that it is transparent at 0 dB
-- reduction and that its latency is exact. Neither says the thing that
-- matters. This one builds a dry signal with silent gaps, adds reverberation
-- of a known T60, and measures the energy in the GAPS against the energy in
-- the BURSTS. A working dereverb lowers that ratio -- less tail, same voice.
-- A broadband attenuator lowers both equally and leaves the ratio alone,
-- which is what "it thins the signal but the reverb is still there" means.
--
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/dereverb_in_reaper.lua

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
  print(string.format("\ndereverb: %d passed, %d failed", pass, fail))
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui") end
local ImGui  = require "imgui" "0.9"
local Config = require "dr.config"
local Kernel = require "dr.kernel"

local RATE = 48000
local ctx = ImGui.CreateContext("dereverb test")

-- ---------------------------------------------------------------- fixture
-- Dry: harmonic bursts with generous silent gaps, so the gaps hold ONLY tail.
local BURST, GAP = 0.45, 0.55
local NREP = 14
local function make_dry()
  local n = math.floor((BURST + GAP) * NREP * RATE)
  local x = {}
  for i = 1, n do x[i] = 0 end
  local marks = {}
  for r = 0, NREP - 1 do
    local t0 = math.floor(r * (BURST + GAP) * RATE)
    local len = math.floor(BURST * RATE)
    local f0 = 180 + 40 * (r % 4)
    for i = 0, len - 1 do
      local env = math.min(1, i / (0.02 * RATE), (len - i) / (0.02 * RATE))
      local s = 0
      for h = 1, 10 do s = s + (1 / h) * math.sin(2 * math.pi * f0 * h * i / RATE) end
      x[t0 + i + 1] = 0.15 * env * s
    end
    marks[#marks + 1] = { b0 = t0, b1 = t0 + len, g0 = t0 + len, g1 = t0 + len + math.floor(GAP * RATE) }
  end
  return x, marks
end

-- Parallel feedback combs, each set to the same T60, and NOTHING else. An
-- allpass diffuser would add its own decay: a g=0.7 allpass rings for 0.8 s
-- regardless of what the combs are set to, which silently makes the fixture
-- lie about its own T60.
local function reverberate(x, t60, wet)
  local combs = { 1687, 1601, 2053, 2251, 2399, 2731 }
  local y = {}
  for i = 1, #x do y[i] = 0 end
  for _, D in ipairs(combs) do
    local g = 10 ^ (-3.0 * D / (t60 * RATE))
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

-- gap energy vs burst energy, in dB. Lower = less reverb relative to the voice.
local function tail_ratio(sig, marks)
  local g, b = 0, 0
  for _, m in ipairs(marks) do
    -- skip the first 80 ms of the gap: that is the note's own release
    g = g + energy(sig, m.g0 + math.floor(0.08 * RATE), m.g1)
    b = b + energy(sig, m.b0, m.b1)
  end
  return 10 * math.log(g / b + 1e-30, 10), b
end

local dry, marks = make_dry()
local T60 = 0.60
local wet = reverberate(dry, T60, 0.5)

local rdry = tail_ratio(dry, marks)
local rwet, bwet = tail_ratio(wet, marks)
print(string.format("  fixture: dry tail %.1f dB, wet tail %.1f dB (T60 %.2f s)", rdry, rwet, T60))
ok(rwet > rdry + 15, "the fixture actually has reverb in the gaps",
   string.format("dry %.1f -> wet %.1f", rdry, rwet))

-- ---------------------------------------------------------------- sweep
local cfgbase = Config.new()
local k = Kernel.new(ImGui, ctx, root, 1, cfgbase)
if not k then bail("kernel would not build") end

local function run(delay_frames, reduction, strength)
  local cfg = Config.new()
  cfg.dereverb_on = true
  cfg.delay_frames = delay_frames
  cfg.reduction = reduction
  cfg.strength = strength
  cfg.t60 = T60
  k:begin_render(cfg, RATE, {}, T60)
  local lat = Config.latency(cfg)
  local out, done = {}, 0
  local total = #wet + lat
  while done < total do
    local n = math.min(k.block, total - done)
    for i = 1, n do
      local j = done + i
      k.inbuf[i] = (j <= #wet) and wet[j] or 0
    end
    k:render(n)
    local o = k.outbuf.table(1, n)
    for i = 1, n do out[done + i] = o[i] end
    done = done + n
  end
  local shifted = {}
  for i = 1, #wet do shifted[i] = out[i + lat] or 0 end
  local r, b = tail_ratio(shifted, marks)
  return r, 10 * math.log(b / bwet + 1e-30, 10)
end

print(string.format("\n  %-8s %-10s %-10s %-10s %s", "D", "lookback", "tail dB", "voice dB", "verdict"))
print("  " .. string.rep("-", 66))
local best, bestd = nil, nil
for _, D in ipairs({ 1, 2, 4, 6, 8, 12, 16, 24 }) do
  local r, voice = run(D, 8, 70)
  local lookback = D * (cfgbase.rfft_size / 4) / RATE * 1000
  local gain = rwet - r                      -- how much tail came off
  local cost = -voice                        -- how much voice came off
  local verdict = (gain > 3 and cost < 3) and "GOOD" or
                  (cost >= 3 and gain <= cost and "just thinning") or ""
  print(string.format("  %-8d %-10s %-10s %-10s %s", D,
    string.format("%.0f ms", lookback), string.format("%.1f", r),
    string.format("%+.1f", voice), verdict))
  if not best or (gain - cost) > best then best, bestd = gain - cost, D end
end
print(string.format("\n  wet baseline: tail %.1f dB, voice 0.0 dB", rwet))
print(string.format("  best net (tail removed minus voice lost): D = %d", bestd or -1))

-- Assert at the SHIPPED DEFAULT, not at whatever the sweep found best.
-- The sweep is diagnostic; if the assertions ran on `bestd` they would pass
-- with any default at all, which is exactly how a 21 ms lookback shipped --
-- removing 0.1 dB of reverb while costing 7.6 dB of voice.
local D0 = Config.new().delay_frames
local r, voice = run(D0, 8, 70)
print(string.format("\n  at the shipped default D = %d (%.0f ms):", D0,
  D0 * (cfgbase.rfft_size / 4) / RATE * 1000))
ok(rwet - r > 3.0, "the default removes at least 3 dB of tail",
   string.format("%.1f -> %.1f dB", rwet, r))
ok(voice > -3.0, "without costing more than 3 dB of the voice itself",
   string.format("%+.1f dB", voice))
ok((rwet - r) > 2 * (-voice),
   "and takes at least twice as much tail as voice -- not an attenuator",
   string.format("tail -%.1f dB vs voice %.1f dB", rwet - r, voice))
ok(D0 * (cfgbase.rfft_size / 4) > cfgbase.rfft_size,
   "and the lookback is longer than the analysis window, so the frames do not overlap",
   string.format("%d vs %d samples", D0 * (cfgbase.rfft_size / 4), cfgbase.rfft_size))

print(string.format("\ndereverb: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
