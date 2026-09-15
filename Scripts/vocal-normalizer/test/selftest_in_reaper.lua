-- Vocal Normalizer -- kernel selftest. Runs inside REAPER.
--
-- Drives the EEL kernel directly on generated signals with answers that can be
-- worked out on paper, with no accessor and no project anywhere near it. That
-- is deliberately the FIRST stage of the bisect described in the README: if
-- this passes and the panel still reports nonsense, the fault is in the
-- accessor or the geometry, not the DSP.
--
-- The load-bearing assertion is the first one. BS.1770 fixes its whole scale
-- with a single statement -- a full-scale 997 Hz sine in one channel reads
-- -3.01 LKFS -- and reproducing that number end to end proves the K-weighting
-- coefficients, the channel summation, the frame accumulator and the -0.691
-- offset all at once. Everything after it is a variation on the same trick:
-- feed a sine, and compare what comes back against what biquad.lua says the
-- filter should do to it.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function report()
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
-- Anything that stops the run counts as a failure. A green exit has to mean
-- the kernel was checked, not that the script declined to look.
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

if not reaper.ImGui_GetBuiltinPath then
  say("  FAIL  ReaImGui is not installed")
  fail = 1
  report()
  return
end
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui    = require "imgui" "0.9"
local Config   = require "vn.config"
local Biquad   = require "vn.biquad"
local Kernel   = require "vn.kernel"
local Loudness = require "vn.loudness"

-- ReaImGui destroys a context that has not been used for a few seconds, and a
-- suite like this one spends real time writing a fixture and pushing audio
-- through a kernel between uses. The symptom is not subtle -- "expected a
-- valid ImGui_Context*, got 0x..." out of Attach, several sections in -- but
-- it depends on how fast the machine is, so it is a flake rather than a
-- failure. Asking for the context through here means it is checked at every
-- use and rebuilt when it has gone.
local ctx
local function alive(c)
  if not c then return false end
  -- pcall, because an optional or strict ReaImGui symbol raises rather than
  -- returning false, and a validity check that can itself throw is no check.
  local okv, v = pcall(ImGui.ValidatePtr, c, "ImGui_Context*")
  return okv and v == true
end
local function get_ctx()
  if alive(ctx) then return ctx end
  ctx = ImGui.CreateContext("Vocal Normalizer selftest")
  return ctx
end

local function conf(over)
  local c = Config.new()
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

