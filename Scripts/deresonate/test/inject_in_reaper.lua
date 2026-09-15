-- POSITIVE CONTROL for the narrow detector.
--
-- Every other test can pass while the detector finds nothing at all -- and on
-- both real takes it legitimately finds nothing, because neither has a ringing
-- resonance. So the suite that matters most drives REAL vocal audio through a
-- resonator of KNOWN centre frequency, Q and ring time, and asserts the
-- detector recovers it. A detector that has quietly stopped accepting anything
-- fails here and nowhere else.
--
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/inject_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "") .. package.path

local pass, fail = 0, 0
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function near(a,b,tol,name)
  local g = a and b and math.abs(a-b) <= tol
  ok(g, name, g and nil or string.format("%s vs %s tol %s", tostring(a), tostring(b), tostring(tol)))
end
local function bail(m)
  fail = fail + 1; print("  FAIL " .. m)
  print(string.format("\ninject: %d passed, %d failed", pass, fail))
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("no ReaImGui") end
local ImGui       = require "imgui" "0.9"
local Config      = require "dr.config"
local Kernel      = require "dr.kernel"
local PitchKernel = require "dr.pitch_kernel"
local Analyze     = require "dr.analyze"
local Spectrum    = require "dr.spectrum"
local Mask        = require "dr.mask"
local Ring        = require "dr.ring"
local Detect      = require "dr.detect"
local Fixture     = require "fixture"

local ctx = ImGui.CreateContext("DeResonate inject")
local cfg = Config.new()

local INJ_HZ, INJ_T60, INJ_GAIN = 420.0, 0.30, 3.0

-- Two-pole resonator. Its pole radius sets the ring time exactly:
-- r^(T60*sr) = 10^-3, and the -3 dB bandwidth is -ln(r)*sr/pi, so Q follows.
local function make_res(f0, t60, sr)
  local r  = 10 ^ (-3.0 / (t60 * sr))
  local w  = 2 * math.pi * f0 / sr
  local bw = -math.log(r) * sr / math.pi
  return { a1 = 2 * r * math.cos(w), a2 = -r * r, g = (1 - r),
           y1 = 0, y2 = 0, bw = bw, q = f0 / bw, r = r }
end
local function res_run(s, x)
  local y = x + s.a1 * s.y1 + s.a2 * s.y2
  s.y2 = s.y1; s.y1 = y
  return s.g * y
end

-- The fixture is imported into a throwaway tab rather than looked for in the
-- user's project: a suite that depends on what happens to be loaded fails the
-- moment they open their own work, and it must not touch that work either.
local FIXTURE = root .. "Room resonance example.wav"
do
  local fh = io.open(FIXTURE, "r")
  if not fh then bail("fixture wav missing: " .. FIXTURE) end
  fh:close()
end

local FIXTURE_TRACK
local function body(track)
  FIXTURE_TRACK = track

local _, take = Fixture.add_item(FIXTURE_TRACK, FIXTURE, 0, 54.0, 1.0)
if not take then bail("could not build the fixture item") end
local geo = Analyze.geometry(take)
local pk  = PitchKernel.new(ImGui, ctx, root, geo.nchan, cfg, cfg.pitch_rate)
if not pk then bail("pitch kernel would not build") end
local k = Kernel.new(ImGui, ctx, root, geo.nchan, cfg)
if not k then bail("kernel would not build") end

-- pitch/occupancy comes from the untouched take: injecting a resonance does
-- not move the singer's pitch, and the mask must be the real one
local F, aerr = Analyze.drive(Analyze.run(take, cfg, pk, k, geo))
if not F then bail("baseline analysis: " .. tostring(aerr)) end

local hz  = Spectrum.hz_axis(k.half, Config.bin_hz(cfg))
local occ = Mask.occupancy(F, hz, cfg)

-- Now re-read the same audio on the MAIN thread, push it through the
-- resonator, and feed the kernel directly. Reads here are legal because this
-- is not a coroutine.
local aa = reaper.CreateTakeAudioAccessor(take)
if not aa then bail("no accessor") end
local span = math.min(reaper.GetAudioAccessorEndTime(aa) - reaper.GetAudioAccessorStartTime(aa),
                      geo.item_len)

local function feed(rate, task)
  k:reset()
  local st = make_res(INJ_HZ, INJ_T60, rate)
  local total, done = math.floor(span * rate), 0
  local buf = reaper.new_array(k.block * geo.nchan)
  while done < total do
    local n = math.min(k.block, total - done)
    buf.clear(0)
    local got = reaper.GetAudioAccessorSamples(aa, rate, geo.nchan, done / rate, n, buf)
    if got == nil then bail("accessor read failed on the main thread") end
    local t = buf.table(1, n * geo.nchan)
    for i = 1, n * geo.nchan do
      t[i] = t[i] + INJ_GAIN * res_run(st, t[i])
    end
    for i = 1, n * geo.nchan do k.inbuf[i] = t[i] end
    if task == 1 then k:modal(n) else k:ring(n) end
    done = done + n
  end
  return st
