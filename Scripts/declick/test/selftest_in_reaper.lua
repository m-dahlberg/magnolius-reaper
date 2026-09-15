-- Adaptive De-Click -- kernel self test. Run from the Actions list.
--
-- Drives the EEL kernel directly on synthetic signals with known answers, with
-- no item, no accessor and no project state involved. Run this first if
-- anything looks wrong: it isolates the DSP from everything around it, and it
-- is the only test that can reach the EEL at all -- test/headless checks the
-- Lua algorithms, but not their transcription.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function section(s) say("-- " .. s) end
-- Anything that stops the run is a failure, not a quiet pass: a green exit has
-- to mean the thing was verified, not that the script declined to look.
local function bail(msg)
  fail = fail + 1
  say("  FAIL  " .. msg)
  reaper.ShowConsoleMsg(table.concat(out, "\n") ..
    string.format("\n\n%d passed, %d failed\n", pass, fail))
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") return end
package.path = script_dir .. "?.lua;" .. reaper.ImGui_GetBuiltinPath()
            .. "/?.lua;" .. package.path

local ImGui  = require "imgui" "0.9"
local Kernel = require "dc.kernel"
local Config = require "dc.config"
local Detect = require "dc.detect"

local ctx = ImGui.CreateContext("De-Click selftest")
local SR = 48000
local LEN = 3.0                       -- seconds
local N = math.floor(SR * LEN)
local BED_FREQ, BED_AMP = 440, 0.3
local CLICKS = { 24000, 48000, 72000, 96000, 120000 }
local R_ONLY = 132000
local SHAPE = { 0.6, -0.5, 0.4 }      -- the same shape the JSFX render test uses

local function cfg_of(t)
  local c = Config.new()
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

local function geom(nch)
  return { nchan = nch, rate = SR, total_samples = N, acc_len = LEN,
           playrate = 1, item_len = LEN }
end

-- Interleaved test signal: a steady tone, optionally with clicks on top.
local function signal(nch, with_clicks, r_only)
  local s = {}
  for i = 0, N - 1 do
    local v = BED_AMP * math.sin(2 * math.pi * BED_FREQ * i / SR)
    for c = 0, nch - 1 do s[i * nch + c + 1] = v end
  end
  if with_clicks then
    for _, p in ipairs(CLICKS) do
      for j, v in ipairs(SHAPE) do
        for c = 0, nch - 1 do s[(p + j - 1) * nch + c + 1] = s[(p + j - 1) * nch + c + 1] + v end
      end
    end
  end
  if r_only and nch > 1 then
    for j, v in ipairs(SHAPE) do
      local idx = (R_ONLY + j - 1) * nch + 2
      s[idx] = s[idx] + v
    end
  end
  return s
end

-- Push an interleaved signal through a task, a block at a time.
local function pump(k, sig, nch, fn)
  local i = 0
  while i < N do
    local n = math.min(k.block, N - i)
    local t = {}
    for j = 1, n * nch do t[j] = sig[i * nch + j] or 0 end
    k.inbuf.clear(0)
    k.inbuf.copy(t, 1, n * nch, 1)
    fn(n)
    i = i + n
  end
end

local function analyse(k, sig, nch)
  k:reset_stream()
  pump(k, sig, nch, function(n) k:analyze(n) end)
end

local function render(k, cfg, sig, nch, isolate)
  k:reset_stream()
  local o, w = {}, 0
  pump(k, sig, nch, function(n)
    k:process(n, isolate)
    local t = k.outbuf.table(1, n * nch)
    for j = 1, n * nch do o[w + j] = t[j] end
    w = w + n * nch
  end)
  return o
end

local function make(cfg, nch)
  local k, err = Kernel.new(ImGui, ctx, script_dir, geom(nch), cfg)
  if not k then bail("kernel: " .. tostring(err)) end
  return k
end

--------------------------------------------------------------------- setup

section("setup")
local base = cfg_of({})
local k = make(base, 2)
ok(k ~= nil, "the kernel compiles and allocates")
ok(k.nsteps > 500, "step count matches the take length", tostring(k.nsteps))
ok(k.stepsz == 240, "5 ms at 48 kHz is 240 samples", tostring(k.stepsz))
ok(k.nhist == 260 and k.hist_bin == 0.25, "the histogram axis came back")
say(string.format("  ..    %.1f MB of envelope cache", k.heap_mb))

----------------------------------------------------------------- detection

section("detection")
local clicky = signal(2, true, false)
local clean  = signal(2, false, false)

analyse(k, clean, 2)
local st = k:detect(base, 6.0)
ok(st.events == 0, "a steady tone produces no detections at 6 dB",
   tostring(st.events))
