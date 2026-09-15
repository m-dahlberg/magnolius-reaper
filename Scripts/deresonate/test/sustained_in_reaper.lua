-- What the spectral dereverb does with CONTINUOUS singing.
--
-- `dereverb_in_reaper.lua` drives bursts with generous silent gaps and the
-- stage does well there -- 5 dB of tail off at the shipped default. That
-- fixture cannot show the limit the stage actually has, and the limit is
-- provable in one line rather than merely suspected.
--
-- The late estimate is a decayed copy of what a bin held one lookback ago, and
-- the Berouti/Wiener gain is driven by snr = 10*log10(P(n) / lam). For
-- STATIONARY material P(n) ~= P(n-D), so
--
--     snr = -10*log10(decay) = 60 * tau / T60
--
-- and the reverb level is not in that expression at all. At T60 0.5 s and
-- tau 128 ms it is 15.4 dB, alpha ~ 1.55, and the gain lands at about -0.4 dB
-- HOWEVER reverberant the room is. The stage can only respond to CHANGES in
-- level: note ends, gaps, consonants. Under a held note it is blind.
--
-- This suite pins that down, so it is a known and measured property rather
-- than a surprise. A user hearing "it does nothing on my sustained vocal" is
-- hearing this, and the number is here.
--
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/sustained_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;" ..
  (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "") .. package.path

local pass, fail = 0, 0
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function bail(m)
  fail = fail + 1; print("  FAIL " .. m)
  print(string.format("\nsustained: %d passed, %d failed", pass, fail))
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui") end
local ImGui  = require "imgui" "0.9"
local Config = require "dr.config"
local Kernel = require "dr.kernel"

local RATE = 48000
local ctx = ImGui.CreateContext("DeResonate sustained")
local seed = 24680
local function rnd()
  seed = (1103515245 * seed + 12345) % 2147483648
  return seed / 2147483648 * 2 - 1
end

-- Parallel feedback combs and NOTHING else, the same reverberator the
-- dereverb suite uses: an allpass would ring on its own and make the fixture
-- lie about the room it is claiming to be.
local COMBS = { 1687, 1601, 2053, 2251, 2399, 2731 }
local function reverberate(x, t60)
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

local SECONDS = 24

-- A sung PHRASE: held notes that change pitch, with no gaps between them. This
-- is the case that matters -- continuous singing, where the spectral chain is
-- blind because nothing about the level changes, but which is still
-- non-stationary enough that the singer is not simply predictable from their
-- own past.
local function make_phrase()
  local n = SECONDS * RATE
  local x = {}
  local notes = { 196.0, 220.0, 246.9, 220.0, 174.6, 196.0, 261.6, 233.1 }
  local nlen = 0.8
  for i = 1, n do
    local t = (i - 1) / RATE
    local ni = math.floor(t / nlen) % #notes
    local f0 = notes[ni + 1]
    local ph = t - math.floor(t / nlen) * nlen
    -- a short attack and release, but the note never falls silent
    local env = math.min(1, ph / 0.03, (nlen - ph) / 0.03) * 0.7 + 0.3
    local s = 0
    for h = 1, 8 do s = s + (1 / h) * math.sin(2 * math.pi * f0 * h * t) end
    x[i] = 0.12 * s * env * (1 + 0.03 * math.sin(2 * math.pi * 5.2 * t))
  end
  return x
end

