-- Spectral DeNoise -- end-to-end alignment check. Run from the Actions list
-- with one audio item selected.
--
-- The kernel selftest proves the DSP reconstructs to unity at the reported
-- latency. This proves the *offline* half: that reading through an accessor,
-- compensating that latency by hand, writing a file and hanging it off the
-- item as a take puts every sample back exactly where it came from.
--
-- It renders with Reduction at 0 dB, which is the chain's transparency guard,
-- so a correct pipeline nulls against the source. The classic failure it
-- catches is a latency compensation that is off by an FFT -- audible as the
-- take sliding against the original, and invisible until you A/B them.
--
-- Run it on a time-stretched item too: at playrate 1 the playrate path is
-- never exercised.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Requires ReaImGui.", "DeNoise verify", 0)
  -- A missing dependency is a failed run too, not a quiet pass.
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;" .. reaper.ImGui_GetBuiltinPath()
            .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Kernel  = require "dn.kernel"
local Config  = require "dn.config"
local Analyze = require "dn.analyze"
local Profile = require "dn.profile"
local Render  = require "dn.render"
local Apply   = require "dn.apply"

local SHIFT_SEARCH = 8        -- samples either side to scan for a slip
local WINDOW       = 200000   -- samples compared, from the middle of the item

local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function fail(s) fails = fails + 1 say(s) end
local function report()
  reaper.ShowConsoleMsg("\n=== Spectral DeNoise alignment check ===\n"
                        .. table.concat(out, "\n") .. "\n")
  -- The verdict has to reach the exit code, or a CI job or an `&&` chain reads
  -- a run that printed FAIL as green. Absent when run from the Actions list:
  -- REAPER's Lua has no os.exit, and everything is already printed by here.
  if os.exit then os.exit(fails == 0 and 0 or 1) end
end
-- Anything that stops the check short counts as a failed run, "you did not
-- select an item" included: a green exit has to mean the alignment was
-- actually verified, not that the script declined to look.
local function bail(s) fail(s) report() end

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then bail("Select one audio item first.") return end
local take = reaper.GetActiveTake(item)
if not take or reaper.TakeIsMIDI(take) then
  bail("The selected item has no audio take.") return
end

-- Drive a coroutine to completion, servicing the accessor reads it asks for --
-- it cannot make them itself from inside a coroutine. See dn/analyze.lua.
local drive = Analyze.drive

local cfg = Config.new()
cfg.reduction, cfg.gate_on, cfg.nlm, cfg.residual = 0, false, 0, false
cfg.mode, cfg.new_take, cfg.select_take = 0, true, false

local ctx = ImGui.CreateContext("DeNoise verify")
local geo = Analyze.geometry(take)
say(string.format("item: %d ch at %d Hz, %.2f s of accessor, playrate %.4f",
    geo.nchan, geo.rate, geo.acc_len, geo.playrate))
if math.abs(geo.playrate - 1) < 1e-9 then
  say("note: playrate is 1, so the stretched path is NOT covered by this run.")
else
  say("note: stretched -- the accessor's span is the ITEM length, and the audio")
  say("      it returns already has the playrate applied, so the new take must")
  say("      carry playrate 1. This is the run that proves it.")
end

local k, kerr = Kernel.new(ImGui, ctx, script_dir, geo.nchan,
                           Config.fft_size(cfg), cfg.nlm, geo.rate)
if not k then bail("kernel: " .. tostring(kerr)) return end
say(string.format("kernel: fft %d, %d bins, latency %d samples",
    k.fft_size, k.nbins, Config.latency(cfg)))

local ares, aerr = drive(function() return Analyze.run(take, cfg, k) end)
if not ares then bail("analysis failed: " .. tostring(aerr)) return end
local hist = Profile.histogram(k:counts(), k.nlev, k.lev0)
local th = Profile.band(hist, cfg)
k:build_profile(th.lo_bin, th.hi_bin, cfg.prof_offset_db)
say(string.format("analysis: %d frames, band %.0f..%.0f dB, %.0f in band",
    ares.frames, th.lo_db, th.hi_db, th.frames))

local path = Render.output_path(take, cfg)
local res, rerr = drive(function() return Render.run(take, cfg, k, path) end)
if not res then bail("render failed: " .. tostring(rerr)) return end
say(string.format("render: %d samples to %s", res.samples,
    res.path:match("([^/\\]+)$")))

if res.samples ~= geo.total_samples then
  fail(string.format("MISMATCH: rendered %d samples, accessor span is %d",
       res.samples, geo.total_samples))
