-- Spectral DeNoise -- kernel self test. Run from the Actions list.
--
-- Drives the EEL kernel directly on synthetic signals with analytically known
-- answers, with no item, no accessor and no project state involved. Run this
-- first if anything looks wrong: it isolates the DSP from everything around
-- it, and it is the only test that can reach the EEL at all -- test/headless
-- checks the algorithms in Lua, but not their transcription.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Requires ReaImGui.", "DeNoise selftest", 0)
  -- A missing dependency is a failed run too, not a quiet pass.
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;" .. reaper.ImGui_GetBuiltinPath()
            .. "/?.lua;" .. package.path

local ImGui  = require "imgui" "0.9"
local Kernel = require "dn.kernel"
local Config = require "dn.config"

local ctx = ImGui.CreateContext("DeNoise selftest")
local SR = 48000

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(math.abs(a - b) <= tol, name, string.format("%.6g vs %.6g (tol %.3g)", a, b, tol))
end

local function cfg_of(t)
  local c = Config.new()
  c.reduction, c.gate_on, c.nlm, c.mode, c.residual = 0, false, 0, 0, false
  c.whitening, c.smoothing, c.strength = 0, 50, 30
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

local function make(cfg, nch)
  local k, err = Kernel.new(ImGui, ctx, script_dir, nch,
                            Config.fft_size(cfg), cfg.nlm, SR)
  if not k then error(tostring(err)) end
  return k
end

-- Push a generated signal through the process task and return it interleaved.
local function process(k, cfg, gen, nsamp, nch)
  k:set_params(cfg)
  k:reset()
  local res, done = {}, 0
  while done < nsamp do
    local n = math.min(k.block, nsamp - done)
    k.inbuf.clear(0)
    for i = 0, n - 1 do
      for c = 1, nch do k.inbuf[i * nch + c] = gen(done + i, c) end
    end
    k:process(n)
    local t = k.outbuf.table(1, n * nch)
    for i = 1, n * nch do res[done * nch + i] = t[i] end
    done = done + n
  end
  return res
end

local function analyse(k, cfg, gen, nsamp, nch)
  k:set_params(cfg)
  k:reset_analysis()
  k:set_stride(nsamp, cfg.max_frames)
  local done = 0
  while done < nsamp do
    local n = math.min(k.block, nsamp - done)
    k.inbuf.clear(0)
    for i = 0, n - 1 do
      for c = 1, nch do k.inbuf[i * nch + c] = gen(done + i, c) end
    end
    k:analyze(n)
    done = done + n
  end
  return k:frames()
end

local function rms(t, from, to, nch, ch)
  local s, n = 0, 0
  for i = from, to do
    local v = t[(i - 1) * nch + ch]
    s = s + v * v
    n = n + 1
  end
  return math.sqrt(s / math.max(n, 1))
end
local function db(x) return 20 * math.log(math.max(x, 1e-12), 10) end

-- rms over a plain 0-based mono array
local function rms0(t, from, to)
  local s, n = 0, 0
  for i = from, to do s = s + (t[i] or 0) ^ 2 n = n + 1 end
  return math.sqrt(s / math.max(n, 1))
end

-- Amplitude of a single frequency, by direct correlation.
local function tone_amp(t, from, to, nch, ch, freq)
  local re, im, n = 0, 0, 0
  for i = from, to do
    local a = 2 * math.pi * freq * (i - 1) / SR
    local v = t[(i - 1) * nch + ch]
    re = re + v * math.cos(a)
    im = im - v * math.sin(a)
    n = n + 1
  end
  return 2 * math.sqrt(re * re + im * im) / n
end

--------------------------------------------------------------- reconstruction

say("STFT reconstruction (reduction 0 dB is the transparency guard)")
for _, fftsel in ipairs({ 1, 2, 3 }) do
  local cfg = cfg_of { fftsel = fftsel }
  local k = make(cfg, 2)
  local lat = Config.latency(cfg)
  local N = lat + 4096
  math.randomseed(11)
  local sig = {}
  for i = 0, N - 1 do sig[i] = math.random() * 2 - 1 end
  local o = process(k, cfg, function(i) return sig[i] end, N, 2)

  local function err_at(shift)
    local e = 0
    for i = 0, 4095 - 8 do
      e = math.max(e, math.abs(o[(i + shift) * 2 + 1] - sig[i]))
    end
    return e
  end
  local e = err_at(lat)
  ok(e < 1e-9, string.format("fft %d reconstructs to unity",
     Config.fft_size(cfg)), string.format("max err %.3g", e))
  -- and the delay really is one FFT, not one FFT plus or minus a sample
  ok(err_at(lat - 1) > 1e-4 and err_at(lat + 1) > 1e-4,
     string.format("fft %d delay is exactly %d samples", Config.fft_size(cfg), lat))