-- The material the stage is GOOD at: bursts with generous gaps, so every gap
-- holds only tail. This is the same shape `dereverb_in_reaper.lua` uses, and
-- it is here so the two cases sit side by side in one report.
local BURST_MARKS = {}
local function make_bursts()
  local BURST, GAP, NREP = 0.45, 0.55, 20
  local per, blen = math.floor((BURST + GAP) * RATE), math.floor(BURST * RATE)
  local x = {}
  for i = 1, per * NREP do x[i] = 0 end
  BURST_MARKS = {}
  for r = 0, NREP - 1 do
    local t0 = r * per
    local f0 = 180 + 40 * (r % 4)
    for i = 0, blen - 1 do
      local env = math.min(1, i / (0.02 * RATE), (blen - i) / (0.02 * RATE))
      local s = 0
      for h = 1, 10 do s = s + (1 / h) * math.sin(2 * math.pi * f0 * h * i / RATE) end
      x[t0 + i + 1] = 0.15 * env * s
    end
    BURST_MARKS[#BURST_MARKS + 1] =
      { t0 + 1, t0 + blen, t0 + blen, math.min(t0 + per, per * NREP) }
  end
  return x
end


local cfg = Config.new()
cfg.rfft_size   = 2048
cfg.dereverb_on = true
cfg.suppress_on = false

local k = Kernel.new(ImGui, ctx, root, 1, cfg)
if not k then bail("kernel would not build") end

local T60 = 0.5
local function wetten(x)
  local rev = reverberate(x, T60)
  local w = {}
  for i = 1, #x do w[i] = x[i] + 1.5 * rev[i] end
  return w
end

local function render(sig, c)
  k:begin_render(c, RATE, {}, T60)
  local out, done = {}, 0
  while done < #sig do
    local n = math.min(k.block, #sig - done)
    for i = 1, n do k.inbuf[i] = sig[done + i] end
    k:render(n)
    local o = k.outbuf.table(1, n)
    for i = 1, n do out[done + i] = o[i] end
    done = done + n
  end
  return out
end
local function rms_db(sig, from, to)
  local s, n = 0, 0
  for i = math.max(1, from), math.min(#sig, to) do s = s + sig[i] * sig[i]; n = n + 1 end
  return 10 * math.log(s / math.max(n, 1) + 1e-30, 10)
end

local a, b = 4 * RATE, (SECONDS - 4) * RATE
local lat = Config.latency(cfg)

-- ---------------------------------------------------- bursts: it works here
do
  local dry = make_bursts()
  local wet = wetten(dry)
  local g, bu = 0, 0
  for _, m in ipairs(BURST_MARKS) do
    for i = m[1], m[2] do bu = bu + wet[i] * wet[i] end
    for i = m[3] + math.floor(0.08 * RATE), m[4] do g = g + wet[i] * wet[i] end
  end
  local before = 10 * math.log(g / bu + 1e-30, 10)
  local out = render(wet, cfg)
  g, bu = 0, 0
  -- the output is delayed by the chain's latency, so every index shifts and
  -- the last burst's tail runs off the end
  local last = #out - lat
  for _, m in ipairs(BURST_MARKS) do
    for i = m[1], math.min(m[2], last) do bu = bu + out[i + lat] * out[i + lat] end
    for i = m[3] + math.floor(0.08 * RATE), math.min(m[4], last) do
      g = g + out[i + lat] * out[i + lat]
    end
  end
  local after = 10 * math.log(g / bu + 1e-30, 10)
  print(string.format("  bursts with gaps: tail %.1f -> %.1f dB", before, after))
  ok(before - after > 2.0,
     "with gaps in the material the spectral stage removes tail",
     string.format("%.1f dB", before - after))
end

-- ------------------------------------------ continuous singing: it does not
do
  local dry = make_phrase()
  local wet = wetten(dry)
  local before = rms_db(wet, a, b)
  local out = render(wet, cfg)
  local after = rms_db(out, a + lat, b + lat)
  local moved = math.abs(after - before)
  print(string.format("  sung phrase, no gaps: %.2f dB in, %.2f dB out (%.2f dB)",
    before, after, after - before))
  ok(moved < 0.5,
     "KNOWN LIMIT: on continuous singing it does essentially nothing",
     string.format("%.2f dB", after - before))
end

-- ------------------------------------------------- and the algebra is why
do
  -- the gain the rule lands on for stationary input, from the model alone
  local Gains = require "dr.gains"
  local tau = cfg.delay_frames * (cfg.rfft_size / 4) / RATE
  local snr = 60 * tau / T60
  local amax = Gains.amax(cfg)
  local alpha = Gains.alpha(snr, amax)
  local lam = 10 ^ (-snr / 10)
  local gain = 20 * math.log(Gains.wiener(1.0, lam, amax), 10)
  print(string.format("  stationary input: snr = 60*tau/T60 = %.1f dB, alpha %.2f, gain %.2f dB",
    snr, alpha, gain))
  ok(gain > -1.5,
     "and the model says so without any audio: the reverb level is not in the snr",
     string.format("%.2f dB", gain))
end

print(string.format("\nsustained: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