end


local nt, aperr = Apply.run(item, take, res, cfg)
if not nt then bail("apply failed: " .. tostring(aperr)) return end

-- The stretch settings must be NEUTRAL on the new take: the render already
-- contains them, because the accessor applied them on the way in. Copying the
-- original's across applied them a second time and slid the take against the
-- source by exactly the playrate -- which is why this check sits ahead of the
-- null, as the null cannot say which of the two mistakes it is seeing.
for key, want in pairs({ D_PLAYRATE = 1, D_PITCH = 0, B_PPITCH = 0,
                         I_CHANMODE = 0 }) do
  local got = reaper.GetMediaItemTakeInfo_Value(nt, key)
  if math.abs(got - want) > 1e-9 then
    fail(string.format("FAIL: the new take has %s = %g, expected %g -- the " ..
      "render already contains it", key, got, want))
  end
end

-- The take must also have a WAVEFORM. REAPER only builds peaks for files that
-- arrive through an import path, so a source made with
-- PCM_Source_CreateFromFile has none and nothing asks for them: the take plays
-- back perfectly and draws an empty lane. Nothing else here can see that --
-- audio is decoded on demand, peaks are not, so the null below passes with the
-- waveform missing.
do
  local pbuf = reaper.new_array(64 * 2)
  pbuf.clear(0)
  local pret = reaper.PCM_Source_GetPeaks(
    reaper.GetMediaItemTake_Source(nt), 8, 0, 1, 64, 0, pbuf)
  local pmax = 0
  for _, v in ipairs(pbuf.table()) do pmax = math.max(pmax, math.abs(v or 0)) end
  if (pret & 0xFFFFF) > 0 and pmax > 0 then
    say(string.format("peaks: %d samples, max %.4f -- the waveform is drawn",
        pret & 0xFFFFF, pmax))
  else
    fail(string.format("FAIL: the new take has no peaks (%d samples, max %.4f)"
      .. " -- it will play back correctly and draw an empty lane",
      pret & 0xFFFFF, pmax))
  end
end

-- Compare the two takes through their own accessors. Both accessor timelines
-- start at the item's first sample, which is the whole point: the original
-- carries a start offset and the render does not, and they still have to line
-- up sample for sample.
local aa_old = reaper.CreateTakeAudioAccessor(take)
local aa_new = reaper.CreateTakeAudioAccessor(nt)
local nch = geo.nchan
local n = math.min(WINDOW, geo.total_samples - 2 * SHIFT_SEARCH)
local start = math.floor((geo.total_samples - n) / 2)

local a = reaper.new_array(n * nch)
local b = reaper.new_array((n + 2 * SHIFT_SEARCH) * nch)
a.clear(0) b.clear(0)
reaper.GetAudioAccessorSamples(aa_old, geo.rate, nch, start / geo.rate, n, a)
reaper.GetAudioAccessorSamples(aa_new, geo.rate, nch,
  (start - SHIFT_SEARCH) / geo.rate, n + 2 * SHIFT_SEARCH, b)
reaper.DestroyAudioAccessor(aa_old)
reaper.DestroyAudioAccessor(aa_new)

local ta = a.table(1, n * nch)
local tb = b.table(1, (n + 2 * SHIFT_SEARCH) * nch)

local best, best_shift = math.huge, nil
for shift = -SHIFT_SEARCH, SHIFT_SEARCH do
  local e = 0
  for i = 0, n - 1 do
    for c = 1, nch do
      local d = math.abs(ta[i * nch + c]
                       - tb[(i + SHIFT_SEARCH + shift) * nch + c])
      if d > e then e = d end
    end
  end
  if e < best then best, best_shift = e, shift end
  if shift == 0 then
    say(string.format("aligned difference: %.3g  (%.1f dBFS)", e,
        20 * math.log(math.max(e, 1e-12), 10)))
  end
end

say(string.format("best alignment: shift %d, difference %.3g", best_shift, best))
if best_shift ~= 0 then
  fail("FAIL: the render is offset from the source by " .. best_shift ..
       " samples -- latency compensation is wrong.")
elseif best > 1e-4 then
  fail(string.format("FAIL: aligned but not transparent (%.1f dBFS). " ..
       "Reduction was 0 dB, so this should null.",
       20 * math.log(best, 10)))
else
  say("PASS: the rendered take nulls against the source, sample aligned.")
end
say("The item now has an extra take; undo to remove it.")
report()
