-- Run the whole M1 analysis over the example takes in the open project and
-- print what every detector says. This is the fixture that decides whether the
-- RULES are right -- synthetic tests can only prove the stages behave as
-- written.
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/analyse_real_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;"
            .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "")
            .. package.path

local fail = 0
local function bail(m) fail = fail + 1; print("  FAIL " .. m) end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui"); if os.exit then os.exit(1) end return end
local ImGui       = require "imgui" "0.9"
local Config      = require "dr.config"
local Kernel      = require "dr.kernel"
local PitchKernel = require "dr.pitch_kernel"
local Analyze     = require "dr.analyze"
local Spectrum    = require "dr.spectrum"
local Mask        = require "dr.mask"
local Ring        = require "dr.ring"
local Broad       = require "dr.broad"
local Detect      = require "dr.detect"
local Solve       = require "dr.solve"
local Auto        = require "dr.auto"
local Fixture     = require "fixture"

local ctx = ImGui.CreateContext("DeResonate real analysis")
local cfg = Config.new()

-- The reference wavs are imported into a throwaway tab. Looking for them in
-- the open project makes the run depend on what the user happens to have
-- loaded, and gives it a reason to touch their session; neither is wanted.
local WAVS = { "Room reverb example.wav", "Room resonance example.wav" }

local function body(track)
local takes = {}
local at = 0.0
for _, name in ipairs(WAVS) do
  local probe = reaper.PCM_Source_CreateFromFile(root .. name)
  if probe then
    local len = reaper.GetMediaSourceLength(probe)
    reaper.PCM_Source_Destroy(probe)
    -- laid end to end: two items at the same position on one track overlap
    local _, tk = Fixture.add_item(track, root .. name, at, len, 1.0)
    at = at + len + 5.0
    if tk then takes[#takes + 1] = { take = tk, name = name } end
  end
end
if #takes == 0 then bail("neither reference wav could be imported") end

for _, T in ipairs(takes) do
  print("\n================ " .. T.name .. " ================")
  local geo = Analyze.geometry(T.take)
  print(string.format("  %.1f s, %d ch, %d Hz%s, playrate %.3f",
    geo.item_len, geo.nchan, geo.rate, geo.rate_known and "" or " (GUESSED)", geo.playrate))

  local pk, perr = PitchKernel.new(ImGui, ctx, root, geo.nchan, cfg, cfg.pitch_rate)
  if not pk then bail("pitch kernel: " .. tostring(perr)) goto continue end
  local k, kerr = Kernel.new(ImGui, ctx, root, geo.nchan, cfg)
  if not k then bail("kernel: " .. tostring(kerr)) goto continue end

  local t0 = reaper.time_precise()
  local F, err = Analyze.drive(Analyze.run(T.take, cfg, pk, k, geo))
  if not F then bail("analysis: " .. tostring(err)) goto continue end
  print(string.format("  analysed in %.1f s -- %d pitch frames, %d modal, %d ring",
    reaper.time_precise() - t0, F.n, F.modal_frames, F.ring_frames))

  -- voicing / pitch summary
  local vf = {}
  for i = 1, F.n do if Mask.voiced(F, i, cfg) then vf[#vf + 1] = F.f0[i] end end
  table.sort(vf)
  if #vf > 0 then
    local function q(p) return vf[math.max(1, math.floor(p * #vf))] end
    print(string.format("  voiced %d/%d (%.0f%%), f0 p05 %.1f  p50 %.1f  p95 %.1f Hz -> %s",
      #vf, F.n, 100 * #vf / F.n, q(.05), q(.5), q(.95),
      q(.5) < 175 and "LOW/MALE" or "high/female"))
  end

  local hz   = Spectrum.hz_axis(k.half, Config.bin_hz(cfg))
  local cube = k:modal_cube()
  local p20  = Spectrum.curve(cube, cfg.percentile / 100.0, k.lev0)
  local p90  = Spectrum.curve(cube, 0.90, k.lev0)
  local occ  = Mask.occupancy(F, hz, cfg)

  -- ring index
  local hists = k:ring_hist(cfg)
  local rhz   = k:ring_hz()
  local times, counts = {}, {}
  for b = 1, k.nband do
    times[b], counts[b] = Ring.time_from_hist(hists[b], cfg, Kernel.ring_time_of)
  end
  local idx = Ring.index(times, rhz, cfg)
  local nmeas = 0
  for b = 1, k.nband do if idx[b] then nmeas = nmeas + 1 end end
  print(string.format("  ring index measured in %d/%d bands", nmeas, k.nband))
  local function ring_at(f)
    local b = Spectrum.index_of(rhz, f)
    return b and idx[b] or nil
  end

  -- broadband ring time, and what auto mode makes of it
  local all = {}
  for b = 1, k.nband do if times[b] then all[#all + 1] = times[b] end end
  table.sort(all)
  local p50r
  if #all > 0 then
    p50r = all[math.max(1, math.floor(0.50 * #all))]
    print(string.format("  ring time across bands: p10 %.2f  p50 %.2f  p90 %.2f s",
      all[math.max(1, math.floor(0.10 * #all))], p50r,
      all[math.max(1, math.floor(0.90 * #all))]))
  end
  local auto, why = Auto.estimate(p50r, #all, false)
  if auto then
    print(string.format("  auto: T60 %.2f s%s, reduction %.0f dB  (before clamping: %.2f s)",
      auto.t60, auto.dry and " -- AT THE DRY FLOOR" or "", auto.reduction, auto.raw))
  else
    print("  auto: no estimate -- " .. tostring(why))
  end

  cfg._schroeder_hz = Detect.schroeder_hz(all[math.floor(#all / 2)] or 0.4, 30.0)
  local env = Spectrum.smooth_power(p20, hz, 1.0 / cfg.smooth_oct)
  local cands = Detect.run(p20, hz, occ, ring_at, cfg, Config.bin_hz(cfg))
  local nacc = 0
  print("  -- narrow candidates --")
  for i = 1, math.min(#cands, 10) do
    if cands[i].accepted then nacc = nacc + 1 end
    print("     " .. Detect.describe(cands[i]))
  end
  if #cands == 0 then print("     (none)") end
  print(string.format("     %d accepted of %d examined", nacc, #cands))

  print("  -- broad colouration --")
  -- start the broad search above the singer's own fundamental range
  local f0_hi = (#vf > 0) and vf[math.max(1, math.floor(0.95 * #vf))] or 0
  local blo = math.max(cfg.search_lo_hz, f0_hi * 1.15)
  print(string.format("     (searching above %.0f Hz -- f0 p95 is %.0f Hz)", blo, f0_hi))
  local humps = Broad.humps(p90, p20, hz, cfg, blo)
  for i = 1, math.min(#humps, 6) do print("     " .. Broad.describe(humps[i])) end
  if #humps == 0 then print("     (none above " .. cfg.min_broad_db .. " dB)") end
  print("  -- correction plan --")
  local function level_at(f)
    local i = Spectrum.index_of(hz, f); return i and p20[i]
  end
  local function target_at(f)
    local i = Spectrum.index_of(hz, f); return i and env[i]
  end
  local plan = Solve.plan(cands, humps, level_at, target_at, cfg, geo.rate)
  if #plan == 0 then print("     (nothing to correct)") end
  for _, f in ipairs(plan) do print("     " .. Solve.describe(f)) end
  ::continue::
end
end

local _, terr, clean = Fixture.run(body)
if terr then bail("the fixture run raised: " .. tostring(terr)) end
if not clean then bail("the fixture track was not removed") end

print(string.format("\nreal analysis: %d failures", fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
