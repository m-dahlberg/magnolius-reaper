-- Spectral DeNoise -- does it actually remove the hiss? Run from the Actions
-- list, or through reascript_test.py. Needs no selection.
--
-- Every other suite in this repo asks whether a stage is well behaved: the
-- kernel reconstructs to unity, the render lines up sample for sample, the
-- histogram bins what it is given. All of them pass on a file the script
-- cannot denoise at all, because none of them is a question about noise. This
-- one states the job as a contrast and measures it on real material.
--
-- "DeNoise test 02.wav" is a voice take with an audible preamp hiss whose
-- pauses have been stripped to dithered digital silence. The room tone sits at
-- about -59 dB and the stripped silence at about -84, so the file is a direct
-- test of whether band placement can tell the two apart. Before that was
-- fixed, this suite measured 0.1 dB of hiss removed -- a complete no-op -- with
-- every other test in the repo green.
--
-- The hiss-removed / voice-lost pair is the rest of it: a broadband attenuator
-- also removes hiss, and only the ratio says which one you have.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir   = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function report()
  reaper.ShowConsoleMsg("\n=== Spectral DeNoise effectiveness ===\n"
                        .. table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fails == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then say("  ok    " .. name)
  else fails = fails + 1
       say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
-- Anything that stops the run counts as a failure: a green exit has to mean
-- the measurement happened, not that the script declined to look.
local function bail(s) fails = fails + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then bail("Requires ReaImGui.") return end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Kernel  = require "dn.kernel"
local Config  = require "dn.config"
local Analyze = require "dn.analyze"
local Profile = require "dn.profile"
local Render  = require "dn.render"
local Fix     = require "fixture"

local MEDIA = script_dir .. "DeNoise test 02.wav"

local runok, err, clean = Fix.with_track(function(tr)
  local _, take = Fix.add_media(tr, MEDIA)

  local ctx = ImGui.CreateContext("DeNoise effectiveness")
  local cfg = Config.new()
  cfg.new_take, cfg.select_take = false, false

  local geo = Analyze.geometry(take)
  say(string.format("file: %.2f s, %d ch at %d Hz%s", geo.acc_len, geo.nchan,
                    geo.rate, geo.rate_known and "" or "  (GUESSED)"))
  ok(geo.rate_known, "the source sample rate is known, not guessed")

  local k, kerr = Kernel.new(ImGui, ctx, script_dir, geo.nchan,
                             Config.fft_size(cfg), cfg.nlm, geo.rate)
  if not k then error("kernel: " .. tostring(kerr), 0) end

  -- ---------------------------------------------------------------- analysis
  local t0 = reaper.time_precise()
  local ares, aerr = Analyze.drive(function()
    return Analyze.run(take, cfg, k)
  end)
  if not ares then error("analysis failed: " .. tostring(aerr), 0) end
  say(string.format("analysis: %d frames in %.1f s", ares.frames,
                    reaper.time_precise() - t0))

  local hist = Profile.histogram(k:counts(), k.nlev, k.lev0)
  local th = Profile.band(hist, cfg)
  say("")
  say("Band placement")
  say(string.format("  lobe %s dB   band %.0f .. %.0f dB   %.0f frames (%.2f%%)",
      th.lobe_db and string.format("%.0f", th.lobe_db) or "none",
      th.lo_db, th.hi_db, th.frames, th.fraction * 100))
  say(string.format("  p10 %.1f   p85 %.1f   separation %.1f dB%s",
      th.noise_floor, th.signal_ref, th.separation,
      th.fallback and "   (FALLBACK)" or ""))
  if th.skipped_db then
    say(string.format("  stepped over edited-in silence at %.0f dB",
                      th.skipped_db))
  end
  if th.warning then say("  warning: " .. th.warning) end

  -- The room tone of this file is at -59 dB and the stripped silence at -84.
  -- This is the assertion the whole suite exists for.
  ok(th.lobe_db and th.lobe_db > -70,
     "the noise lobe is the room tone, not the stripped silence",
     string.format("lobe at %s dB",
                   th.lobe_db and string.format("%.0f", th.lobe_db) or "none"))
  ok(th.skipped_db ~= nil and th.skipped_db < -75,
     "and the silence lobe is reported, not silently ignored",
     tostring(th.skipped_db))
  ok(th.lo_db > -75 and th.hi_db < -50, "the band brackets the room tone",
     string.format("%.0f .. %.0f dB", th.lo_db, th.hi_db))
  -- The panel's own orientation figures have to describe the same distribution.
  -- Before the fix they read a healthy 64 dB of separation over a profile made
  -- of dither, which is how this got as far as it did.
  ok(th.noise_floor > -75, "the reported noise floor is the room tone",
     string.format("%.1f dB", th.noise_floor))

  local pframes = k:build_profile(th.lo_bin, th.hi_bin, cfg.prof_offset_db)
  ok(pframes >= Profile.MIN_BAND_FRAMES, "enough frames behind the profile",
     tostring(pframes))

  -- The profile's own high band, straight out of the kernel. A profile learnt
  -- on dither reads 45 dB below one learnt on the hiss, so this is the same
  -- fact as the band assertion above, stated where the DSP will read it.
  local prof = k:profile_spectrum()
  local norm = (k.fft_size * 0.25) ^ 2
  local hs, hn = 0, 0
  for i = 2, k.nbins do
    local f = (i - 1) * geo.rate / k.fft_size
    if f >= Fix.HP_FC and f <= 16000 then hs = hs + prof[i] hn = hn + 1 end
  end
  local prof_hf = Fix.db(hs / math.max(hn, 1) / norm)
  say(string.format("  profile mean level, %.0f Hz .. 16 kHz: %.1f dB",
                    Fix.HP_FC, prof_hf))
  ok(prof_hf > -95, "the profile is at the level of the hiss, not the dither",
     string.format("%.1f dB", prof_hf))

  -- ------------------------------------------------------------------ render
  local path = script_dir .. "test-denoised-tmp.wav"
  os.remove(path)
  t0 = reaper.time_precise()
  local res, rerr = Analyze.drive(function()
    return Render.run(take, cfg, k, path)
  end)
  if not res then error("render failed: " .. tostring(rerr), 0) end
  say(string.format("render: %.1f s", reaper.time_precise() - t0))

  -- ----------------------------------------------------------------- measure
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then error("could not create audio accessor", 0) end
  local fh = assert(io.open(path, "rb"))
  local data_off = Fix.data_offset(fh) or 44

  local function group(wins, label)
    say("")
    say(label .. "        in(all) in(>3k)   out(all) out(>3k)    d(all)  d(>3k)")
    local all, hf, i0, i0h = Fix.group(aa, fh, data_off, geo, wins,
      function(w, a, b, c, d)
        say(string.format("  %6.2f-%6.2f s   %7.1f %7.1f   %8.1f %8.1f   %7.1f %7.1f",
                          w[1], w[2], a, b, c, d, c - a, d - b))
      end)
    say(string.format("  %-16s %7.1f %7.1f   %8.1f %8.1f   %7.1f %7.1f", "mean",
        i0, i0h, i0 + all, i0h + hf, all, hf))
    return all, hf
  end

  local _,         tone_hf  = group(Fix.TONE,  "room tone")
  local voice_all, voice_hf = group(Fix.VOICE, "voice")

  fh:close()
  reaper.DestroyAudioAccessor(aa)
  os.remove(path)

  local removed, lost = -tone_hf, -voice_hf
  say("")
  say(string.format("verdict: %.1f dB of hiss removed above %d Hz "
                    .. "for %.1f dB of voice", removed, Fix.HP_FC, lost))

  -- Assertions at the SHIPPED default, not at a swept best value. The default
  -- Reduction is 10 dB, which is a gain floor rather than a promise: the
  -- Berouti rule lets the noisiest bins through, so the measured depth always
  -- lands a little under the setting. test/sweep_in_reaper.lua maps that out.
  ok(removed >= 6.0, "removes at least 6 dB of hiss above 3 kHz",
     string.format("%.1f dB", removed))
  ok(lost <= 2.0, "without costing 2 dB of voice above 3 kHz",
     string.format("%.1f dB", lost))
  -- The line that separates a denoiser from a broadband attenuator.
  ok(removed > 2 * lost, "and takes more hiss than voice",
     string.format("%.1f dB removed vs %.1f dB lost", removed, lost))
  ok(-voice_all <= 1.5, "broadband voice level is preserved",
     string.format("%.1f dB", voice_all))
end)

if not runok then fails = fails + 1 say("  FAIL  " .. tostring(err)) end
if not clean then
  fails = fails + 1
  say("  FAIL  the fixture track was not cleaned up")
end

say("")
say(fails == 0 and "all checks passed" or (fails .. " failed"))
report()
