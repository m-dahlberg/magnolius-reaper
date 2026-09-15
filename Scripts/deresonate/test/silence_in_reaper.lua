-- Does the level statistic survive edited-in silence? Run from the Actions
-- list, or through reascript_test.py. Needs no selection.
--
-- Every percentile in this script is taken over every frame of the file, and
-- that is only the right statistic if every frame is a frame of the recording.
-- Strip-silence, a hard noise gate, or the noise-shaped dither a 16-bit master
-- carries in its pauses all put a population at the very bottom of every bin's
-- histogram that the microphone never produced. If it is larger than the
-- percentile being asked for, the percentile lands inside it -- at every
-- frequency at once.
--
-- Measured before `spectrum.floor_bin` existed, on a voice take whose pauses
-- had been stripped: 27 % of its frames were dithered silence, the p20 curve
-- came back as a PERFECTLY FLAT LINE at the bottom of the level axis (0.0 dB
-- of spread across the whole spectrum), and the detector found nothing and
-- said nothing -- because every detector here measures a curve against a
-- smoothed copy of itself, and a constant minus its own envelope is zero.
--
-- The fixture needs no second file and no external material. An item longer
-- than its source reads as digital silence past the end, so the same take
-- analysed at two different item lengths is the same recording with and
-- without a block of silence attached. The statistic must not be able to tell
-- them apart -- that is the whole assertion.
--
-- B_LOOPSRC has to be cleared for that to be true. It defaults to ON, so an
-- over-long item REPEATS its source instead of running out into silence, and
-- the fixture quietly becomes "the same audio, twice" -- which of course
-- changes no statistic at all and makes every assertion below pass for the
-- wrong reason. The opt-out check at the end is what caught it.

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;"
            .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "")
            .. package.path

local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function report()
  reaper.ShowConsoleMsg("\n=== DeResonate: edited-in silence ===\n"
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

local ImGui       = require "imgui" "0.9"
local Config      = require "dr.config"
local Kernel      = require "dr.kernel"
local PitchKernel = require "dr.pitch_kernel"
local Analyze     = require "dr.analyze"
local Spectrum    = require "dr.spectrum"
local Detect      = require "dr.detect"
local Fixture     = require "fixture"

local WAV        = root .. "Room resonance example.wav"
local SILENCE_FR = 0.40       -- of the analysed span, appended as digital silence

local ctx = ImGui.CreateContext("DeResonate silence")
local cfg = Config.new()

-- Analyse `path` over an item of `len` seconds and return the p20 curve, the
-- per-band ring floors and the candidates.
local function analyse(track, path, len, label)
  local item, take = Fixture.add_item(track, path, 0, len, 1.0)
  if not item then error(tostring(take), 0) end
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)   -- silence, not a repeat
  local geo = Analyze.geometry(take)
  local pk, perr = PitchKernel.new(ImGui, ctx, root, geo.nchan, cfg, cfg.pitch_rate)
  if not pk then error("pitch kernel: " .. tostring(perr), 0) end
  local k, kerr = Kernel.new(ImGui, ctx, root, geo.nchan, cfg)
  if not k then error("kernel: " .. tostring(kerr), 0) end

  local F, err = Analyze.drive(Analyze.run(take, cfg, pk, k, geo))
  if not F then error("analysis: " .. tostring(err), 0) end

  local cube = k:modal_cube()
  local hz   = Spectrum.hz_axis(k.half, Config.bin_hz(cfg))
  local floors = Spectrum.floor_bins(cube, true)
  local p20  = Spectrum.curve(cube, cfg.percentile / 100.0, k.lev0, floors)
  local occ  = {}
  for i = 1, k.half do occ[i] = 0.0 end
  local cands = Detect.run(p20, hz, occ, nil, cfg, Config.bin_hz(cfg))
  local _, rfloors = k:ring_hist(cfg)

  local lo, hi = math.huge, -math.huge
  for i = 1, #p20 do
    if p20[i] then lo = math.min(lo, p20[i]) hi = math.max(hi, p20[i]) end
  end
  say(string.format("  %-28s %6.1f s  %4d modal frames  p20 spread %5.1f dB  "
                    .. "%d candidates  (skipped up to %.0f%%)",
                    label, len, F.modal_frames, hi - lo, #cands,
                    floors.skipped_frac * 100))
  reaper.DeleteTrackMediaItem(track, item)
  return { p20 = p20, hz = hz, cands = cands, rfloors = rfloors,
           spread = hi - lo, floors = floors, nband = k.nband }
