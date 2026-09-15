-- The compiled EEL kernel, driven on synthetic signals with known answers.
-- Headless cannot reach the EEL, so this suite runs inside REAPER.
-- Run: python3 ~/.claude/skills/reascript-lua/assets/reascript_test.py test/selftest_in_reaper.lua

local dir  = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. (reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/?.lua;") or "") .. package.path

local pass, fail = 0, 0
local function ok(c, name, extra)
  if c then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  (" .. tostring(extra) .. ")") or "")) end
end
local function near(a, b, tol, name)
  local good = a and b and math.abs(a - b) <= tol
  ok(good, name, good and nil or string.format("%s vs %s tol %s", tostring(a), tostring(b), tostring(tol)))
end
-- anything that stops the run counts as a failure, never a skip
local function bail(msg)
  fail = fail + 1
  print("  FAIL " .. msg)
  -- The suite's own failure path: report what has run so far and stop. This
  -- body used to carry an accidental duplicate of the whole render section,
  -- which never executed on a passing run and errored against an undefined
  -- `k` the first time bail was actually called -- so the one path that has
  -- to work when something is wrong was the one path that did not.
  print(string.format("\nselftest: %d passed, %d failed", pass, fail))
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") end
local ImGui  = require "imgui" "0.9"
local Config = require "dr.config"
local Kernel = require "dr.kernel"
local Ring   = require "dr.ring"
local Spectrum = require "dr.spectrum"

local ctx = ImGui.CreateContext("DeResonate selftest")
local cfg = Config.new()
local k, err = Kernel.new(ImGui, ctx, root, 1, cfg)
if not k then bail("kernel would not build: " .. tostring(err)) end

print(string.format("  kernel: half %d, nband %d, heap %d doubles (budget %d)",
  k.half, k.nband, k.heap_used, Kernel.heap_doubles(cfg, 1)))
ok(k.heap_used <= Kernel.heap_doubles(cfg, 1), "heap fits the advertised budget",
   k.heap_used .. " vs " .. Kernel.heap_doubles(cfg, 1))
ok(k.nband > 40 and k.nband <= Kernel.MAXBAND, "band map built", k.nband)

-- band centres must be 1/12-octave apart and start at search_lo_hz
local hz = k:ring_hz()
near(hz[2] / hz[1], 2 ^ (1 / 12), 0.001, "ring bands are 1/12 octave apart")
ok(hz[1] > cfg.search_lo_hz and hz[1] < cfg.search_lo_hz * 1.1,
   "first band sits just above search_lo_hz", hz[1])

---------------------------------------------------------------- modal level
-- A full-scale sine on a bin centre must read -3.0103 dBFS in that bin.
-- This is the single-bin normalisation, coherent-gain-squared over two. It is
-- NOT the broadband Parseval constant; using that reads 4.77 dB low.
do
  k:rewind()
  local bin = 200
  local f = bin * cfg.modal_rate / cfg.fft_size
  local total = cfg.fft_size * 40
  local done = 0
  while done < total do
    local n = math.min(k.block, total - done)
    for i = 0, n - 1 do
      k.inbuf[i + 1] = math.sin(2 * math.pi * f * (done + i) / cfg.modal_rate)
    end
    k:modal(n); done = done + n
  end
  ok(k:frames() > 10, "modal frames were produced", k:frames())
  local cube = k:modal_cube()
  local peak = Spectrum.percentile(cube[bin], 0.5, k.lev0)
  near(peak, -3.0103, 0.6, "a full-scale sine reads -3.01 dBFS in its own bin")
  local off = Spectrum.percentile(cube[bin + 20], 0.5, k.lev0)
  ok(off < peak - 60, "and its neighbours 20 bins away are far below", off)
end

------------------------------------------------------------------ ring time
-- A band driven with a known exponential decay must report that decay.
do
  local function drive(rate_db_per_s)
    k:rewind()
    local sr = cfg.pitch_rate
    local fc = 500.0
    local total = sr * 20
    local done = 0
    local amp_db = 0.0
    local period = math.floor(0.5 * sr)
    while done < total do
      local n = math.min(k.block, total - done)
      for i = 0, n - 1 do
        local t = done + i
        local ph = t % period
        amp_db = -rate_db_per_s * (ph / sr)
        if amp_db < -60 then amp_db = -60 end
        k.inbuf[i + 1] = (10 ^ (amp_db / 20)) *
                         math.sin(2 * math.pi * fc * t / sr)
      end
      k:ring(n); done = done + n
    end
    local hists = k:ring_hist(cfg)
    local hzr = k:ring_hz()
    local bi = Spectrum.index_of(hzr, fc)
    return Ring.time_from_hist(hists[bi], cfg, Kernel.ring_time_of), bi, hzr[bi]
  end
  local t_fast, bi, bhz = drive(600.0)
  local t_slow = drive(120.0)
  ok(bi and math.abs(bhz - 500) < 30, "the 500 Hz band is located", bhz)
  ok(t_fast and t_slow, "ring time measurable from the kernel histogram",
     tostring(t_fast) .. " / " .. tostring(t_slow))
  if t_fast and t_slow then
    near(t_fast, 0.10, 0.05, "a 600 dB/s decay reads as ~0.10 s")
    near(t_slow, 0.50, 0.20, "a 120 dB/s decay reads as ~0.50 s")
    ok(t_slow > t_fast * 2.5, "and the slow band ranks as ringing far more",
       string.format("%.3f vs %.3f", t_slow, t_fast))
  end
end

------------------------------------------------------------------- render
local Solve = require "dr.solve"
local RATE = 48000

-- deterministic pseudo-noise, so a failure is reproducible
local function noise(n, seed)
  local t, x = {}, seed or 12345
  for i = 1, n do
    x = (1103515245 * x + 12345) % 2147483648
    t[i] = (x / 1073741824.0) - 1.0
  end
  return t
end

local function push_render(sig, cfg2, filters, t60)
  k:begin_render(cfg2, RATE, filters or {}, t60)
  local out, done = {}, 0
  while done < #sig do
    local n = math.min(k.block, #sig - done)
    for i = 1, n do k.inbuf[i] = sig[done + i] end
    k:render(n)
    local o = k.outbuf.table(1, n)
    for i = 1, n do out[done + i] = o[i] end
    done = done + n
  end
  return out
end

do
  local cfg2 = Config.new(); cfg2.dereverb_on = false
  local sig = noise(20000)
  local out = push_render(sig, cfg2, {})
  local worst = 0
  for i = 1, #sig do
    local d = math.abs(out[i] - sig[i])
    if d > worst then worst = d end
  end
  ok(worst == 0, "zero filters, dereverb off -> BIT-EXACT null at shift 0", worst)
end

do
  -- a designed cut must attenuate its own frequency by its own gain and leave
  -- an octave away alone; this is what makes solve.lua's answer trustworthy
  local cfg2 = Config.new(); cfg2.dereverb_on = false
  local f = Solve.peaking(100.0, 20.0, -12.0, RATE)
  local function rms_at(hz)
    local sig = {}
    for i = 1, 40000 do sig[i] = math.sin(2 * math.pi * hz * (i - 1) / RATE) end
    local out = push_render(sig, cfg2, { f })
    local a, b = 0, 0
    for i = 20000, 40000 do a = a + out[i] * out[i]; b = b + sig[i] * sig[i] end
    return 10 * math.log(a / b, 10)
  end
  near(rms_at(100.0), -12.0, 0.6, "a -12 dB Q=20 cut at 100 Hz attenuates 100 Hz by 12 dB")
  local off = rms_at(200.0)
  ok(math.abs(off) < 0.5, "and leaves 200 Hz within 0.5 dB", off)
end

do
  -- Latency must be EXACTLY one FFT. Off by one and the whole take slides, so
  -- assert the null lands at dfft and that +-1 sample is clearly worse.
  local cfg2 = Config.new()
  cfg2.dereverb_on = true
  cfg2.reduction = 0          -- gains forced to 1: pure analysis-resynthesis
  local lat = Config.latency(cfg2)
  ok(lat == cfg2.rfft_size, "Config.latency reports one FFT with dereverb on", lat)
  local sig = noise(30000, 999)
  local out = push_render(sig, cfg2, {}, 0.4)
  local function err_at(shift)
    local num, den = 0, 0
    for i = 1, #sig - shift - 4000 do
      if i > 4000 then
        local d = out[i + shift] - sig[i]
        num = num + d * d; den = den + sig[i] * sig[i]
      end
    end
    return 10 * math.log((num / den) + 1e-30, 10)
  end
  local e0, em, ep = err_at(lat), err_at(lat - 1), err_at(lat + 1)
  ok(e0 < -60, "at 0 dB reduction the dereverb reconstructs to better than -60 dB",
     string.format("%.1f dB", e0))
  ok(em > e0 + 20 and ep > e0 + 20,
     "and +-1 sample is far worse, so an off-by-one cannot pass",
     string.format("-1: %.1f, 0: %.1f, +1: %.1f", em, e0, ep))
end

-------------------------------------------------------- suppression toggle
do
  local sig = noise(20000, 4242)
  local f = Solve.peaking(400.0, 8.0, -9.0, RATE)
  local cfg2 = Config.new(); cfg2.dereverb_on = false

  cfg2.suppress_on = false
  local off = push_render(sig, cfg2, { f })
  local worst = 0
  for i = 1, #sig do
    local d = math.abs(off[i] - sig[i])
    if d > worst then worst = d end
  end
  ok(worst == 0, "suppression off is a BIT-EXACT pass-through even with filters given",
     worst)

  cfg2.suppress_on = true
  local on = push_render(sig, cfg2, { f })
  local diff = 0
  for i = 1, #sig do diff = diff + (on[i] - sig[i]) ^ 2 end
  ok(diff > 0, "and suppression on actually changes the signal")
end

------------------------------------------------------------------ residual
do
  local sig = noise(20000, 77)
  -- With nothing engaged the residual must be DIGITAL SILENCE. That is the
  -- alignment check: any misalignment of the dry path shows up here as a comb
  -- of the delay rather than as zero.
  local cfg2 = Config.new()
  cfg2.dereverb_on = false; cfg2.suppress_on = false; cfg2.residual = true
  local r = push_render(sig, cfg2, {})
  local worst = 0
  for i = 1, #sig do if math.abs(r[i]) > worst then worst = math.abs(r[i]) end end
  ok(worst == 0, "residual with nothing engaged is digital silence", worst)

  -- residual + processed must reconstruct the input exactly
  local f = Solve.peaking(400.0, 8.0, -9.0, RATE)
  cfg2.suppress_on = true
  cfg2.residual = false
  local kept = push_render(sig, cfg2, { f })
  cfg2.residual = true
  local removed = push_render(sig, cfg2, { f })
  local wrst = 0
  for i = 1, #sig do
    local d = math.abs((kept[i] + removed[i]) - sig[i])
    if d > wrst then wrst = d end
  end
  ok(wrst < 1e-12, "kept + residual reconstructs the input", wrst)

  local e = 0
  for i = 1, #sig do e = e + removed[i] * removed[i] end
  ok(e > 0, "and the residual is not empty when a filter is working")

  -- With the dereverb engaged the dry path is delayed by a whole FFT. If that
  -- delay is wrong the residual is the input combed with itself, which is
  -- LOUDER than the input, not quieter -- so this catches the sign of the
  -- mistake as well as its presence.
  cfg2.suppress_on = false
  cfg2.dereverb_on = true
  cfg2.reduction = 0                     -- transparent chain
  local rd = push_render(sig, cfg2, {}, 0.4)
  local num, den = 0, 0
  for i = 6000, #sig - 6000 do
    num = num + rd[i] * rd[i]; den = den + sig[i] * sig[i]
  end
  local db = 10 * math.log(num / den + 1e-30, 10)
  ok(db < -55, "residual of a transparent dereverb is far below the input",
     string.format("%.1f dB", db))
end

-- -------------------------------------------------------------------- gate
-- The gate shares the dereverb's STFT, so three things that were previously
-- impossible have to be checked: that the STFT runs for the gate ALONE, that
-- it still costs exactly one window when it does, and that the band level the
-- kernel measures is in the same dBFS the analysis reports -- get that last
-- one wrong and every suggested threshold lands somewhere else, plausibly.
local Gate = require "dr.gate"
do
  local cfg2 = Config.new()
  cfg2.dereverb_on = false          -- the gate on its own: a NEW case
  cfg2.gate_on = true
  cfg2.gate_mode = "expander"
  cfg2.gate_ratio = 1.0             -- ratio 1 is identically 0 dB of gain
  local lat = Config.latency(cfg2)
  ok(lat == cfg2.rfft_size,
     "the gate alone still costs exactly one window", lat)

  local sig = noise(30000, 31337)
  local out = push_render(sig, cfg2, {})
  local function err_at(shift)
    local num, den = 0, 0
    for i = 4001, #sig - shift - 4000 do
      local d = out[i + shift] - sig[i]
      num = num + d * d; den = den + sig[i] * sig[i]
    end
    return 10 * math.log((num / den) + 1e-30, 10)
  end
  local e0, em, ep = err_at(lat), err_at(lat - 1), err_at(lat + 1)
  ok(e0 < -60, "at ratio 1 the gate is transparent through the STFT",
     string.format("%.1f dB", e0))
  ok(em > e0 + 20 and ep > e0 + 20,
     "and its latency is exactly one FFT, +-1 clearly worse",
     string.format("-1: %.1f, 0: %.1f, +1: %.1f", em, e0, ep))
end

do
  -- Does the kernel's band level agree with the analysis cube's? Drive one
  -- steady tone, read the band dB the render measured, and read the same band
  -- out of the ring cube. Both are power sums over the band normalised by
  -- N^2/8, so they must land on the same number -- and if they ever stop
  -- doing so, every threshold dr/gate.lua suggests moves with them.
  --
  -- The two passes run at DIFFERENT RATES: the render at the take's rate, the
  -- ring pass at _PRATE, which is what the accessor decimates to. Feeding the
  -- ring pass 48 kHz samples puts the tone at 250/6 Hz and the comparison is
  -- against an empty band.
  local FTONE, AMP = 250.0, 0.5
  local sig = {}
  for i = 1, 200000 do sig[i] = AMP * math.sin(2 * math.pi * FTONE * (i - 1) / RATE) end

  local cfg2 = Config.new()
  cfg2.dereverb_on = false; cfg2.gate_on = true
  cfg2.gate_ratio = 1.0; cfg2.gate_auto = false
  for g = 1, Gate.NBANDS do cfg2["gate_thr" .. g] = -140.0 end   -- never fires
  push_render(sig, cfg2, {})
  local glev = k:read(k.addr.glev, Gate.NBANDS)
  local gb = Gate.band_of(FTONE)
  local render_db = glev[gb]

  -- the same tone through the ring pass, at the rate that pass reads
  local PRATE = Config.new().pitch_rate
  local psig = {}
  for i = 1, 60000 do psig[i] = AMP * math.sin(2 * math.pi * FTONE * (i - 1) / PRATE) end
  k:rewind()
  local done = 0
  while done < #psig do
    local n = math.min(k.block, #psig - done)
    for i = 1, n do k.inbuf[i] = psig[done + i] end
    k:ring(n); done = done + n
  end
  local lev = k:read(k.addr.rlev, k.nband * k.nlev)
  local rhz = k:ring_hz()
  -- fold the 1/12-octave bands inside this gate band, at the same percentile
  local per = {}
  for b = 1, k.nband do
    local base, h = (b - 1) * k.nlev, {}
    for i = 1, k.nlev do h[i] = lev[base + i] end
    per[b] = Gate.percentile_db(h, k.lev0, 0.5, 1)
  end
  local folded = Gate.fold(per, rhz, k.nband)
  local ana_db = folded[gb]
  ok(ana_db ~= nil, "the analysis reaches the band the tone is in", gb)
  if ana_db then
    near(render_db, ana_db, 1.5,
         "the render's band level is the same dBFS the analysis reports")
    -- And both must land on the figure a Hann-windowed sine gives when its
    -- whole main lobe is SUMMED, which is not the single-bin figure. The peak
    -- bin carries the window's 0.5 coherent gain and each neighbour 0.25, so
    -- the power sum is (0.25 + 2*0.0625)/0.25 = 1.5 times the peak bin alone:
    -- +1.76 dB. Asserting -3.01 here instead reads 1.76 dB low, which is
    -- exactly the kind of quiet normalisation error this whole check exists
    -- to catch.
    near(render_db, 20 * math.log(AMP, 10) - 3.0103 + 10 * math.log(1.5, 10), 1.0,
         "and on the main-lobe power sum a Hann window gives, not one bin")
  end
  k:rewind()
end

do
  -- The EEL's gain must be the gain dr/gate.lua computes. Drive a steady tone
  -- well UNDER a threshold, let the release settle, and compare.
  local FTONE, AMP = 250.0, 0.02
  local sig = {}
  for i = 1, 400000 do sig[i] = AMP * math.sin(2 * math.pi * FTONE * (i - 1) / RATE) end
  local cfg2 = Config.new()
  cfg2.dereverb_on = false; cfg2.gate_on = true
  cfg2.gate_mode = "expander"; cfg2.gate_ratio = 3.0
  cfg2.gate_amount = 100; cfg2.gate_auto = false; cfg2.gate_offset_db = 0
  for g = 1, Gate.NBANDS do cfg2["gate_thr" .. g] = -20.0 end
  push_render(sig, cfg2, {})
  local gb = Gate.band_of(FTONE)
  local glev = k:read(k.addr.glev, Gate.NBANDS)
  local ggain = k:read(k.addr.gg, Gate.NBANDS)
  local thr, rng = Gate.effective_band(cfg2, nil, gb)
  local want = Gate.gain_db(glev[gb], thr, 3.0, rng)
  near(ggain[gb], want, 0.05,
       "the kernel's settled band gain is the gain dr/gate.lua computes")
  ok(ggain[gb] < -1, "and it really is gating", ggain[gb])
end

do
  -- kept + residual == input, with the gate engaged
  local sig = noise(60000, 8181)
  local cfg2 = Config.new()
  cfg2.dereverb_on = false; cfg2.suppress_on = false
  cfg2.gate_on = true; cfg2.gate_mode = "gate"
  cfg2.gate_amount = 100; cfg2.gate_auto = false
  for g = 1, Gate.NBANDS do cfg2["gate_thr" .. g] = -30.0 end
  cfg2.residual = false
  local kept = push_render(sig, cfg2, {})
  cfg2.residual = true
  local removed = push_render(sig, cfg2, {})
  -- The gate runs the STFT, so the chain is one window late and the residual
  -- subtracts the dry signal delayed by exactly that. kept + residual is
  -- therefore the input AT THAT DELAY, not the input: comparing against
  -- sig[i] measures the delay rather than the reconstruction.
  local lat = Config.latency(cfg2)
  local wrst = 0
  for i = lat + 1, #sig do
    local d = math.abs((kept[i] + removed[i]) - sig[i - lat])
    if d > wrst then wrst = d end
  end
  ok(wrst < 1e-9, "kept + residual reconstructs the input with the gate on", wrst)
  local e = 0
  for i = 1, #sig do e = e + removed[i] * removed[i] end
  ok(e > 0, "and the gate really removed something")
end

-- ------------------------------------------------------------- filterbank
-- The other domain. Its defining property is not a bit-exact null -- a
-- Linkwitz-Riley tree cannot give one, it rotates phase -- but MAGNITUDE
-- FLATNESS: at unity gain the eight bands must sum to something whose level is
-- the input's at every frequency. That is the assertion that says the allpass
-- correction is right, and without it the bank sums with ripple at every
-- crossover and every band edge colours the take.
do
  local cfg2 = Config.new()
  cfg2.dereverb_on = false; cfg2.suppress_on = false
  cfg2.gate_on = true; cfg2.gate_domain = "filterbank"
  cfg2.gate_auto = false; cfg2.gate_amount = 0     -- unity gain everywhere
  for g = 1, Gate.NBANDS do cfg2["gate_thr" .. g] = -140.0 end

  ok(Config.latency(cfg2) == 0,
     "the filterbank gate reports no latency", Config.latency(cfg2))

  local worst, wf = 0, 0
  for _, f in ipairs({ 40, 70, 90, 130, 180, 300, 360, 600, 720, 1000, 1400,
                       2000, 2800, 4000, 5600, 9000, 15000 }) do
    local sig = {}
    for i = 1, 40000 do sig[i] = 0.4 * math.sin(2 * math.pi * f * (i - 1) / RATE) end
    local out = push_render(sig, cfg2, {})
    local a, b = 0, 0
    for i = 20000, 40000 do a = a + out[i] * out[i]; b = b + sig[i] * sig[i] end
    local d = math.abs(10 * math.log(a / b, 10))
    if d > worst then worst, wf = d, f end
  end
  ok(worst < 0.1,
     "and at unity gain the bank is magnitude-flat across the spectrum",
     string.format("%.3f dB at %d Hz", worst, wf))

  -- zero latency means the residual identity is EXACT again, not one window
  -- late the way the spectral path leaves it
  local sig = noise(60000, 606)
  cfg2.gate_amount = 100; cfg2.gate_mode = "gate"
  for g = 1, Gate.NBANDS do cfg2["gate_thr" .. g] = -30.0 end
  cfg2.residual = false
  local kept = push_render(sig, cfg2, {})
  cfg2.residual = true
  local removed = push_render(sig, cfg2, {})
  local wrst = 0
  for i = 1, #sig do
    local d = math.abs((kept[i] + removed[i]) - sig[i])
    if d > wrst then wrst = d end
  end
  ok(wrst < 1e-12,
     "kept + residual reconstructs the input exactly, at shift 0", wrst)
  local e = 0
  for i = 1, #sig do e = e + removed[i] * removed[i] end
  ok(e > 0, "and it removed something")
end

do
  -- The two domains must READ THE SAME LEVEL, or the thresholds the analysis
  -- suggests mean different things in each. They cannot agree on a tone -- a
  -- Hann main lobe sums to 1.5x its peak bin, so the spectral side reads
  -- 1.76 dB high there -- but on broadband content, which is what a reverb
  -- tail is, Gate.FB_OFFSET_DB is exactly the constant that lines them up.
  local sig = noise(200000, 4242)
  local function levels(domain)
    local c = Config.new()
    c.dereverb_on = false; c.suppress_on = false
    c.gate_on = true; c.gate_domain = domain
    c.gate_auto = false; c.gate_amount = 0
    for g = 1, Gate.NBANDS do c["gate_thr" .. g] = -140.0 end
    push_render(sig, c, {})
    return k:read(k.addr.glev, Gate.NBANDS)
  end
  local sp = levels("spectral")
  local fb = levels("filterbank")
  -- What must be right is the OFFSET, which is a constant: if FB_OFFSET_DB is
  -- wrong every band moves the same way, so the mean difference is the test.
  -- The per-band SCATTER is not an error -- the two banks genuinely divide
  -- broadband energy differently, LR4 being -6 dB at each crossover where the
  -- spectral bank crossfades over +-1/6 octave -- so it is bounded rather than
  -- driven to zero. Measured: mean -0.07 dB, worst 2.5 dB.
  local sum, worst, wb, n = 0, 0, 0, 0
  for g = 2, Gate.NBANDS - 1 do          -- the open-ended bands are not comparable
    local d = fb[g] - sp[g]
    sum = sum + d; n = n + 1
    if math.abs(d) > worst then worst, wb = math.abs(d), g end
  end
  local mean = sum / n
  ok(math.abs(mean) < 0.75,
     "the two domains agree ON AVERAGE, so the unit offset between them is right",
     string.format("mean %+.2f dB", mean))
  ok(worst < 3.5,
     "and no band disagrees grossly -- the rest is the two banks' band shapes",
     string.format("%.2f dB in band %d", worst, wb))
end

do
  -- gate off is still a bit-exact pass-through, the same guard suppression has
  local sig = noise(20000, 5150)
  local cfg2 = Config.new()
  cfg2.dereverb_on = false; cfg2.suppress_on = false; cfg2.gate_on = false
  cfg2.gate_amount = 100
  local out = push_render(sig, cfg2, {})
  local worst = 0
  for i = 1, #sig do
    local d = math.abs(out[i] - sig[i])
    if d > worst then worst = d end
  end
  ok(worst == 0, "gate off -> BIT-EXACT pass-through, no STFT at all", worst)
end

-- ------------------------------------------------------------------ stereo
-- Every assertion above drives a MONO kernel, and that is how a real fault
-- lived here unseen: `dframe` was advanced inside `dere_frame`, which krender
-- calls once per channel per hop, so on stereo the lookback ran at
-- _DDELAY/_NCH hops while the decay factor was still computed for the full
-- _DDELAY. The two channels are identical here, so the dereverb must treat
-- them identically -- and the lookback it actually used must be the one the
-- config asked for.
do
  local k2, e2 = Kernel.new(ImGui, ctx, root, 2, cfg)
  if not k2 then
    ok(false, "a stereo kernel builds", tostring(e2))
  else
    ok(k2.heap_used <= Kernel.heap_doubles(cfg, 2),
       "stereo heap fits the advertised budget",
       k2.heap_used .. " vs " .. Kernel.heap_doubles(cfg, 2))

    local cfg2 = Config.new()
    cfg2.dereverb_on = true; cfg2.suppress_on = false
    cfg2.reduction = 12; cfg2.strength = 100
    local mono = noise(120000, 777)

    -- the same signal in both channels, interleaved
    local st, done = {}, 0
    for i = 1, #mono do st[2 * i - 1] = mono[i]; st[2 * i] = mono[i] end
    k2:begin_render(cfg2, RATE, {}, 0.5)
    local out = {}
    while done < #mono do
      local n = math.min(k2.block, #mono - done)
      for i = 1, n * 2 do k2.inbuf[i] = st[done * 2 + i] end
      k2:render(n)
      local o = k2.outbuf.table(1, n * 2)
      for i = 1, n * 2 do out[done * 2 + i] = o[i] end
      done = done + n
    end
    local worst = 0
    for i = 1, #mono do
      local d = math.abs(out[2 * i - 1] - out[2 * i])
      if d > worst then worst = d end
    end
    ok(worst < 1e-12, "identical channels come out identical", worst)

    -- and the same signal through a MONO kernel must give the same answer:
    -- if the frame counter runs per channel, stereo sees a different lookback
    -- and this diverges.
    local mo = push_render(mono, cfg2, {}, 0.5)
    local num, den = 0, 0
    for i = 1, #mono do
      local d = out[2 * i - 1] - mo[i]
      num = num + d * d; den = den + mo[i] * mo[i]
    end
    local db = 10 * math.log(num / (den + 1e-30) + 1e-30, 10)
    ok(db < -100, "and stereo matches mono, so the lookback is per hop not per channel",
       string.format("%.1f dB", db))

    -- The gate is the reason dere_frame was split into an analyse pass and a
    -- synth pass: the band levels are POOLED across channels, so no gain can
    -- be applied until every channel has been transformed. Gating each channel
    -- from its own level would let the image wander in the pauses, and on a
    -- signal that is identical in both channels that fault is invisible -- so
    -- this checks the split did not break the mono equivalence instead.
    local cfg3 = Config.new()
    cfg3.dereverb_on = false; cfg3.suppress_on = false
    cfg3.gate_on = true; cfg3.gate_mode = "gate"
    cfg3.gate_amount = 100; cfg3.gate_auto = false
    for g = 1, Gate.NBANDS do cfg3["gate_thr" .. g] = -35.0 end
    k2:begin_render(cfg3, RATE, {}, nil)
    local gout = {}
    done = 0
    while done < #mono do
      local n = math.min(k2.block, #mono - done)
      for i = 1, n * 2 do k2.inbuf[i] = st[done * 2 + i] end
      k2:render(n)
      local o = k2.outbuf.table(1, n * 2)
      for i = 1, n * 2 do gout[done * 2 + i] = o[i] end
      done = done + n
    end
    local gw = 0
    for i = 1, #mono do
      local d = math.abs(gout[2 * i - 1] - gout[2 * i])
      if d > gw then gw = d end
    end
    ok(gw < 1e-12, "with the gate on, identical channels still come out identical", gw)

    local gmo = push_render(mono, cfg3, {}, nil)
    local gn, gd = 0, 0
    for i = 1, #mono do
      local d = gout[2 * i - 1] - gmo[i]
      gn = gn + d * d; gd = gd + gmo[i] * gmo[i]
    end
    local gdb = 10 * math.log(gn / (gd + 1e-30) + 1e-30, 10)
    ok(gdb < -100,
       "and the gated stereo render matches the gated mono one", string.format("%.1f dB", gdb))
    local moved = 0
    for i = 1, #mono do if math.abs(gmo[i] - mono[i]) > 1e-6 then moved = moved + 1 end end
    ok(moved > 0, "(the gate was actually doing something)", moved)

    pcall(ImGui.Detach, ctx, k2.func)
  end
end

print(string.format("\nselftest: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