end

do
  local cfg = cfg_of { fftsel = 2, nlm = 1 }
  local k = make(cfg, 2)
  local lat = Config.latency(cfg)
  ok(lat == 2 * Config.fft_size(cfg), "NLM reports two FFTs of latency")
  local N = lat + 4096
  math.randomseed(13)
  local sig = {}
  for i = 0, N - 1 do sig[i] = math.random() * 2 - 1 end
  local o = process(k, cfg, function(i) return sig[i] end, N, 2)
  local e = 0
  for i = 0, 4095 - 8 do
    e = math.max(e, math.abs(o[(i + lat) * 2 + 1] - sig[i]))
  end
  ok(e < 1e-9, "NLM delay path reconstructs to unity at the reported latency",
     string.format("max err %.3g", e))
end

do
  -- Channels must not bleed into one another.
  local cfg = cfg_of { fftsel = 2 }
  local k = make(cfg, 2)
  local lat = Config.latency(cfg)
  local N = lat + 2048
  local o = process(k, cfg, function(i, c)
    return c == 1 and math.sin(2 * math.pi * 1000 * i / SR) or 0
  end, N, 2)
  local leak = rms(o, lat + 1, lat + 2000, 2, 2)
  ok(leak < 1e-9, "silent channel stays silent", string.format("%.3g", leak))
end

------------------------------------------------------------------- analysis

say("")
say("Analysis: level binning and the profile spectrum")
do
  local cfg = cfg_of { fftsel = 2 }
  local k = make(cfg, 1)
  local fft = Config.fft_size(cfg)
  local bin = 100
  local freq = bin * SR / fft            -- exactly bin-centred
  local N = fft * 40
  local frames = analyse(k, cfg, function(i)
    return math.sin(2 * math.pi * freq * i / SR)
  end, N, 1)
  ok(frames > 20, "analysis produced frames", tostring(frames))

  -- A full-scale sine is -3.01 dBFS; the histogram has to say so.
  local counts, best, bestn = k:counts(), -1, -1
  for b = 0, k.nlev - 1 do
    if counts[b] > bestn then bestn, best = counts[b], b end
  end
  near(k.lev0 + best, -3.01, 1.5, "a full-scale sine bins at -3 dBFS")

  k:build_profile(0, k.nlev - 1, 0)
  local prof, pb, pv = k:profile_spectrum(), -1, -1
  for i = 1, k.nbins do
    if prof[i] > pv then pv, pb = prof[i], i end
  end
  ok(pb - 1 == bin, "the profile peaks in the sine's bin",
     string.format("%d vs %d", pb - 1, bin))

  -- Off-peak bins must be far below: proof the window and the transform are
  -- doing what they should rather than smearing energy everywhere.
  local far = prof[math.floor(k.nbins / 2)]
  ok(10 * math.log(far / pv, 10) < -80, "energy is confined to the peak",
     string.format("%.1f dB", 10 * math.log(far / pv, 10)))
end

--------------------------------------------------------------------- denoise

