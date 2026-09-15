-- Spectral DeNoise -- the tuning instrument. Run from the Actions list.
-- Asserts nothing; it prints two tables and takes about a minute and a half,
-- during which REAPER's UI is blocked.
--
--   1. How close the learned noise profile is to the truth. The truth here is
--      measurable: analyse ONLY the room-tone windows in a second kernel and
--      the mean spectrum that comes out is the hiss, with no band placement
--      involved at all. Every automatic band is then printed as its error
--      against that, per octave. A band that reaches into the programme
--      material shows up immediately as a positive error in the low mids,
--      because that is where speech lives and hiss does not.
--
--   2. What the Reduction and Strength settings actually do. Reduction is a
--      gain floor, not a promise: the Berouti rule passes any bin whose
--      instantaneous noise power exceeds alpha times the mean, so the measured
--      depth lands under the setting, and Strength -- which is alpha -- is what
--      closes the gap. The table is the map from settings to dB removed.
--
-- The windows and the fixture file come from test/fixture.lua. Re-pick them
-- there before pointing this at other material.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir   = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out = {}
local function say(s) out[#out + 1] = s end
local function report()
  reaper.ShowConsoleMsg("\n=== Spectral DeNoise tuning sweep ===\n"
                        .. table.concat(out, "\n") .. "\n")
end

if not reaper.ImGui_GetBuiltinPath then
  say("Requires ReaImGui.") report()
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Kernel  = require "dn.kernel"
local Config  = require "dn.config"
local Analyze = require "dn.analyze"
local Profile = require "dn.profile"
local Render  = require "dn.render"
local Fix     = require "fixture"

local MEDIA  = script_dir .. "DeNoise test 02.wav"
local OCTAVE = { 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 24000 }

local function cfgwith(t)
  local c = Config.new()
  c.new_take, c.select_take = false, false
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

local runok, err, clean = Fix.with_track(function(tr)
  local _, take = Fix.add_media(tr, MEDIA)
  local ctx = ImGui.CreateContext("DeNoise sweep")
  local base = cfgwith {}
  local geo = Analyze.geometry(take)
  say(string.format("file: %.2f s, %d ch at %d Hz", geo.acc_len, geo.nchan,
                    geo.rate))

  local k = assert(Kernel.new(ImGui, ctx, script_dir, geo.nchan,
                              Config.fft_size(base), base.nlm, geo.rate))
  assert(Analyze.drive(function() return Analyze.run(take, base, k) end))
  local hist = Profile.histogram(k:counts(), k.nlev, k.lev0)

  local norm = (k.fft_size * 0.25) ^ 2
  local function octaves(sp)
    local r = {}
    for oi = 1, #OCTAVE - 1 do
      local s, c = 0, 0
      for i = 2, k.nbins do
        local f = (i - 1) * geo.rate / k.fft_size
        if f >= OCTAVE[oi] and f < OCTAVE[oi + 1] then s = s + sp[i] c = c + 1 end
      end
      r[oi] = c > 0 and Fix.db(s / c / norm) or -999
    end
    return r
  end
  local function row(label, vals, tail)
    local s = string.format("%-26s", label)
    for i = 1, #vals do s = s .. string.format("%8.1f", vals[i]) end
    say(s .. (tail or ""))
  end

  -- ------------------------------------------ 1. how good is the profile?
  -- A second kernel fed only the room-tone windows. No band, no histogram --
  -- just the hiss.
  local k2 = assert(Kernel.new(ImGui, ctx, script_dir, geo.nchan,
                               Config.fft_size(base), 0, geo.rate))
  k2:set_params(base)
  k2:reset_analysis()
  ImGui.Function_SetValue(k2.func, "_ANAHOP", k2.fft_size / 4)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then error("could not create audio accessor", 0) end
  for _, w in ipairs(Fix.TONE) do
    k2:reset()                          -- each window starts a fresh STFT
    local n, done = math.floor((w[2] - w[1]) * geo.rate), 0
    while done < n do
      local blk = math.min(k2.block, n - done)
      k2.inbuf.clear(0)
      if reaper.GetAudioAccessorSamples(aa, geo.rate, geo.nchan,
                                        w[1] + done / geo.rate, blk,
                                        k2.inbuf) == nil then
        error("the accessor read returned nil", 0)
      end
      k2:analyze(blk)
      done = done + blk
    end
  end
  local truth = octaves((function()
    k2:build_profile(0, k2.nlev - 1, 0)
    return k2:profile_spectrum()
  end)())

  say("")
  say("1. Noise profile against the true room tone (dB per octave)")
  local head = string.format("%-26s", "")
  for oi = 1, #OCTAVE - 1 do head = head .. string.format("%8s", OCTAVE[oi]) end
  say(head)
  row("true room tone", truth)
  say("")
  say("   ...and the error of each band setting (0 = perfect, + = too much):")
  local function profrow(label, mut)
    local c = cfgwith(mut)
    local th = Profile.band(hist, c)
    local nf = k:build_profile(th.lo_bin, th.hi_bin, c.prof_offset_db)
    local e, p = {}, octaves(k:profile_spectrum())
    for i = 1, #p do e[i] = p[i] - truth[i] end
    row("   " .. label, e,
        string.format("   [%.0f..%.0f dB, %.0f fr]", th.lo_db, th.hi_db, nf))
  end
  profrow("auto 8/4 (default)", {})
  profrow("auto 6/2", { band_below_db = 6, band_above_db = 2 })
  profrow("auto 4/1", { band_below_db = 4, band_above_db = 1 })
  profrow("auto 12/6", { band_below_db = 12, band_above_db = 6 })
  profrow("auto 8/8", { band_below_db = 8, band_above_db = 8 })
  profrow("skip_silence OFF", { skip_silence = false })

  -- --------------------------------------------- 2. what do the knobs do?
  say("")
  say("2. Settings against measured effect on the file")
  say(string.format("%-34s %9s %9s %9s", "", "hiss dB", "voice dB", "ratio"))
  local function rendered(label, mut)
    local c = cfgwith(mut)
    local th = Profile.band(hist, c)
    k:build_profile(th.lo_bin, th.hi_bin, c.prof_offset_db)
    local path = script_dir .. "test-sweep-tmp.wav"
    os.remove(path)
    local res, rerr = Analyze.drive(function()
      return Render.run(take, c, k, path)
    end)
    if not res then error("render failed: " .. tostring(rerr), 0) end
    local fh = assert(io.open(path, "rb"))
    local off = Fix.data_offset(fh) or 44
    local _, tone_hf  = Fix.group(aa, fh, off, geo, Fix.TONE)
    local _, voice_hf = Fix.group(aa, fh, off, geo, Fix.VOICE)
    fh:close()
    os.remove(path)
    local removed, lost = -tone_hf, -voice_hf
    say(string.format("%-34s %9.1f %9.1f %9s", label, removed, lost,
        lost > 0.05 and string.format("%.1f", removed / lost) or "--"))
  end
  rendered("Reduction 10, Strength 30 (default)", {})
  rendered("Reduction 18, Strength 30", { reduction = 18 })
  rendered("Reduction 18, Strength 60", { reduction = 18, strength = 60 })
  rendered("Reduction 24, Strength 60", { reduction = 24, strength = 60 })
  rendered("Reduction 24, Strength 100", { reduction = 24, strength = 100 })
  rendered("Reduction 30, Strength 100", { reduction = 30, strength = 100 })

  reaper.DestroyAudioAccessor(aa)
end)

if not runok then say("ERROR: " .. tostring(err)) end
if not clean then say("ERROR: the fixture track was not cleaned up") end
report()
if os.exit then os.exit((runok and clean) and 0 or 1) end
