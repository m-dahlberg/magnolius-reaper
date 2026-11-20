-- Loudness Envelope -- kernel and panel selftest. Runs inside REAPER.
--
-- Part 1 drives the EEL kernel on generated signals whose answers can be
-- worked out on paper, with no accessor and no project near it -- the first
-- stage of the bisect: if this passes and the panel reports nonsense, the
-- fault is in the accessor or the geometry, not the DSP.
--
-- The load-bearing assertion is the quadrature pair. L = A sin, R = A cos is
-- a signal on which the three plausible reductions all give different
-- answers: the per-channel mean is A^2/2, the channel sum A^2, and the
-- rider's per-sample louder channel A^2 (1/2 + 1/pi). Only the last is right,
-- and only this signal tells them apart.
--
-- Part 2 renders the panel against a stub ImGui, empty and populated, quiet
-- and with every control moved. It never clicks Analyse or Write.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local restore = {}
local function say(s) out[#out + 1] = s end
local function report()
  for i = #restore, 1, -1 do pcall(restore[i]) end
  say(string.format("selftest: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %.6g (tol %.3g)", tostring(a), b, tol))
end
-- Anything that stops the run counts as a failure.
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") return end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui  = require "imgui" "0.9"
local Config = require "le.config"
local Kernel = require "le.kernel"
local Curve  = require "le.curve"

-- ReaImGui destroys a context left unused for a few seconds; ask through here
-- so it is checked at every use and rebuilt when it has gone.
local ctx
local function get_ctx()
  local okv, v = pcall(ImGui.ValidatePtr, ctx, "ImGui_Context*")
  if ctx and okv and v == true then return ctx end
  ctx = ImGui.CreateContext("Loudness Envelope selftest")
  return ctx
end

-- Push `nframes` frames of gen(t, ch) through a kernel, in blocks, sampled at
-- absolute time so the signal is continuous across block boundaries. Returns
-- per-frame mean energies and sample counts.
local function push(k, gen, nframes)
  local E, N = {}, {}
  local done = 0
  while done < nframes do
    local nf = math.min(k.frames, nframes - done)
    local s0 = Kernel.frame_sample(done, k.hopf)
    local s1 = Kernel.frame_sample(done + nf, k.hopf)
    local buf = {}
    for i = 0, s1 - s0 - 1 do
      local t = (s0 + i) / k.rate
      for c = 0, k.nchan - 1 do buf[#buf + 1] = gen(t, c) end
    end
    k.inbuf.clear(0)
    if #buf > 0 then k.inbuf.copy(buf) end
    local e, n = k:measure(done, nf, s1 - s0)
    local et, nt = e.table(1, nf), n.table(1, nf)
    for i = 1, nf do
      E[done + i] = nt[i] > 0 and et[i] / nt[i] or 0
      N[done + i] = nt[i]
    end
    done = done + nf
  end
  return E, N
end

local function mean(t, a, b)
  local s = 0
  for i = a, b do s = s + t[i] end
  return s / (b - a + 1)
end

------------------------------------------------------------------- kernel

say("kernel")
do
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 1, 48000)
  if not k then bail("mono kernel would not build: " .. tostring(err)) return end
  ok(k.heap_used > 0, "heap probe ran")
  local A = 0.5
  local E = push(k, function(t) return A * math.sin(2 * math.pi * 1000 * t) end, 50)
  -- 10 ms at 48 kHz is exactly ten cycles of 1 kHz, so every frame is exact.
  near(E[1], A * A / 2, 1e-9, "mono sine: frame mean energy is A^2/2")
  near(E[50], A * A / 2, 1e-9, "and still is fifty frames on")
  near(Curve.db10(E[25]), 20 * math.log(A, 10) - 3.0103, 1e-3,
       "which is -9.03 dB for A = 0.5")
end

do
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 2, 48000)
  if not k then bail("stereo kernel would not build: " .. tostring(err)) return end
  local A = 0.5
  local E = push(k, function(t, c)
    local w = 2 * math.pi * 1000 * t
    return c == 0 and A * math.sin(w) or A * math.cos(w)
  end, 40)
  -- A^2 (1/2 + 1/pi) in continuous time; on a 48-sample cycle the discrete
  -- mean differs by 0.2%, so the expectation is taken on the same grid.
  local want = 0
  for i = 0, 479 do
    local w = 2 * math.pi * 1000 * i / 48000
    want = want + math.max((A * math.sin(w)) ^ 2, (A * math.cos(w)) ^ 2)
  end
  want = want / 480
  near(want, A * A * (0.5 + 1 / math.pi), 1e-3, "(the expectation is the 1/2 + 1/pi figure)")
  near(mean(E, 1, 40), want, 1e-9,
       "quadrature stereo: the per-sample louder channel, as the rider measures")
  ok(math.abs(mean(E, 1, 40) - A * A / 2) > 0.03, "not the per-channel mean")
  ok(math.abs(mean(E, 1, 40) - A * A) > 0.03, "not the channel sum")

  local E2 = push(k, function(t, c)
    local s = math.sin(2 * math.pi * 1000 * t)
    return c == 0 and 0.1 * s or 0.4 * s
  end, 10)
  near(E2[5], 0.4 * 0.4 / 2, 1e-9, "the louder channel wins whichever side it is on")