-- Push `nblocks` blocks of generated audio through a kernel and return the
-- per-block band level, K level, peak and sample count.
--
-- `gen(t, ch)` is sampled at absolute take time, so the signal is continuous
-- across block boundaries -- which is what makes the filter-state assertions
-- below mean anything.
local function push(k, cfg, rate, nchan, gen, nblocks, reset_every)
  local blocks = {}
  for b = 0, nblocks - 1 do
    local foff = b * k.frames
    local s0 = Kernel.frame_sample(foff, k.hopf)
    local s1 = Kernel.frame_sample(foff + k.frames, k.hopf)
    local nsamp = s1 - s0
    -- A fresh, strictly sequential table each block. Both halves of that
    -- matter: a table with holes punched in it has an unreliable length, and
    -- reaper.array.copy does not read out-of-array-part keys in index order
    -- (see the note on pack() in vn/kernel.lua).
    local buf = {}
    for i = 0, nsamp - 1 do
      local t = (s0 + i) / rate
      for c = 0, nchan - 1 do buf[#buf + 1] = gen(t, c) end
    end
    k.inbuf.clear(0)
    k.inbuf.copy(buf)

    local zb, zk, n, pk = k:measure(foff, k.frames, nsamp,
                                    (b == 0) or (reset_every == true))
    local B, K, N, P = zb.table(1, k.frames), zk.table(1, k.frames),
                       n.table(1, k.frames), pk.table(1, k.frames)
    local sb, sk, sn, sp = 0, 0, 0, 0
    for i = 1, k.frames do
      sb, sk, sn = sb + B[i], sk + K[i], sn + N[i]
      if P[i] > sp then sp = P[i] end
    end
    blocks[b + 1] = {
      band = Loudness.db10(sb / sn), kw = Loudness.db10(sk / sn),
      peak = sp, n = sn, want = nsamp,
    }
  end
  return blocks
end

local function sine(hz, amp)
  return function(t) return (amp or 1) * math.sin(2 * math.pi * hz * t) end
end

------------------------------------------------------------ BS.1770 calibration

-- Wide band plus K-weighting IS ordinary LUFS, so both chains must agree and
-- both must land on the standard's own calibration point.
for _, rate in ipairs({ 48000, 44100 }) do
  local cfg = conf({ band_lo_hz = 20, band_hi_hz = 20000, band_order = 4,
                     kweight = true })
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 1, cfg, rate)
  if not k then bail(string.format("kernel at %d Hz: %s", rate, tostring(err))) end

  local b = push(k, cfg, rate, 1, sine(997, 1.0), 3)
  local last = b[#b]
  near(last.kw, -3.01, 0.06, string.format(
    "a full-scale 997 Hz sine reads -3.01 LUFS at %d Hz", rate))

  -- The two chains are not identical even here: the band still carries its
  -- 20 Hz high-pass and 20 kHz low-pass, which are not quite flat at 997 Hz.
  -- So the assertion is that the gap between them is EXACTLY the residual
  -- those two sections have at this frequency, which is a far sharper claim
  -- than "close enough" -- it pins the band chain to its own design rather
  -- than to a tolerance.
  local skirts = Biquad.response_db(Biquad.butterworth("hp", 20, rate, 4), 997, rate)
               + Biquad.response_db(Biquad.butterworth("lp", 20000, rate, 4), 997, rate)
  near(last.band - last.kw, skirts, 2e-3, string.format(
    "a wide K-weighted band is the K chain plus its own skirts at %d Hz", rate))
  near(last.peak, 1.0, 1e-4, "and its peak is full scale")

  -- The coefficients the kernel is actually filtering with are the ones Lua
  -- designed. This is a regression guard with a specific bug behind it: built
  -- through a five-at-once multiple assignment and reaper.array.copy, the last
  -- two coefficients of each array arrived TRANSPOSED, which made the RLB
  -- section an unstable pole pair and every K reading `inf`. See pack() in
  -- vn/kernel.lua.
  local gotb, gotk = k:coefficients()
  local wantb, wantk = Biquad.band(cfg, rate), Biquad.kweight(rate)
  local worst, at = 0, 0
  for i, sec in ipairs(wantb) do
    for j = 1, 5 do
      local d = math.abs(gotb[(i - 1) * 5 + j] - sec[j])
      if d > worst then worst, at = d, (i - 1) * 5 + j end
    end
  end
  for i, sec in ipairs(wantk) do
    for j = 1, 5 do
      local d = math.abs(gotk[(i - 1) * 5 + j] - sec[j])
      if d > worst then worst, at = d, -((i - 1) * 5 + j) end
    end
  end
  ok(worst == 0, string.format(
    "every coefficient reached the kernel unchanged at %d Hz", rate),
    string.format("worst %.3e at slot %d", worst, at))
  ok(last.n == last.want, "every sample offered was accumulated",
     string.format("%d of %d", last.n, last.want))
  Kernel.detach(ImGui, get_ctx(), k)
end

-- Two channels carrying the same sine sum to +3.01 dB, because BS.1770 sums
-- per-channel mean squares rather than averaging them. Getting this backwards
-- would make every stereo take read 3 dB quiet and every gain 3 dB too big.
do
  local rate = 48000
  local cfg = conf({ band_lo_hz = 20, band_hi_hz = 20000, band_order = 4,
                     kweight = true })
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 2, cfg, rate)
  if not k then bail("stereo kernel: " .. tostring(err)) end
  local b = push(k, cfg, rate, 2, sine(997, 1.0), 3)
  near(b[#b].kw, 0.0, 0.06, "the same sine on two channels reads +3.01 louder")
  Kernel.detach(ImGui, get_ctx(), k)
end

------------------------------------------------------------------ the band

-- The kernel has to implement exactly the filter biquad.lua designed, so every
-- one of these compares a measured tone against the designed response at that
-- frequency. A cascade wired up in the wrong order, a coefficient packed into
-- the wrong slot or a state pair shared between channels all show up here and
-- nowhere else.
do
  local rate = 48000
  local cfg = conf({ band_lo_hz = 100, band_hi_hz = 1000, band_order = 4,
                     kweight = false })
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 1, cfg, rate)
  if not k then bail("band kernel: " .. tostring(err)) end
  local sections = Biquad.band(cfg, rate)

  for _, hz in ipairs({ 40, 100, 316, 1000, 2000, 5000 }) do
    local b = push(k, cfg, rate, 1, sine(hz, 1.0), 4)
    -- A full-scale sine has a mean square of 0.5, so -3.0103 dB, and the
    -- reported figure carries BS.1770's -0.691 offset like every other number
    -- in this script.
    local want = Loudness.OFFSET - 3.0103 + Biquad.response_db(sections, hz, rate)
    near(b[#b].band, want, 0.5, string.format(
      "%d Hz through the band lands where the design says", hz))
  end

  -- The two facts the whole script rests on, stated as measurements rather
  -- than as filter theory: sibilance and rumble cannot move the meter.
  local sib = push(k, cfg, rate, 1, sine(6000, 1.0), 4)[4]
  ok(sib.band < -50, "a full-scale 6 kHz sibilant measures below -50 dB",
     string.format("%.2f", sib.band))
  local rum = push(k, cfg, rate, 1, sine(40, 1.0), 4)[4]
  ok(rum.band < -30, "a full-scale 40 Hz rumble measures below -30 dB",
     string.format("%.2f", rum.band))
  -- ...while the K chain, running on the same samples at the same time, is
  -- fooled by both. This is the bias, measured.
  ok(sib.kw > -4, "the K chain hears that sibilant at nearly full level",
     string.format("%.2f", sib.kw))
  ok(sib.kw - sib.band > 45, "which is the whole difference between the two")

  Kernel.detach(ImGui, get_ctx(), k)
end

------------------------------------------------------- state across Executes

-- Filter state carries from one Execute to the next; the reads tile the take
-- exactly once and there is no lookahead, so a kernel that reset per block
-- would ring its high-pass at every block boundary. A 20 Hz tone into a 100 Hz
-- high-pass is the sharpest way to see it: settled it is 30+ dB down, and each
-- restart puts the transient back.
do
  local rate = 48000
  local cfg = conf({ band_lo_hz = 100, band_hi_hz = 1000, band_order = 4 })
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 1, cfg, rate)
  if not k then bail("continuity kernel: " .. tostring(err)) end

  local carried = push(k, cfg, rate, 1, sine(20, 1.0), 4, false)
  local restart = push(k, cfg, rate, 1, sine(20, 1.0), 4, true)
  ok(carried[4].band < restart[4].band - 1.0,
     "filter state carried across Executes settles below a per-block reset",
     string.format("%.2f vs %.2f", carried[4].band, restart[4].band))
  ok(carried[4].band < carried[1].band,
     "and the fourth block is quieter than the first, as a settling filter is",
     string.format("%.2f vs %.2f", carried[4].band, carried[1].band))

  Kernel.detach(ImGui, get_ctx(), k)