end

local function body(track)
  local probe = reaper.PCM_Source_CreateFromFile(WAV)
  if not probe then error("could not open " .. WAV, 0) end
  local srclen = reaper.GetMediaSourceLength(probe)
  reaper.PCM_Source_Destroy(probe)

  say(string.format("source: %s, %.1f s", WAV:match("([^/\\]+)$"), srclen))
  local dry = analyse(track, WAV, srclen, "audio only")
  local pad = analyse(track, WAV, srclen / (1 - SILENCE_FR),
                      string.format("+ %.0f%% digital silence", SILENCE_FR * 100))

  -- 1. The curve must still be a curve.
  ok(pad.spread > 20.0,
     "the percentile curve survives the silence",
     string.format("%.1f dB of spread", pad.spread))

  -- 2. And it must be the SAME curve. This is the assertion that matters: the
  --    statistic may not depend on how much silence was edited into the file.
  local worst, worst_hz, n = 0, 0, 0
  for i = 1, #dry.p20 do
    local f = dry.hz[i]
    if f >= cfg.search_lo_hz and f <= cfg.search_hi_hz
       and dry.p20[i] and pad.p20[i] then
      local d = math.abs(dry.p20[i] - pad.p20[i])
      n = n + 1
      if d > worst then worst, worst_hz = d, f end
    end
  end
  ok(n > 100, "the search range holds enough bins to compare", tostring(n))
  ok(worst <= 3.0,
     "the curve is unchanged by the silence, across the search range",
     string.format("worst %.1f dB at %.0f Hz", worst, worst_hz))

  -- 3. The ring floors are p10 per band -- an even lower percentile, so an
  --    even smaller share of silence pins them to the bottom of the axis.
  local pinned_dry, pinned_pad = 0, 0
  for b = 1, dry.nband do
    if (dry.rfloors[b] or -140) <= -139 then pinned_dry = pinned_dry + 1 end
    if (pad.rfloors[b] or -140) <= -139 then pinned_pad = pinned_pad + 1 end
  end
  ok(pinned_pad <= pinned_dry,
     "the silence pins no additional ring band to the level axis",
     string.format("%d bands pinned with silence vs %d without",
                   pinned_pad, pinned_dry))

  -- 4. And the detector reaches the same verdict.
  ok(math.abs(#pad.cands - #dry.cands) <= 1,
     "the detector finds the same candidates either way",
     string.format("%d with silence vs %d without", #pad.cands, #dry.cands))

  -- 5. The opt-out has to opt out, or the old behaviour is unreachable and
  --    this whole file is asserting against something that cannot happen.
  local item, take = Fixture.add_item(track, WAV, 0, srclen / (1 - SILENCE_FR), 1.0)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  local geo = Analyze.geometry(take)
  local pk = PitchKernel.new(ImGui, ctx, root, geo.nchan, cfg, cfg.pitch_rate)
  local k  = Kernel.new(ImGui, ctx, root, geo.nchan, cfg)
  local F  = Analyze.drive(Analyze.run(take, cfg, pk, k, geo))
  if not F then error("analysis (opt-out): failed", 0) end
  local cube = k:modal_cube()
  local raw  = Spectrum.curve(cube, cfg.percentile / 100.0, k.lev0,
                              Spectrum.floor_bins(cube, false))
  local lo, hi = math.huge, -math.huge
  for i = 1, #raw do
    if raw[i] then lo = math.min(lo, raw[i]) hi = math.max(hi, raw[i]) end
  end
  reaper.DeleteTrackMediaItem(track, item)
  say(string.format("  %-28s %6s    %4d modal frames  p20 spread %5.1f dB",
                    "same, skip_silence OFF", "", F.modal_frames, hi - lo))
  ok(hi - lo < pad.spread - 10.0,
     "with the guard off the curve collapses, as it used to",
     string.format("%.1f dB of spread, against %.1f with it on",
                   hi - lo, pad.spread))
  return true          -- Fixture.run returns nil + message on error, so the
end                    -- success path has to be distinguishable from it

local okrun, err, clean = Fixture.run(body)
if not okrun then fails = fails + 1 say("  FAIL  " .. tostring(err)) end
if clean == false then
  fails = fails + 1
  say("  FAIL  the fixture track was not cleaned up")
end
say("")
say(fails == 0 and "all checks passed" or (fails .. " failed"))
report()
