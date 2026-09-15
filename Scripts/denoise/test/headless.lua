-- Spectral DeNoise -- headless tests.
--
-- Covers the three pure-Lua stages and the FFT algorithm the kernel uses. No
-- REAPER, no audio files, no ReaImGui.
--
--   lua test/headless.lua
--
-- What this cannot cover is the EEL transcription itself; that is what
-- test/selftest_in_reaper.lua exists for.

package.path = "./?.lua;./test/?.lua;" .. package.path

local Profile = require "dn.profile"
local Gains   = require "dn.gains"
local Wav     = require "dn.wav"
local Config  = require "dn.config"
local FFT     = require "fft_ref"

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then pass = pass + 1
  else fail = fail + 1 print("FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  tol = tol or 1e-9
  ok(math.abs(a - b) <= tol, name, string.format("%.12g vs %.12g", a, b))
end
local function section(s) print("-- " .. s) end

--------------------------------------------------------------------------- fft

section("fft")
do
  local n = 64
  local T = FFT.tables(n)
  math.randomseed(7)
  local x = {}
  for i = 0, n - 1 do x[2 * i] = math.random() * 2 - 1 x[2 * i + 1] = 0 end
  local ref = FFT.dft(x, n)
  local buf = {}
  for i = 0, 2 * n - 1 do buf[i] = x[i] end
  FFT.fwd(buf, T)
  local err = 0
  for i = 0, 2 * n - 1 do err = math.max(err, math.abs(buf[i] - ref[i])) end
  ok(err < 1e-10, "radix-2 forward matches a naive DFT", string.format("err %.3g", err))

  -- fwd then inv reproduces N*x: the transform pair is unscaled, exactly as
  -- the kernel assumes when it folds 1/N into outscale.
  FFT.inv(buf, T)
  local rerr = 0
  for i = 0, n - 1 do
    rerr = math.max(rerr, math.abs(buf[2 * i] - n * x[2 * i]))
    rerr = math.max(rerr, math.abs(buf[2 * i + 1]))
  end
  ok(rerr < 1e-9, "inverse of forward is N*x", string.format("err %.3g", rerr))

  -- a sine at bin b puts all its energy in bins b and N-b
  local b = 7
  local s = {}
  for i = 0, n - 1 do
    s[2 * i] = math.sin(2 * math.pi * b * i / n)
    s[2 * i + 1] = 0
  end
  FFT.fwd(s, T)
  local peak, peakbin = -1, -1
  for k = 0, n / 2 do
    local p = s[2 * k] ^ 2 + s[2 * k + 1] ^ 2
    if p > peak then peak, peakbin = p, k end
  end
  ok(peakbin == b, "a bin-centred sine peaks in that bin", tostring(peakbin))
end

do
  -- The level the histogram bins frames by. A full-scale sine is -3.01 dBFS,
  -- and the Hann correction in ana_frame has to recover that from the
  -- windowed spectrum or every band in the panel sits at the wrong dB.
  local n = 256
  local T = FFT.tables(n)
  local w = FFT.hann(n)
  local buf = {}
  for i = 0, n - 1 do
    buf[2 * i] = math.sin(2 * math.pi * 11 * i / n) * w[i]
    buf[2 * i + 1] = 0
  end
  FFT.fwd(buf, T)
  local tot = 0
  for k = 0, n - 1 do tot = tot + buf[2 * k] ^ 2 + buf[2 * k + 1] ^ 2 end
  local level = 10 * math.log(tot / (n * n * 0.375), 10)
  near(level, -3.0103, 0.02, "full-scale sine reads -3.01 dBFS through the window")

  -- and the half-spectrum sum the kernel actually uses agrees with the full one
  local half = n / 2
  local halfsum = buf[0] ^ 2 + buf[1] ^ 2 + buf[2 * half] ^ 2 + buf[2 * half + 1] ^ 2
  for k = 1, half - 1 do
    halfsum = halfsum + 2 * (buf[2 * k] ^ 2 + buf[2 * k + 1] ^ 2)
  end
  near(halfsum, tot, tot * 1e-9, "mirrored half-spectrum sum equals the full sum")
end

----------------------------------------------------------------------- profile

section("profile")

-- Build a histogram: lobes is a list of { db, count, width }.
local function hist_of(lobes, nlev, lev0)
  local c = {}
  for b = 0, nlev - 1 do c[b] = 0 end
  for _, L in ipairs(lobes) do
    local width = L.width or 2
    local total = 0
    local wts = {}
    for b = 0, nlev - 1 do
      local d = (lev0 + b) - L.db
      wts[b] = math.exp(-0.5 * (d / width) ^ 2)
      total = total + wts[b]
    end
    -- integer counts, as the kernel produces them
    for b = 0, nlev - 1 do c[b] = c[b] + math.floor(L.count * wts[b] / total + 0.5) end
  end
  return Profile.histogram(c, nlev, lev0)
end

local base = Config.new()
local function cfgwith(t)
  local c = Config.new()
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

do
  -- The case the whole design is for: room tone with speech over it. The band
  -- must land on the room-tone lobe even though the signal lobe is present.
  local h = hist_of({ { db = -62, count = 6000, width = 2 },
                      { db = -24, count = 4000, width = 6 } }, 127, -120)
  local th = Profile.band(h, base)
  ok(th.lobe_db ~= nil, "bimodal: a lobe is found")
  near(th.lobe_db, -62, 1.5, "bimodal: the lobe is the room tone, not the voice")
  ok(th.lo_db <= -62 and th.hi_db >= -62, "bimodal: the band straddles the lobe",
     string.format("%.0f..%.0f", th.lo_db, th.hi_db))
  ok(th.hi_db < -40, "bimodal: the band stays clear of the voice lobe")
  ok(th.frames > 1000, "bimodal: the band selects a usable number of frames")
  ok(th.warning == nil, "bimodal: no warning", tostring(th.warning))
  ok(not th.fallback, "bimodal: no fallback")
end

do
  -- Edited-in digital silence is not room tone. If it were averaged into the
  -- profile it would halve it and the reduction would fall short.
  local h = hist_of({ { db = -119, count = 5000, width = 0.6 },
                      { db = -62, count = 6000, width = 2 },
                      { db = -24, count = 4000, width = 6 } }, 127, -120)
  local th = Profile.band(h, base)
  near(th.lobe_db, -62, 1.5, "silence: the lobe is still the room tone")
  ok(th.lo_db > -100, "silence: the band starts above the silence floor",
     string.format("%.0f", th.lo_db))
end

do
  -- Continuous material with no pauses: there is nothing to learn from and the
  -- script has to say so rather than quietly build a profile out of music.
  local h = hist_of({ { db = -20, count = 10000, width = 3 } }, 127, -120)
  local th = Profile.band(h, base)
  ok(th.warning ~= nil, "unimodal: warns that there is nothing to learn from")
  ok(th.separation < 12, "unimodal: no separation between noise and material",
     string.format("%.1f", th.separation))
end

do
  -- Mostly-speech: a few seconds of room tone against minutes of voice. The
  -- lobe is 3% as tall as the speech lobe and must still be found -- height
  -- relative to the tallest peak is the wrong test, prominence is the right
  -- one.
  local h = hist_of({ { db = -70, count = 200, width = 1.5 },
                      { db = -18, count = 20000, width = 4 } }, 127, -120)
  local th = Profile.band(h, base)
  near(th.lobe_db, -70, 1.5, "sparse pauses: the small room-tone lobe is found")
  ok(th.frames >= Profile.MIN_BAND_FRAMES,
     "sparse pauses: enough frames for a profile", string.format("%.0f", th.frames))
  ok(th.warning == nil,
     "sparse pauses: a clean lobe far below the material draws no warning",
     tostring(th.warning))
end

do
  -- Manual band is used verbatim, and auto is not silently substituted.
  local h = hist_of({ { db = -62, count = 6000, width = 2 },
                      { db = -24, count = 4000, width = 6 } }, 127, -120)
  local th = Profile.band(h, cfgwith { band_auto = false,
                                       band_lo_db = -70, band_hi_db = -66 })
  near(th.lo_db, -70, 0.001, "manual: low edge honoured")
  near(th.hi_db, -66, 0.001, "manual: high edge honoured")
end

do
  -- A band the user put somewhere empty is widened until the mean has enough
  -- frames behind it, rather than producing a profile from three of them.
  local h = hist_of({ { db = -62, count = 6000, width = 2 } }, 127, -120)
  local th = Profile.band(h, cfgwith { band_auto = false,
                                       band_lo_db = -40, band_hi_db = -39 })
  ok(th.frames >= Profile.MIN_BAND_FRAMES or th.widened_db >= 29,
     "sparse band is widened", string.format("%.0f frames, widened %d dB",
     th.frames, th.widened_db))
end

do
  -- Silence islands. A 16-bit master's stripped pauses land on the histogram
  -- as a lobe of dithered digital silence, well above the -100 dB silence
  -- floor and separated from everything real by a dead gap. It is not room
  -- tone, and scanning up from the bottom finds it first.
  --
  -- Shape measured off "DeNoise test 02.wav": dither at -84 with 29% of the
  -- frames, room tone at -59, voice at -22.
  local h = hist_of({ { db = -84, count = 5800, width = 0.9 },
                      { db = -59, count = 800, width = 2 },
                      { db = -22, count = 13400, width = 6 } }, 127, -120)
  local th = Profile.band(h, base)
  near(th.lobe_db, -59, 1.5, "island: the lobe is the room tone, not the dither")
  ok(th.skipped_db ~= nil and th.skipped_db < -75,
     "island: the dither lobe is reported as skipped",
     tostring(th.skipped_db))
  ok(th.lo_db > -70, "island: the band stays out of the dither",
     string.format("%.0f..%.0f", th.lo_db, th.hi_db))
  -- The panel's own orientation numbers must describe the same distribution,
  -- or it shows a healthy 60 dB of separation over a profile made of dither.
  ok(th.noise_floor > -75, "island: the reported noise floor is the room tone",
     string.format("%.1f", th.noise_floor))

  -- The opt-out has to actually opt out, or the old behaviour is unreachable.
  local raw = Profile.band(h, cfgwith { skip_silence = false })
  near(raw.lobe_db, -84, 1.5, "island: skip_silence=false takes the dither")
  ok(raw.skipped_db == nil, "island: and reports nothing skipped")
end

do
  -- The rule must not run away with itself: a room-tone lobe can sit behind a
  -- dead gap too, when the take's pauses are clean and its speech is loud.
  -- Skipping that one would put the band on the voice. Nothing above the gap
  -- here is a candidate, so nothing is skipped.
  local h = hist_of({ { db = -70, count = 200, width = 1.5 },
                      { db = -18, count = 20000, width = 4 } }, 127, -120)
  local th = Profile.band(h, base)
  near(th.lobe_db, -70, 1.5, "gap: a lone room-tone lobe is kept")
  ok(th.skipped_db == nil, "gap: and nothing is reported skipped",
     tostring(th.skipped_db))
end

do
  -- Two islands, both above the -100 dB silence floor so the flat threshold
  -- cannot help: a stripped-silence lobe, dither above it, then the room tone.
  -- Both are stepped over, and the last one wins the report.
  local h = hist_of({ { db = -96, count = 900, width = 0.6 },
                      { db = -84, count = 4000, width = 0.9 },
                      { db = -58, count = 700, width = 2 },
                      { db = -22, count = 12000, width = 6 } }, 127, -120)
  local th = Profile.band(h, base)
  near(th.lobe_db, -58, 1.5, "two islands: the room tone is still found")
  ok(th.skipped_db ~= nil and th.skipped_db < -75,
     "two islands: the higher one is reported", tostring(th.skipped_db))
end

do
  local h = hist_of({ { db = -60, count = 1000, width = 1 } }, 127, -120)
  local p50 = Profile.percentile(h, 50, 0)
  near(p50, -60, 1.0, "percentile finds the centre of a single lobe")
  ok(Profile.percentile(h, 10, 0) < p50, "percentiles are ordered")
end

------------------------------------------------------------------------- gains

section("gains")
do
  near(Gains.alpha(-10, 4), 4, 1e-12, "alpha saturates at amax below -5 dB SNR")
  near(Gains.alpha(30, 4), 1, 1e-12, "alpha bottoms out at 1 above 20 dB SNR")
  near(Gains.alpha(7.5, 4), 2.5, 1e-9, "alpha is linear across the ramp")

  -- Pure noise: the signal equals the estimate, so with any oversubtraction
  -- at all the raw gain is zero and only the floor is left.
  near(Gains.wiener(1, 1, 4), 0, 1e-12, "gain is 0 where signal equals noise")
  ok(Gains.wiener(1000, 1, 4) > 0.99, "gain is ~1 far above the noise")
  near(Gains.wiener(1, 0, 4), 1, 1e-12, "gain is 1 where there is no noise")

  near(Gains.floor_gain(0, 10 ^ (-20 / 20), 1 - 0.1, 1), 0.1, 1e-12,
       "20 dB reduction floors the gain at 0.1")
  near(Gains.floor_gain(0, 10 ^ (-0 / 20), 0, 1), 1, 1e-12,
       "0 dB reduction is transparent")
end

do
  local n = 65
  local flat, coloured = {}, {}
  for i = 1, n do
    flat[i] = 1
    coloured[i] = (i < n / 2) and 100 or 0.01   -- loud lows, quiet highs
  end
  local w0 = Gains.whitening_weights(flat, n, 0)
  local allone = true
  for i = 1, n do if math.abs(w0[i] - 1) > 1e-12 then allone = false end end
  ok(allone, "whitening off leaves every weight at 1")

  local w = Gains.whitening_weights(coloured, n, 100)
  ok(w[n] > 1, "whitening lifts the floor in the profile's valleys", tostring(w[n]))
  ok(w[1] < 1, "and lowers it on the profile's peaks", tostring(w[1]))
  local wf = Gains.whitening_weights(flat, n, 100)
  local flatone = true
  for i = 1, n do if math.abs(wf[i] - 1) > 1e-9 then flatone = false end end
  ok(flatone, "an already-flat profile needs no reshaping")
end

do
  local n = 33
  local prof, spec = {}, {}
  for i = 1, n do prof[i] = 1 spec[i] = 1 end
  spec[20] = 10000                                   -- one loud bin
  local c = cfgwith { reduction = 20, strength = 30, whitening = 0 }
  local g = Gains.curve(spec, prof, n, c)
  near(g[1], 0.1, 1e-9, "noise-only bins land on the reduction floor")
  ok(g[20] > 0.9, "a bin far above the noise passes", tostring(g[20]))

  c.residual = true
  local r = Gains.curve(spec, prof, n, c)
  near(r[1], 1 - 0.1, 1e-9, "residual listen inverts the gain")
end

do
  local n = 9
  local b = {}
  for i = 1, n do b[i] = 5 end
  Gains.smooth_spectrum(b, n)
  local flat = true
  for i = 1, n do if math.abs(b[i] - 5) > 1e-12 then flat = false end end
  ok(flat, "smoothing a constant spectrum changes nothing")

  local imp = {}
  for i = 1, n do imp[i] = 0 end
  imp[5] = 3
  local before = imp[5]
  Gains.smooth_spectrum(imp, n)
  ok(imp[5] < before and imp[4] > 0 and imp[6] > 0,
     "smoothing spreads an impulse into its neighbours")
  local sum = 0
  for i = 1, n do sum = sum + imp[i] end
  near(sum, 3, 1e-9, "and conserves total power")
end

--------------------------------------------------------------------------- wav

section("wav")
do
  local path = os.tmpname() .. ".wav"
  local w = assert(Wav.create(path, 2, 44100))
  local t = {}
  local N = 5000
  for i = 1, N * 2 do t[i] = ((i % 7) - 3) / 4 end
  w:write(t, 1, N * 2)
  w:close()

  local fh = assert(io.open(path, "rb"))
  local data = fh:read("a")
  fh:close()
  os.remove(path)

  ok(data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE", "wav: RIFF/WAVE header")
  local riffsz = string.unpack("<I4", data, 5)
  near(riffsz, #data - 8, 0, "wav: RIFF size patched on close")
  local fmt, nch, rate = string.unpack("<I2I2I4", data, 21)
  ok(fmt == 3, "wav: IEEE float format tag", tostring(fmt))
  ok(nch == 2, "wav: channel count")
  ok(rate == 44100, "wav: sample rate")
  local bits = string.unpack("<I2", data, 35)
  ok(bits == 32, "wav: 32 bit")
  local datasz = string.unpack("<I4", data, 41)
  ok(datasz == N * 2 * 4, "wav: data size", tostring(datasz))

  local worst = 0
  for i = 1, N * 2 do
    local v = string.unpack("<f", data, 45 + (i - 1) * 4)
    worst = math.max(worst, math.abs(v - t[i]))
  end
  ok(worst < 1e-7, "wav: samples round-trip", string.format("%.3g", worst))

  ok(Wav.will_overflow(600e6, 2), "wav: oversized renders are refused up front")
  ok(not Wav.will_overflow(48000 * 300, 2), "wav: a five minute stereo take fits")
end

------------------------------------------------------------------------ config

section("config")
do
  local c = Config.new()
  c.fftsel = 2 c.nlm = 0
  ok(Config.fft_size(c) == 2048, "fft size lookup")
  ok(Config.latency(c) == 2048, "latency is one FFT without NLM")
  c.nlm = 1
  ok(Config.latency(c) == 4096, "NLM's lookahead costs a second FFT")
end

do
  -- Reset has to work in place: the panel hands one cfg table to the kernel,
  -- the profile and the render, so replacing it would strand all three.
  local c = Config.new()
  c.reduction, c.nlm, c.band_auto = 33, 2, false
  c._band_lo = -70                      -- a key the render stamps on
  local same = Config.reset(c)
  ok(same == c, "reset keeps the same table")
  ok(c.reduction == Config.defaults.reduction, "reset restores a number")
  ok(c.band_auto == Config.defaults.band_auto, "reset restores a boolean")
  ok(c._band_lo == nil, "reset drops keys that are not defaults")
  local n = 0
  for _ in pairs(c) do n = n + 1 end
  local d = 0
  for _ in pairs(Config.defaults) do d = d + 1 end
  ok(n == d, "reset leaves exactly the default keys",
     string.format("%d vs %d", n, d))
end

--------------------------------------------------------------------------- ui

-- The panel is a defer loop and cannot be run here, but every control in it
-- names a config key as a string, and a key that has been renamed out from
-- under a slider is a Lua error the moment the user drags it. Reading the
-- source catches that for the price of a gmatch.
section("ui")
do
  local src
  for dir in package.path:gmatch("([^;]*)%?%.lua") do
    local fh = io.open(dir .. "dn/ui.lua", "rb")
    if fh then src = fh:read("a") fh:close() break end
  end
  ok(src ~= nil, "dn/ui.lua was found next to the tests")
  if src then
    local seen, missing = {}, {}
    for key in src:gmatch('slider%s*%(%s*"[^"]*"%s*,%s*"([%w_]+)"') do
      seen[key] = true
      if Config.defaults[key] == nil then missing[#missing + 1] = key end
    end
    for key in src:gmatch('checkbox%s*%(%s*"[^"]*"%s*,%s*"([%w_]+)"') do
      seen[key] = true
      if Config.defaults[key] == nil then missing[#missing + 1] = key end
    end
    ok(#missing == 0, "every control on the panel names a real config key",
       table.concat(missing, ", "))
    ok(next(seen) ~= nil, "controls were actually found in the source")
    -- Not a failure -- combos and buttons set keys directly -- but worth
    -- printing, because a setting with no control is a setting nobody can see.
    local orphans = {}
    for key in pairs(Config.defaults) do
      -- Combos and buttons write cfg.<key> directly rather than through a
      -- wrapper, so count those as controls too.
      if not seen[key] and not src:find("cfg%." .. key .. "%f[^%w_]") then
        orphans[#orphans + 1] = key
      end
    end
    table.sort(orphans)
    if #orphans > 0 then
      print("      note: no control mentions " .. table.concat(orphans, ", "))
    end
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
-- Guarded like the in-REAPER suites: this file is pure Lua, but with no system
-- `lua` on the machine it usually runs inside REAPER, whose embedded Lua has no
-- os.exit. Unguarded, a failing run would die on the reporting line instead of
-- reporting.
if os.exit then os.exit(fail == 0 and 0 or 1) end