end

do
  -- 44056 Hz: a 10 ms hop of 440.56 samples. An integer hop would drift
  -- 0.56 samples a frame -- over half a second across a three-minute take.
  local rate = 44056
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 1, rate)
  if not k then bail("fractional-rate kernel would not build: " .. tostring(err)) return end
  local nf = 1000
  local _, N = push(k, function() return 0.25 end, nf)
  local total, exact = 0, true
  for f = 1, nf do
    total = total + N[f]
    local want = Kernel.frame_sample(f, k.hopf) - Kernel.frame_sample(f - 1, k.hopf)
    if N[f] ~= want then exact = false end
  end
  ok(exact, "every frame holds the samples its own time-defined edges say")
  ok(total == Kernel.frame_sample(nf, k.hopf),
     "1000 frames end exactly at sample round(1000 * hop)",
     string.format("%d vs %d", total, Kernel.frame_sample(nf, k.hopf)))
  near(nf * Config.FRAME_S, total / rate, 1 / rate, "and so at 10.000 s, not drifted")
end

do
  local k = Kernel.new(ImGui, get_ctx(), script_dir, 1, 48000)
  local E, N = push(k, function() return 0 end, 3)
  ok(E[1] == 0 and N[1] == 480, "silence is zero energy over a full frame")
  local e, n = k:measure(0, 2, 100)                -- a block shorter than its frames
  local nt = n.table(1, 2)
  ok(nt[1] == 100 and nt[2] == 0, "a short final read is measured over what exists",
     string.format("%d, %d", nt[1], nt[2]))
end

-------------------------------------------------------------------- panel

say("panel against a stub ImGui")

local Frame = require "ui_frame"
local UI    = require "le.ui"

-- _init loads from ExtState and the `changed` cases save to it, so snapshot
-- the section and put it back.
do
  local saved = {}
  for key in pairs(Config.defaults) do
    if reaper.HasExtState(Config.EXT_SECTION, key) then
      saved[key] = reaper.GetExtState(Config.EXT_SECTION, key)
    end
  end
  restore[#restore + 1] = function()
    for key in pairs(Config.defaults) do
      if saved[key] then reaper.SetExtState(Config.EXT_SECTION, key, saved[key], true)
      else reaper.DeleteExtState(Config.EXT_SECTION, key, true) end
    end
  end
end

local function synthetic_F()
  local E = {}
  local function e(db) return 10 ^ (db / 10) end
  for _ = 1, 100 do E[#E + 1] = e(-70) end
  for i = 1, 600 do E[#E + 1] = e(-22 + ((i % 25) < 17 and 3 or -10)) end
  for _ = 1, 150 do E[#E + 1] = e(-60) end
  for i = 1, 600 do E[#E + 1] = e(-16 + ((i % 25) < 17 and 3 or -10)) end
  return { t0 = 12.5, hop = Config.FRAME_S, n = #E, E = E }
end

local function populate(ST)
  ST.F = synthetic_F()
  ST.src = { track = nil, name = "fixture source", clips = {}, t0 = 12.5,
             t1 = 12.5 + ST.F.n * Config.FRAME_S }
  ST.key = "fixture"
  ST.csig = nil                 -- forces the frame to rebuild the curve
  ST.status = "fixture"
  ST.hover_t = 15
end

local function case(name, prepare, clicks, changed, drop)
  local ran, err, log, ST = Frame.run(UI, script_dir, prepare, clicks, changed, drop)
  ok(ran, name, tostring(err))
  ok(log.push == log.pop, name .. ": style colours balance",
     string.format("%d pushed, %d popped", log.push, log.pop))
  ok(log.dis == 0, name .. ": disabled scopes balance", tostring(log.dis))
  ok(log.child == 0, name .. ": child windows balance", tostring(log.child))
  return ST
end

case("an empty panel renders")
local ST = case("a populated panel renders", populate)
ok(ST.res ~= nil and #ST.res.points >= 2, "and built a curve in the frame",
   tostring(ST.res_err))
case("every control moved", populate, nil, true)
case("every control moved, empty", nil, nil, true)
case("a curve that cannot be built renders its reason", function(S)
  populate(S)
  for i = 1, S.F.n do S.F.E[i] = 0 end
end)
case("depth 0 and no smoothing", function(S, c)
  populate(S)
  c.depth_pct, c.smooth_s = 0, 0
end)
case("the controls column is hidden", function(S)
  populate(S)
  S.show_controls = false
end)
case("a job in flight renders", function(S)
  populate(S)
  S.job = coroutine.create(function() coroutine.yield(0.5) end)
  S.jobkind, S.progress = "Analysing", 0.5
end)
case("error and warning lines render", function(S)
  populate(S)
  S.err, S.warn = "something went wrong", "a warning"
end)
case("guessed rate notice renders", function(S)
  populate(S)
  S.rate_guessed = true
end)
case("reset settings clicks", populate, { ["Reset settings"] = true })
case("without the optional symbols", populate, nil, false,
     { SeparatorText = true, ChildFlags_ResizeX = true, ChildFlags_Borders = true })

report()
