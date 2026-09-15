-- Vocal Splitter -- in-REAPER self-test for the EEL feature kernel.
--
-- The headless tests cover stages 2-4 from synthetic frames. They cannot reach
-- stage 1, which needs ReaImGui's EEL JIT. This drives the kernel directly on
-- signals whose answers are known analytically, so it isolates the kernel from
-- the audio accessor and from REAPER's project state entirely.
--
-- Run it from the Actions list. Results go to the console.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowConsoleMsg("FAIL  ReaImGui is missing -- nothing was checked.\n")
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui  = require "imgui" "0.9"
local Config = require "vs.config"

local cfg  = Config.new()
local RATE = 48000
local HOP  = cfg.hop
local NF   = 200                       -- frames per test signal
local NS   = NF * HOP

local fails, checks = 0, 0
local function say(s) reaper.ShowConsoleMsg(s .. "\n") end
local function check(ok, msg, extra)
  checks = checks + 1
  if not ok then fails = fails + 1 end
  say(("  %s  %s%s"):format(ok and "ok  " or "FAIL", msg,
      extra and ("   (" .. extra .. ")") or ""))
end

reaper.ShowConsoleMsg("")
say("Vocal Splitter -- EEL kernel self-test\n")

-- compile ------------------------------------------------------------------
local fh = io.open(script_dir .. "vs/dsp/features.eel", "rb")
if not fh then
  check(false, "vs/dsp/features.eel is readable")
  if os.exit then os.exit(1) end
  return
end
local code = fh:read("a") fh:close()

local ctx = ImGui.CreateContext("vs selftest")
local ok, func = pcall(ImGui.CreateFunctionFromEEL, code)
check(ok and func ~= nil, "kernel compiles", not ok and tostring(func) or nil)
if not (ok and func) then if os.exit then os.exit(1) end return end
ImGui.Attach(ctx, func)

-- driver -------------------------------------------------------------------
local OUTS = { "SUMSQ", "PEAK", "ELOW", "EHIGH", "ZCR", "N" }
local inbuf = reaper.new_array(NS)
local out = {}
for _, n in ipairs(OUTS) do out[n] = reaper.new_array(NF) end

local function svf_g(hz) return math.tan(math.pi * math.min(hz, RATE * 0.49) / RATE) end

local addr = NS
local addrs = {}
for _, n in ipairs(OUTS) do addrs[n] = addr; addr = addr + NF end

-- Analyse a generator function over NS samples, return mean frame features.
local function measure(gen)
  for i = 1, NS do inbuf[i] = gen(i - 1) end

  ImGui.Function_SetValue(func, "_SAMPLES", 0)
  ImGui.Function_SetValue_Array(func, "_SAMPLES", inbuf)
  ImGui.Function_SetValue(func, "_NCHAN", 1)
  ImGui.Function_SetValue(func, "_HOP", HOP)
  ImGui.Function_SetValue(func, "_NSAMP", NS)
  ImGui.Function_SetValue(func, "_NFRAMES", NF)
  ImGui.Function_SetValue(func, "_RESET", 1)
  ImGui.Function_SetValue(func, "_G_LO", svf_g(cfg.lo_hz))
  ImGui.Function_SetValue(func, "_K_LO", 1 / cfg.svf_q)
  ImGui.Function_SetValue(func, "_G_HI", svf_g(cfg.hi_hz))
  ImGui.Function_SetValue(func, "_K_HI", 1 / cfg.svf_q)
  ImGui.Function_SetValue(func, "_R_DC", math.exp(-2 * math.pi * cfg.dc_hz / RATE))
  for _, n in ipairs(OUTS) do ImGui.Function_SetValue(func, "_OUT_" .. n, addrs[n]) end

  ImGui.Function_Execute(func)

  for _, n in ipairs(OUTS) do
    ImGui.Function_SetValue(func, "_OUT_" .. n, addrs[n])
    ImGui.Function_GetValue_Array(func, "_OUT_" .. n, out[n])
  end

  -- Skip the first 20 frames: the filters need to settle.
  local sq, lo, hi, zc, nn = 0, 0, 0, 0, 0
  local sumsq = out.SUMSQ.table(1, NF)
  local elow  = out.ELOW.table(1, NF)
  local ehigh = out.EHIGH.table(1, NF)
  local zcr   = out.ZCR.table(1, NF)
  for i = 21, NF do
    sq = sq + sumsq[i]; lo = lo + elow[i]; hi = hi + ehigh[i]
    zc = zc + zcr[i];   nn = nn + HOP
  end
  return {
    ms = sq / nn,
    voice = lo / (sq + 1e-20),
    sib   = hi / (sq + 1e-20),
    zcr   = zc * RATE / nn,
  }
end

local function sine(f, a)
  return function(n) return a * math.sin(2 * math.pi * f * n / RATE) end
end

-- tests --------------------------------------------------------------------
say("level")
local s = measure(sine(1000, 0.5))
-- a sine of amplitude a has mean square a^2/2
check(math.abs(s.ms - 0.125) < 0.002, "1 kHz @ 0.5 reads -9.0 dB",
      ("%.2f dB"):format(10 * math.log(s.ms, 10)))

local z = measure(function() return 0 end)
check(z.ms == 0, "silence reads zero energy")

say("\nvoicing band (lowpass at " .. cfg.lo_hz .. " Hz)")
local v = measure(sine(200, 0.5))
check(v.voice > 0.85, "200 Hz sine is voiced", ("voice_ratio %.3f"):format(v.voice))
check(v.sib < 0.01, "200 Hz sine is not sibilant", ("sib_ratio %.5f"):format(v.sib))

say("\nsibilance band (highpass at " .. cfg.hi_hz .. " Hz)")
local h = measure(sine(8000, 0.5))
check(h.sib > 0.85, "8 kHz sine is sibilant", ("sib_ratio %.3f"):format(h.sib))
check(h.voice < 0.02, "8 kHz sine is not voiced", ("voice_ratio %.5f"):format(h.voice))

say("\nthe two bands actually separate")
check(v.voice > cfg.voice_thresh and h.voice < cfg.voice_thresh,
      ("voice_thresh %.2f splits them"):format(cfg.voice_thresh))
check(h.sib > cfg.sib_thresh and v.sib < cfg.sib_thresh,
      ("sib_thresh %.2f splits them"):format(cfg.sib_thresh))

say("\nzero crossing rate")
check(math.abs(v.zcr - 400) < 20, "200 Hz sine crosses ~400 times/s",
      ("%.0f"):format(v.zcr))

say("\nfilter state carries across blocks")
-- Same signal in one block vs two: if state were reset per block the second
-- half would show a settling transient and the energies would differ.
local a = measure(sine(300, 0.5))
ImGui.Function_SetValue(func, "_RESET", 0)
local b = measure(sine(300, 0.5))
check(math.abs(a.voice - b.voice) < 0.02, "band energies are block-independent",
      ("%.4f vs %.4f"):format(a.voice, b.voice))

say(("\n%d/%d checks passed"):format(checks - fails, checks))
if fails > 0 then
  reaper.MB(("%d of %d checks failed -- see the console.")
            :format(fails, checks), "Vocal Splitter self-test", 0)
end
if os.exit then os.exit(fails == 0 and 0 or 1) end