say("")
say("Denoise: reduction depth and signal preservation")
do
  local cfg = cfg_of { fftsel = 2, reduction = 18, strength = 30 }
  local k = make(cfg, 1)
  local fft = Config.fft_size(cfg)
  local N = fft * 60
  math.randomseed(29)
  local noise = {}
  for i = 0, N - 1 do noise[i] = (math.random() * 2 - 1) * 0.05 end

  analyse(k, cfg, function(i) return noise[i] end, N, 1)
  local n = k:build_profile(0, k.nlev - 1, 0)
  ok(n > 20, "profile built from the whole file", tostring(n))

  local lat = Config.latency(cfg)
  local o = process(k, cfg, function(i) return noise[i] or 0 end, N, 1)
  local before = db(rms0(noise, 0, N - lat - 1))
  local after  = db(rms(o, lat + 1, N - 1, 1, 1))
  near(after - before, -18, 3.5, "pure noise is reduced by about the set depth")

  -- A tone well above the floor has to survive it. Amplitudes are compared,
  -- not waveforms, so the STFT delay between the two does not matter.
  local freq = 1000
  local mix = {}
  for i = 0, N - 1 do
    mix[i] = (noise[i] or 0) + 0.5 * math.sin(2 * math.pi * freq * i / SR)
  end
  local om = process(k, cfg, function(i) return mix[i] end, N, 1)
  local flat = {}
  for i = 0, N - 1 do flat[i + 1] = mix[i] end
  local a_in  = tone_amp(flat, lat + 1, N - 1, 1, 1, freq)
  local a_out = tone_amp(om,   lat + 1, N - 1, 1, 1, freq)
  near(db(a_out) - db(a_in), 0, 1.0, "a tone 20 dB over the floor is preserved")
end

do
  -- Residual listen must be the complement: what is removed, not what is kept.
  local cfg = cfg_of { fftsel = 2, reduction = 18 }
  local k = make(cfg, 1)
  local fft = Config.fft_size(cfg)
  local N = fft * 40
  math.randomseed(31)
  local noise = {}
  for i = 0, N - 1 do noise[i] = (math.random() * 2 - 1) * 0.05 end
  analyse(k, cfg, function(i) return noise[i] end, N, 1)
  k:build_profile(0, k.nlev - 1, 0)
  local lat = Config.latency(cfg)
  local kept = process(k, cfg, function(i) return noise[i] or 0 end, N, 1)
  cfg.residual = true
  local gone = process(k, cfg, function(i) return noise[i] or 0 end, N, 1)
  ok(db(rms(gone, lat + 1, N - 1, 1, 1)) > db(rms(kept, lat + 1, N - 1, 1, 1)),
     "on pure noise the residual is louder than what is kept")
end

------------------------------------------------------------------------ gate

say("")
say("Output gate")
do
  local base = { fftsel = 2, reduction = 0, gate_on = true, gmode = 0,
                 gattack = 1, grelease = 5, ghold = 0, gauto = false }
  local fft = 2048
  local N = fft + 20000
  local sig = function(i) return 0.5 * math.sin(2 * math.pi * 440 * i / SR) end

  local cfg = cfg_of(base)
  cfg.gthresh = -40                       -- well below the -6 dB peak
  local k = make(cfg, 1)
  local o = process(k, cfg, sig, N, 1)
  local open_rms = rms(o, fft + 5000, N - 1, 1, 1)
  near(db(open_rms), db(0.5 / math.sqrt(2)), 0.5, "gate open passes the signal")

  cfg = cfg_of(base)
  cfg.gthresh = -3                        -- above the peak: never opens
  k = make(cfg, 1)
  o = process(k, cfg, sig, N, 1)
  ok(db(rms(o, fft + 5000, N - 1, 1, 1)) < -60, "gate closed mutes the signal",
     string.format("%.1f dB", db(rms(o, fft + 5000, N - 1, 1, 1))))

  cfg = cfg_of(base)
  cfg.gmode, cfg.gratio, cfg.gthresh = 1, 2, -6   -- expander, 1:2
  k = make(cfg, 1)
  o = process(k, cfg, function(i) return 0.05 * math.sin(2 * math.pi * 440 * i / SR) end, N, 1)
  -- 0.05 peak is -26 dB, 20 dB under the -6 dB threshold; a 1:2 expander
  -- turns that into 40 dB down, so another 20 dB of attenuation.
  local got = db(rms(o, fft + 5000, N - 1, 1, 1)) - db(0.05 / math.sqrt(2))
  near(got, -20, 2.5, "expander applies the ratio")
end

------------------------------------------------------------------------ report

say("")
say(string.format("%d passed, %d failed", pass, fail))
reaper.ShowConsoleMsg("\n=== Spectral DeNoise kernel selftest ===\n"
                      .. table.concat(out, "\n") .. "\n")

-- The tally has to reach the exit code, or a CI job or an `&&` chain reads a
-- suite that printed FAIL as green. Run from the Actions list this is a no-op:
-- REAPER's Lua has no os.exit, so the call is simply absent and the script has
-- already printed everything by now.
if os.exit then os.exit(fail == 0 and 0 or 1) end