end

k:rewind()
local st = feed(cfg.modal_rate, 1)
feed(cfg.pitch_rate, 2)
reaper.DestroyAudioAccessor(aa)

print(string.format("  injected into the fixture: %.1f Hz, T60 %.2f s -> bandwidth %.2f Hz, Q %.0f",
  INJ_HZ, INJ_T60, st.bw, st.q))

local cube = k:modal_cube()
local p20  = Spectrum.curve(cube, cfg.percentile / 100.0, k.lev0)
local hists = k:ring_hist(cfg)
local rhz   = k:ring_hz()
local times = {}
for b = 1, k.nband do times[b] = Ring.time_from_hist(hists[b], cfg, Kernel.ring_time_of) end
local idx = Ring.index(times, rhz, cfg)
local function ring_at(f)
  local b = Spectrum.index_of(rhz, f); return b and idx[b] or nil
end

-- DIAGNOSTIC: which percentile of the ring-time distribution actually moves
-- when a real resonance is present?
do
  local bi0 = Spectrum.index_of(rhz, INJ_HZ)
  local function pct_of(h, p)
    local tot = 0
    for i = 1, #h do tot = tot + h[i] end
    if tot == 0 then return nil end
    local want, run = p * tot, 0
    for i = 1, #h do
      run = run + h[i]
      if run >= want then return Kernel.ring_time_of(i - 1) end
    end
  end
  print("  ring time by percentile (s) -- injected band vs neighbours:")
  print(string.format("  %10s %7s %7s %7s %7s %7s %7s",
    "band Hz", "p05", "p20", "p50", "p80", "p90", "p95"))
  for _, off in ipairs({ -4, -2, 0, 2, 4 }) do
    local b = bi0 + off
    if b >= 1 and b <= k.nband and hists[b] then
      local mark = (off == 0) and "  <== injected" or ""
      print(string.format("  %10.1f %7s %7s %7s %7s %7s %7s%s", rhz[b],
        tostring(pct_of(hists[b], .05) and string.format("%.3f", pct_of(hists[b], .05))),
        tostring(pct_of(hists[b], .20) and string.format("%.3f", pct_of(hists[b], .20))),
        tostring(pct_of(hists[b], .50) and string.format("%.3f", pct_of(hists[b], .50))),
        tostring(pct_of(hists[b], .80) and string.format("%.3f", pct_of(hists[b], .80))),
        tostring(pct_of(hists[b], .90) and string.format("%.3f", pct_of(hists[b], .90))),
        tostring(pct_of(hists[b], .95) and string.format("%.3f", pct_of(hists[b], .95))), mark))
    end
  end
end

local bi = Spectrum.index_of(rhz, INJ_HZ)
print(string.format("  ring time at %.0f Hz: %s s (index %s); neighbours %s / %s",
  rhz[bi], tostring(times[bi] and string.format("%.3f", times[bi])),
  tostring(idx[bi] and string.format("%.2f", idx[bi])),
  tostring(times[bi-2] and string.format("%.3f", times[bi-2])),
  tostring(times[bi+2] and string.format("%.3f", times[bi+2]))))

cfg._schroeder_hz = 243.0
local cands = Detect.run(p20, hz, occ, ring_at, cfg, Config.bin_hz(cfg))
print("  -- candidates --")
for i = 1, math.min(#cands, 6) do print("     " .. Detect.describe(cands[i])) end

local hit
for _, c in ipairs(cands) do
  if math.abs(c.hz - INJ_HZ) <= 6.0 then hit = c; break end
end
ok(hit ~= nil, "the injected resonance appears as a candidate")
if hit then
  near(hit.hz, INJ_HZ, 4.0, "found at the right frequency")
  ok(hit.q and hit.q > 15 and hit.q < 200, "with a plausible Q", hit.q)
  ok(hit.accepted, "and it is ACCEPTED",
     hit.accepted and "" or table.concat(hit.reasons, ", "))
  -- Documented limitation, asserted so it cannot regress silently in either
  -- direction: the ring index is measured, and it does NOT separate a genuine
  -- injected resonance from its neighbours. If this ever starts passing, the
  -- ring test has become useful and should be promoted back to a gate.
  ok(hit.ring_index ~= nil, "the ring index is measured", hit.ring_index)
  ok(hit.ring_index < cfg.min_ring_index,
     "and -- known limit -- it still fails to see a real 0.30 s resonance",
     string.format("%.2f; if this now exceeds %.2f, promote it back to a gate",
                   hit.ring_index, cfg.min_ring_index))
end

end

local _, terr, clean = Fixture.run(body)
if terr then ok(false, "the fixture run raised: " .. tostring(terr)) end
ok(clean, "the fixture track was removed")

print(string.format("\ninject: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