end

------------------------------------------------------------ peak and framing

do
  local rate = 44100
  local cfg = conf({ block_ms = 300 })       -- a hop of 75 ms: 3307.5 samples
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 1, cfg, rate)
  if not k then bail("framing kernel: " .. tostring(err)) end

  -- A fractional hop is the case an integer sample step gets wrong. Over four
  -- blocks the frames must still tile the span exactly, with no sample counted
  -- twice and none dropped.
  ok(math.abs(k.hopf - 3307.5) < 1e-9, "a fractional hop survives to the kernel",
     tostring(k.hopf))
  local b = push(k, cfg, rate, 1, sine(300, 0.5), 4)
  local total = 0
  for _, blk in ipairs(b) do total = total + blk.n end
  local want = Kernel.frame_sample(4 * k.frames, k.hopf)
  ok(total == want, "the frames tile the span exactly",
     string.format("%d vs %d", total, want))
  near(Loudness.db_from_amp(b[4].peak), -6.02, 0.05,
       "a 0.5 amplitude sine peaks at -6.02 dBFS")

  Kernel.detach(ImGui, get_ctx(), k)
end

------------------------------------------------------------------ heap probe

do
  -- Kernel.new refuses when heap_ok comes back false, so reaching this line at
  -- all is the assertion. Asking for a deliberately large map makes it a real
  -- one rather than a formality.
  local cfg = conf({ band_order = 8, kweight = true })
  local k, err = Kernel.new(ImGui, get_ctx(), script_dir, 8, cfg, 96000)
  ok(k ~= nil, "an 8-channel order-8 K-weighted kernel allocates", tostring(err))
  if k then
    ok(k.nsect == 10, "and reports ten filter sections", tostring(k.nsect))
    Kernel.detach(ImGui, get_ctx(), k)
  end
end

report()