ok(st.cut_steps == 0, "and no step carries a cut")

analyse(k, clicky, 2)
st = k:detect(base, 6.0)
ok(st.events > 0, "clicks on the same tone are detected", tostring(st.events))

do
  -- Every injected click should have an event within a step or two of it. The
  -- position is what the take markers and the display both hang on, so an
  -- offset here is an offset everywhere.
  local ev = k:events(st.kept)
  local found = 0
  for _, p in ipairs(CLICKS) do
    for _, e in ipairs(ev) do
      if math.abs(e.pos - p) <= 3 * k.stepsz then found = found + 1 break end
    end
  end
  ok(found == #CLICKS, "every injected click is located",
     string.format("%d of %d", found, #CLICKS))
  local over = 0
  for _, e in ipairs(ev) do over = math.max(over, e.over_db) end
  ok(over > 6, "and stands well over the threshold",
     string.format("%.1f dB", over))
end

do
  -- Raising the threshold must only ever remove detections. This is the
  -- monotonicity the whole adaptive scheme leans on: if it does not hold, the
  -- histogram cannot be used to place a threshold at all.
  local prev, mono, trace = math.huge, true, {}
  for _, s in ipairs({ 2, 6, 12, 20, 30, 42 }) do
    local n = k:detect(base, s).events
    if n > prev then mono = false end
    prev = n
    trace[#trace + 1] = string.format("%d dB:%d", s, n)
  end
  ok(mono, "detection count is monotone in the threshold")
  -- The count does not fall to zero on this fixture, and that is correct: a
  -- 0.6 click on a 0.3 tone overshoots the near-silent bands above 1 kHz by
  -- far more than 42 dB, so no threshold on the slider clears it. Recorded
  -- rather than asserted, because it is a property of the signal, not the code.
  say("  ..    counts across the sweep -- " .. table.concat(trace, "  "))
end

do
  -- The survey histogram is what autothresh reads, so its total has to be the
  -- event count it was built from. This is the seam between the kernel and the
  -- pure Lua stage, and seams like this one are where the bugs live.
  local floor_st = k:detect(base, base.sens_floor_db)
  local h = k:histogram()
  local total = 0
  for b = 0, h.n - 1 do total = total + (h.counts[b] or 0) end
  ok(total == floor_st.kept, "the histogram totals the events it was built from",
     string.format("%d vs %d", total, floor_st.kept))
  ok(h.lo == -5 and h.bin == 0.25, "on the axis Lua expects")
end

do
  -- The cut-depth clamp is the one guard this port adds to the plugin, which
  -- computes depth from the measured overshoot with no ceiling at all. A large
  -- overshoot would otherwise dig a hole deep enough to hear.
  local tight = cfg_of({ max_cut_db = 6 })
  k:detect(tight, 6.0)
  local bc, bs = k:bands()
  local deepest = 0
  for b = 1, #bc do
    if bc[b] > 0 then deepest = math.min(deepest, bs[b] / bc[b]) end
  end
  ok(deepest >= -6.0001, "no cut goes past the clamp",
     string.format("%.2f dB", deepest))

  local loose = cfg_of({ max_cut_db = 48 })
  k:detect(loose, 6.0)
  local bc2, bs2 = k:bands()
  local deepest2 = 0
  for b = 1, #bc2 do
    if bc2[b] > 0 then deepest2 = math.min(deepest2, bs2[b] / bc2[b]) end
  end
  ok(deepest2 < -6.0001, "and lifting the clamp lets deeper cuts through",
     string.format("%.2f dB", deepest2))
end

do
  local bc = select(1, k:bands())
  local hit, total = 0, 0
  for b = 1, #bc do
    total = total + bc[b]
    if bc[b] > 0 then hit = hit + 1 end
  end
  k:detect(base, 6.0)
  ok(total > 0, "the per-band tally is populated")
  ok(hit >= 3, "a broadband click lights several bands", tostring(hit))
end

------------------------------------------------------------- band selection

section("band selection")
do
  -- Two band-limited bursts: one low, one high. Restricting the detection band
  -- must actually stop the out-of-band one being found -- redrawing the strip
  -- while still detecting everything would look identical in the panel.
  local LF_POS, HF_POS, BURST = 24000, 72000, 144   -- 3 ms at 48 kHz
  local function burst_signal(nch)
    local s = {}
    for i = 0, N - 1 do
      local v = BED_AMP * math.sin(2 * math.pi * BED_FREQ * i / SR)
      for c = 0, nch - 1 do s[i * nch + c + 1] = v end
    end
    local function add(pos, freq)
      for j = 0, BURST - 1 do
        -- Hann-windowed, so the burst really is band-limited and the test is
        -- about the band and not about a broadband edge.
        local wnd = 0.5 - 0.5 * math.cos(2 * math.pi * j / BURST)
        local v = 0.6 * wnd * math.sin(2 * math.pi * freq * j / SR)
        for c = 0, nch - 1 do
          local idx = (pos + j) * nch + c + 1
          s[idx] = (s[idx] or 0) + v
        end
      end
    end
    add(LF_POS, 200)
    add(HF_POS, 6000)
    return s
  end

  local function found_near(ev, pos, tol)
    for _, e in ipairs(ev) do
      if math.abs(e.pos - pos) <= tol then return true end
    end
    return false
  end

  local bsig = burst_signal(2)
  analyse(k, bsig, 2)

  local function run(lo, hi)
    -- Reach off: this block is about which bands may take part, and the low
    -- burst is exactly the shape the reach test exists to reject.
    local c = cfg_of({ det_lo_hz = lo, det_hi_hz = hi, min_reach_hz = 0 })
    local st = k:detect(c, 6.0)
    local ev = k:events(st.kept)
    return st, found_near(ev, LF_POS, 4 * k.stepsz),
               found_near(ev, HF_POS, 4 * k.stepsz)
  end

  local stAll, lfAll, hfAll = run(150, 9600)
  ok(lfAll and hfAll, "with the full span both bursts are found",
     string.format("lf=%s hf=%s of %d events", tostring(lfAll), tostring(hfAll),
                   stAll.events))

  local stHi, lfHi, hfHi = run(2000, 9600)
  ok(hfHi, "restricted to the top, the high burst is still found")
  ok(not lfHi, "and the low burst is not")
  ok(stHi.band_lo > 0, "the reported band range moved up",
     string.format("%d..%d", stHi.band_lo, stHi.band_hi))

  local stLo, lfLo, hfLo = run(150, 500)
  ok(lfLo, "restricted to the bottom, the low burst is found")
  ok(not hfLo, "and the high burst is not")

  ok(stHi.events < stAll.events and stLo.events < stAll.events,
     "either restriction detects less than the full span",
     string.format("all=%d hi=%d lo=%d", stAll.events, stHi.events, stLo.events))

  -- The per-band tally must agree with the selection, or the strip lies about
  -- what is happening.
  local bc = k:bands()
  local outside = 0
  for b = 1, #bc do
    if (b - 1) < stLo.band_lo or (b - 1) > stLo.band_hi then
      outside = outside + (bc[b] or 0)
    end
  end
  ok(outside == 0, "no band outside the selection reports a detection",
     tostring(outside))

  -- The reach test, on the same two bursts. This is a different question from
  -- band selection: not "which bands may take part" but "how high does what
  -- would be removed still stand over its own background". The low burst is a
  -- 200 Hz event with nothing above it, which is the shape a plosive has; the
  -- high one reaches. Both are detected with the test off, so a rejection here
  -- is the test acting and not the signal failing to produce a candidate.
  local function reach_run(hz)
    local c = cfg_of({ min_reach_hz = hz })
    local st = k:detect(c, 6.0)
    local ev = k:events(st.kept)
    return st, found_near(ev, LF_POS, 4 * k.stepsz),
               found_near(ev, HF_POS, 4 * k.stepsz)
  end
  local stR0, lf0, hf0 = reach_run(0)
  ok(lf0 and hf0, "with the reach test off both bursts are found")
  local stR, lfR, hfR = reach_run(3000)
  ok(hfR, "requiring reach to 3 kHz keeps the 6 kHz burst")
  ok(not lfR, "and drops the 200 Hz one, which has nothing up there")
  ok(stR.events < stR0.events, "so the test removes events rather than none",
     string.format("off=%d on=%d", stR0.events, stR.events))
  -- Clamped, not silently fatal: asking for reach above the analysed span must
  -- fall back to the top band rather than qualifying nothing and reporting a
  -- clean file.
  ok(Config.reach_band(cfg_of({ min_reach_hz = 999999 })) == base.nbands - 1,
     "a reach above the span clamps to the top band")
  ok(Config.reach_band(cfg_of({ min_reach_hz = 0 })) == -1, "and 0 is off")

  -- The survey must not see the reach test, or the histogram loses the very
  -- population the threshold estimators fit. Same signal, same floor: the
  -- surveyed count has to be identical whether reach is on or off.
  local sOff = Detect.survey(k, cfg_of({ min_reach_hz = 0 }))
  local sOn  = Detect.survey(k, cfg_of({ min_reach_hz = 6000 }))
  ok(sOn.events == sOff.events,
     "the survey is unaffected by the reach test",
     string.format("off=%d on=%d", sOff.events, sOn.events))
  ok(sOff.events > 0, "and it surveyed something", tostring(sOff.events))

  analyse(k, clicky, 2)   -- leave the kernel as the later sections expect
end

---------------------------------------------------------------- event length

section("event length")
do
  -- The axis sep and max_steps do not cover: a click and a fricative have the
  -- same onset and differ in whether the sound is still going 150 ms later.
  --
  -- Both events here are the SAME 3 ms burst at the same frequency. The only
  -- difference is what surrounds one of them: 150 ms of the same tone 9.5 dB
  -- down, which is what a fluctuation inside a sustained sound looks like to a
  -- detector whose background reaches only +-20 ms.
  --
  -- Every edge is windowed. An abrupt 3 ms burst is broadband splatter, and
  -- the detector would then trigger in a high band where the plateau has no
  -- energy at all -- the test would pass while measuring nothing.
  local ISO_POS, SUS_POS = 24000, 96000
  local BURST, PLATEAU, RAMP = 144, 7200, 240   -- 3 ms, 150 ms, 5 ms
  local TONE = 6000

  local function sig(nch)
    local s = {}
    for i = 0, N - 1 do
      local v = BED_AMP * math.sin(2 * math.pi * BED_FREQ * i / SR)
      for c = 0, nch - 1 do s[i * nch + c + 1] = v end
    end
    local function add(pos, len, amp, ramp)
      for j = 0, len - 1 do
        local w = 1
        if ramp == nil then
          w = 0.5 - 0.5 * math.cos(2 * math.pi * j / len)   -- full Hann
        elseif j < ramp then
          w = 0.5 - 0.5 * math.cos(math.pi * j / ramp)
        elseif j >= len - ramp then
          w = 0.5 - 0.5 * math.cos(math.pi * (len - 1 - j) / ramp)
        end
        local v = amp * w * math.sin(2 * math.pi * TONE * (pos + j) / SR)
        for c = 0, nch - 1 do
          local idx = (pos + j) * nch + c + 1
          s[idx] = (s[idx] or 0) + v
        end
      end
    end
    add(ISO_POS, BURST, 0.6)                          -- a click: nothing around it
    add(SUS_POS, PLATEAU, 0.2, RAMP)                  -- 150 ms of held tone
    add(SUS_POS + PLATEAU // 2, BURST, 0.6)           -- the same burst inside it
    return s
  end

  local function near(ev, pos)
    for _, e in ipairs(ev) do
      if math.abs(e.pos - pos) <= 4 * k.stepsz then return true end
    end
    return false
  end
  local function run(ms)
    local st = k:detect(cfg_of({ max_event_ms = ms }), 6.0)
    local ev = k:events(st.kept)
    return st, near(ev, ISO_POS), near(ev, SUS_POS + PLATEAU // 2)
  end

  analyse(k, sig(2), 2)

  -- The control that makes the rest mean anything: with the test off, the
  -- sustained one IS found. Otherwise "not detected" could just mean the
  -- signal never produced a candidate and the guard was never consulted.
  local stOff, isoOff, susOff = run(0)
  ok(isoOff, "with the test off the isolated burst is found")
  ok(susOff, "and so is the one inside the plateau")

  local stOn, isoOn, susOn = run(25)
  ok(isoOn, "at 25 ms the isolated burst is still found")
  ok(not susOn, "but the one inside the plateau is rejected")
  ok(stOn.events < stOff.events, "so the cap removes events rather than none",
     string.format("off=%d on=%d", stOff.events, stOn.events))

  local n200 = select(1, run(200)).events
  local n10  = select(1, run(10)).events
  ok(n10 <= stOn.events and stOn.events <= n200,
     "and is monotone in the cap",
     string.format("10ms=%d 25ms=%d 200ms=%d", n10, stOn.events, n200))

  analyse(k, clicky, 2)   -- leave the kernel as the later sections expect
end

------------------------------------------------------------------- repair

section("repair")
do
  k:detect(base, 6.0)
  local wet = render(k, base, clicky, 2, false)
  local function peak_near(sig, p, r, nch, c)
    local m = 0
    for i = math.max(0, p - r), math.min(N - 1, p + r) do
      m = math.max(m, math.abs(sig[i * nch + c] or 0))
    end
    return m
  end
  local reduced = 0
  for _, p in ipairs(CLICKS) do
    if peak_near(wet, p, 8, 2, 1) < peak_near(clicky, p, 8, 2, 1) * 0.9 then
      reduced = reduced + 1
    end
  end
  ok(reduced == #CLICKS, "every click peak is reduced",
     string.format("%d of %d", reduced, #CLICKS))

  -- Outside the repairs the signal must come through untouched. Offline there
  -- is no lookahead and no delay, so this is an exact equality at shift 0 --
  -- not a search for the best alignment.
  local worst, at = 0, 0
  for i = 0, 4000 do
    local d = math.abs((wet[i * 2 + 1] or 0) - (clicky[i * 2 + 1] or 0))
    if d > worst then worst, at = d, i end
  end
  ok(worst == 0, "bit-exact passthrough before the first click",
     string.format("%.3g at sample %d", worst, at))
end

do
  -- THE alignment test. An empty gain envelope must leave the file completely
  -- alone, and offline there is no lookahead to unwind -- so this is an exact
  -- equality at shift 0 across every sample, not a search for the best offset.
  -- A latency of even one sample shows up here immediately.
  --
  -- The envelope is emptied by detecting on the clean tone; the render then
  -- runs the clicky signal through the same bypassed filters, so the transients
  -- are present and still must come through untouched.
  analyse(k, clean, 2)
  local none = k:detect(base, 6.0)
  ok(none.events == 0, "the envelope really is empty")
  local wet = render(k, base, clicky, 2, false)
  local worst, at = 0, 0
  for i = 1, N * 2 do
    local d = math.abs((wet[i] or 0) - (clicky[i] or 0))
    if d > worst then worst, at = d, i end
  end
  ok(worst == 0, "an empty envelope passes every sample through bit-exactly",
     string.format("%.3g at %d of %d", worst, at, N * 2))
  analyse(k, clicky, 2)
end

do
  -- Channel independence, as in the plugin. A click in R only must leave L
  -- untouched -- not approximately, exactly.
  local rsig = signal(2, false, true)
  analyse(k, rsig, 2)
  local stR = k:detect(base, 6.0)
  ok(stR.events > 0, "the right-only click is detected", tostring(stR.events))
  local wet = render(k, base, rsig, 2, false)
  local worstL, worstR = 0, 0
  for i = 0, N - 1 do
    worstL = math.max(worstL, math.abs((wet[i * 2 + 1] or 0) - (rsig[i * 2 + 1] or 0)))
    worstR = math.max(worstR, math.abs((wet[i * 2 + 2] or 0) - (rsig[i * 2 + 2] or 0)))
  end
  ok(worstL == 0, "left is bit-exact when only right has a click",
     string.format("%.3g", worstL))
  ok(worstR > 0, "and right is not", string.format("%.3g", worstR))
end

do
  -- Isolate renders what is being removed, so apply == input + isolate. The
  -- fastest way to hear whether real content is going, and worth proving
  -- rather than trusting.
  analyse(k, clicky, 2)
  k:detect(base, 6.0)
  local wet = render(k, base, clicky, 2, false)
  local iso = render(k, base, clicky, 2, true)
  local worst = 0
  for i = 1, N * 2 do
    worst = math.max(worst,
      math.abs((wet[i] or 0) - ((clicky[i] or 0) + (iso[i] or 0))))
  end
  ok(worst < 1e-12, "apply == input + isolate", string.format("%.3g", worst))
end

--------------------------------------------------------------------- mono

section("mono")
do
  local k1 = make(base, 1)
  local sig = signal(1, true, false)
  analyse(k1, sig, 1)
  local s = k1:detect(base, 6.0)
  ok(s.events > 0, "a mono take detects too", tostring(s.events))
  pcall(ImGui.Detach, ctx, k1.func)
end

--------------------------------------------------------------- one phase

section("single phase (the null-test configuration)")
do
  local c1 = cfg_of({ nphases = 1 })
  local k1 = make(c1, 2)
  analyse(k1, clicky, 2)
  local s = k1:detect(c1, 6.0)
  ok(s.events > 0, "one grid phase still detects", tostring(s.events))
  local wet = render(k1, c1, clicky, 2, false)
  local worst = 0
  for i = 0, 4000 do
    worst = math.max(worst, math.abs((wet[i * 2 + 1] or 0) - (clicky[i * 2 + 1] or 0)))
  end
  ok(worst == 0, "and passes untouched audio through bit-exactly")
  pcall(ImGui.Detach, ctx, k1.func)
end

------------------------------------------------------------------- report

reaper.ShowConsoleMsg(table.concat(out, "\n") ..
  string.format("\n\n%d passed, %d failed\n", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
