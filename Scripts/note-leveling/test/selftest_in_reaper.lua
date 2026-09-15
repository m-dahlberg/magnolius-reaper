-- Note Leveling -- kernel self test. Run from the Actions list.
--
-- Drives the EEL kernel directly on synthetic signals with analytically known
-- answers: no item, no accessor, no project state. Run this first if anything
-- looks wrong. test/headless checks the Lua algorithms; this is the only test
-- that can reach the EEL at all, and the seam between them -- nl/analyze.lua --
-- is covered by verify_edit_in_reaper.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Requires ReaImGui.", "Note Leveling selftest", 0)
  -- A missing dependency is a failed run too, not a quiet pass.
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;" .. script_dir .. "test/?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui  = require "imgui" "0.9"
local Kernel  = require "nl.kernel"
local Config  = require "nl.config"
local Cluster = require "nl.cluster"
local Level   = require "nl.level"
local Reference = require "nl.reference"
local Rider     = require "nl.rider"
local Ride      = require "nl.ride"
local UIFrame = require "ui_frame"

local ctx = ImGui.CreateContext("Note Leveling selftest")
local SR = 48000

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%.6g vs %.6g (tol %.3g)", a or 0 / 0, b, tol))
end
local function report()
  say(string.format("selftest: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
-- Anything that stops the run short counts as a failed run. A green exit has
-- to mean the kernel was actually exercised, not that the suite gave up.
local function bail(s) fail = fail + 1 say("  FAIL  " .. s) report() end

local function cfg_of(t)
  local c = Config.new()
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

local function make(cfg, nch)
  local k, err = Kernel.new(ImGui, ctx, script_dir, nch or 1, cfg, SR)
  if not k then bail("kernel would not build: " .. tostring(err)) end
  return k
end

-- Fill the input buffer with `nsamp` samples per channel from gen(i, ch).
local function fill(k, nsamp, nch, gen)
  k.inbuf.clear(0)
  for i = 0, nsamp - 1 do
    for c = 1, nch do k.inbuf[i * nch + c] = gen(i, c) end
  end
end

local NF = 24                       -- frames per probe; enough to ignore edges

-- Run the pitch task over a generated signal and return f0[] and aper[].
local function pitch_of(k, nch, gen)
  local nsamp = Kernel.frame_sample(NF, k.hopf_pitch) + k.need
  fill(k, nsamp, nch, gen)
  local f0, aper = k:pitch(0, NF, nsamp)
  return f0.table(1, NF), aper.table(1, NF)
end

-- Returns the broadband dB per frame and, second, the same frames through the
-- vocal band -- the two reductions task 1 emits from one pass over the samples.
local function level_of(k, nch, gen)
  local nsamp = Kernel.frame_sample(NF, k.hopf_level)
  fill(k, nsamp, nch, gen)
  local sumsq, cnt, bpsq = k:level(0, NF, nsamp, true)
  local ss, nn, bb = sumsq.table(1, NF), cnt.table(1, NF), bpsq.table(1, NF)
  local db, bdb = {}, {}
  local tss, tbb, tnn = 0, 0, 0
  for i = 1, NF do
    local n = math.max(nn[i], 1)
    db[i]  = 10 * math.log(ss[i] / n, 10)
    bdb[i] = bb[i] > 0 and 10 * math.log(bb[i] / n, 10) or -300
    tss, tbb, tnn = tss + ss[i], tbb + bb[i], tnn + n
  end
  -- Pooled over the whole block as well as per frame. A 5 ms frame is a
  -- QUARTER of a 50 Hz period, so a per-frame RMS of a low tone is really a
  -- sample of the waveform's phase and its median sits about 2 dB under the
  -- true RMS. Nothing is wrong with the kernel when that happens -- the frame
  -- is simply shorter than the thing being measured -- but an assertion about
  -- a low frequency has to pool the frames or it is asserting the phase.
  local function d(v) return v > 0 and 10 * math.log(v / tnn, 10) or -300 end
  return db, bdb, d(tss), d(tbb)
end

local function median(t)
  local c = {}
  for i = 1, #t do c[i] = t[i] end
  table.sort(c)
  return c[math.floor(#c / 2) + 1]
end

local function cents(a, b) return 1200 * math.log(a / b, 2) end

-------------------------------------------------------------------- geometry

do
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local g = Kernel.geometry(cfg)
  ok(k.taumin == g.taumin and k.taumax == g.taumax,
     "kernel and Lua agree on the tau range")
  near(k.taumax, 8000 / 75, 1, "taumax is one period of the lowest pitch")
  near(k.taumin, 8000 / 600, 1, "taumin is one period of the highest")
  ok(k.win == 2 * k.taumax, "the window is two of the longest periods")
  ok(k.need == k.win + k.taumax, "and a frame reaches win + taumax past itself")
  ok(k.heap_used > 0, "the kernel allocated a heap")
end

do
  -- The frame grid is defined in time, so it must not drift on a rate where
  -- the hop is fractional. 5 ms at 44100 is 220.5 samples.
  local hopf = 0.005 * 44100
  local f = 20000
  ok(Kernel.frame_sample(f, hopf) == 4410000,
     "frame 20000 lands where 100 seconds says it should",
     tostring(Kernel.frame_sample(f, hopf)))
  local a = Kernel.frame_sample(f + 1, hopf) - Kernel.frame_sample(f, hopf)
  local b = Kernel.frame_sample(f + 2, hopf) - Kernel.frame_sample(f + 1, hopf)
  ok(a + b == 441, "and consecutive frames alternate 220 and 221 samples",
     a .. "," .. b)
end

----------------------------------------------------------------------- pitch

for _, hz in ipairs({ 82.407, 110, 220, 440, 587.33 }) do
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local f0, aper = pitch_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * hz * i / cfg.pitch_rate)
  end)
  local got, ap = median(f0), median(aper)
  near(cents(got, hz), 0, 5,
       string.format("a %.1f Hz sine is found within 5 cents", hz))
  ok(ap < cfg.yin_threshold,
     string.format("...and reads as voiced (aper %.4f)", ap))
end

do
  -- A sawtooth: rich in harmonics, and the classic way to trip YIN into
  -- reporting an octave up.
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local hz = 147
  local f0 = pitch_of(k, 1, function(i)
    local ph = (hz * i / cfg.pitch_rate) % 1
    return 0.5 * (2 * ph - 1)
  end)
  near(cents(median(f0), hz), 0, 10, "a 147 Hz sawtooth is found, not its octave")
end

do
  -- Two channels of the same tone: the kernel mono-sums before it looks.
  local cfg = cfg_of()
  local k = make(cfg, 2)
  local f0 = pitch_of(k, 2, function(i)
    return 0.5 * math.sin(2 * math.pi * 220 * i / cfg.pitch_rate)
  end)
  near(cents(median(f0), 220), 0, 5, "a stereo tone is found on the mono sum")
end

do
  -- Vibrato: 440 Hz, +-50 cents at 6 Hz. Phase has to be integrated, or the
  -- signal is frequency-swept in a way no detector should agree with.
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local rate = cfg.pitch_rate
  local phase, inst = 0, {}
  local f0 = pitch_of(k, 1, function(i)
    local hz = 440 * 2 ^ (0.5 * math.sin(2 * math.pi * 6 * i / rate) / 12)
    inst[i] = hz
    local s = 0.5 * math.sin(phase)
    phase = phase + 2 * math.pi * hz / rate
    return s
  end)
  local worst = 0
  for f = 1, NF do
    local centre = Kernel.frame_sample(f - 1, k.hopf_pitch) + math.floor(k.win / 2)
    local want = inst[centre] or 440
    worst = math.max(worst, math.abs(cents(f0[f], want)))
  end
  ok(worst < 25, "vibrato tracks within 25 cents of the instantaneous pitch",
     string.format("%.1f cents", worst))
end

do
  local cfg = cfg_of()
  local k = make(cfg, 1)
  math.randomseed(20260825)
  local _, aper = pitch_of(k, 1, function() return math.random() * 2 - 1 end)
  local voiced = 0
  for i = 1, NF do if aper[i] < cfg.yin_threshold then voiced = voiced + 1 end end
  ok(voiced == 0, "white noise reads as unvoiced in every frame",
     voiced .. " of " .. NF .. " frames, median aper " ..
     string.format("%.3f", median(aper)))
end

do
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local _, aper = pitch_of(k, 1, function() return 0 end)
  ok(median(aper) >= 0.99, "digital silence reads as maximally aperiodic",
     string.format("%.3f", median(aper)))
end

do
  -- The threshold is a parameter, not part of the memory map: moving it must
  -- change the decision without rebuilding anything. It also selects which of
  -- the two candidate-picking paths runs, and those have a strict ordering: a
  -- threshold nothing crosses falls back to the GLOBAL minimum of the CMNDF,
  -- which can never be above the first-dip candidate a loose threshold takes.
  -- Same seed both times, so the noise is identical and the comparison means
  -- something.
  local cfg = cfg_of({ yin_threshold = 0.001 })
  local k = make(cfg, 1)
  local function noisy()
    math.randomseed(20260825)
    return pitch_of(k, 1, function(i)
      return 0.5 * math.sin(2 * math.pi * 220 * i / cfg.pitch_rate)
        + 0.3 * (math.random() * 2 - 1)
    end)
  end

  local f_strict, a_strict = noisy()
  k:set_yin_threshold(0.5)
  local f_loose, a_loose = noisy()

  near(cents(median(f_strict), 220), 0, 15, "a noisy tone is found either way")
  near(cents(median(f_loose), 220), 0, 15, "...at both thresholds")

  local worst, wi = 0, 0
  for i = 1, NF do
    local d = a_strict[i] - a_loose[i]
    if d > worst then worst, wi = d, i end
  end
  ok(worst <= 1e-9,
     "the fallback path never reports more aperiodicity than the first dip",
     string.format("frame %d: %.6f vs %.6f", wi, a_strict[wi] or 0,
                   a_loose[wi] or 0))
  local differs = false
  for i = 1, NF do
    if math.abs(a_strict[i] - a_loose[i]) > 1e-12 then differs = true end
  end
  ok(differs, "and the threshold reached the kernel without a rebuild")
end

----------------------------------------------------------------------- level

do
  local cfg = cfg_of()
  local k = make(cfg, 1)
  -- A full-scale sine is 3.01 dB under full scale in RMS terms.
  local db = level_of(k, 1, function(i)
    return math.sin(2 * math.pi * 1000 * i / SR)
  end)
  near(median(db), -3.0103, 0.05, "a full-scale sine measures -3.01 dB RMS")

  db = level_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * 1000 * i / SR)
  end)
  near(median(db), -9.0309, 0.05, "a -6 dBFS sine measures -9.03 dB RMS")

  db = level_of(k, 1, function() return 0 end)
  ok(db[NF // 2] < -200, "digital silence measures at the floor",
     tostring(db[NF // 2]))
end

do
  -- DC must not reach the level accumulator: a leveling decision made on a
  -- signal with an offset would measure the offset as well as the note.
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local db = level_of(k, 1, function(i)
    return 0.5 + 0.5 * math.sin(2 * math.pi * 1000 * i / SR)
  end)
  near(median(db), -9.0309, 0.2, "a 0.5 DC offset is removed before measuring")
end

do
  local cfg = cfg_of()
  local k = make(cfg, 2)
  -- Equal channels: the mono sum is the same signal, not twice it.
  local db = level_of(k, 2, function(i)
    return 0.5 * math.sin(2 * math.pi * 1000 * i / SR)
  end)
  near(median(db), -9.0309, 0.05, "a stereo tone measures its own level")
end

do
  -- Every frame must be measured over the same number of samples, give or
  -- take the one the fractional hop moves around.
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local nsamp = Kernel.frame_sample(NF, k.hopf_level)
  fill(k, nsamp, 1, function() return 0.25 end)
  local _, cnt = k:level(0, NF, nsamp, true)
  local nn, total = cnt.table(1, NF), 0
  local lo, hi = math.huge, 0
  for i = 1, NF do
    total = total + nn[i]
    lo, hi = math.min(lo, nn[i]), math.max(hi, nn[i])
  end
  ok(total == nsamp, "the frames tile the block exactly", total .. " of " .. nsamp)
  ok(hi - lo <= 1, "and no frame is more than one sample off", lo .. ".." .. hi)
end


------------------------------------------------------------------ vocal band

-- The rider measures both the vocal and the arrangement through this band, so
-- what it does to a tone is the one thing that decides whether the ride tracks
-- masking or tracks kick drums. headless.lua checks the coefficients against
-- the transfer function; this checks that the coefficients reached the kernel
-- and that the filter actually runs.
do
  local cfg = cfg_of()
  local k = make(cfg, 1)

  -- The band must be transparent where the voice lives. The tone is well
  -- inside it, so broadband and band-passed must agree.
  local db, bdb = level_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * 1000 * i / SR)
  end)
  near(median(bdb), -9.0309, 0.3, "the vocal band passes 1 kHz at its own level")
  near(median(bdb), median(db), 0.3,
       "so the two reductions agree inside the band")

  -- And it must reject what the voice does not compete with. A 50 Hz tone is
  -- most of what a broadband reading of an arrangement measures and almost
  -- none of what masks a vocal, which is the entire reason this exists.
  --
  -- The broadband figure is not quite -9.03: the level pass runs a 20 Hz DC
  -- blocker ahead of its accumulator, which still takes a fraction of a dB off
  -- 50 Hz. Predicted from its own transfer function rather than allowed for
  -- with a loose tolerance, so the assertion stays exact --
  -- H(z) = (1 - z^-1) / (1 - R z^-1).
  local function dcblock_db(f)
    local R = math.exp(-2 * math.pi * 20 / SR)
    local w = 2 * math.pi * f / SR
    local c, sn = math.cos(-w), math.sin(-w)
    local nr, ni = 1 - c, -sn
    local dr, di = 1 - R * c, -R * sn
    return 10 * math.log((nr * nr + ni * ni) / (dr * dr + di * di), 10)
  end

  local _, _, p50, pb50 = level_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * 50 * i / SR)
  end)
  near(p50, -9.0309 + dcblock_db(50), 0.3,
       "a 50 Hz tone reads broadband at its level, less the DC blocker")
  ok(pb50 < p50 - 25,
     "and is rejected by more than 25 dB in the vocal band",
     string.format("%.1f vs %.1f dB", pb50, p50))

  local _, _, _, pb15k = level_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * 15000 * i / SR)
  end)
  ok(pb15k < -30, "and 15 kHz is rejected too", string.format("%.1f dB", pb15k))

  -- The decisive case for the whole design. Two beds of the same amplitude,
  -- one at 50 Hz and one at 1.5 kHz, are within a couple of dB of each other
  -- broadband -- so a broadband rider would treat them as the same
  -- arrangement -- and more than 25 dB apart through the vocal band, which is
  -- the difference between a bed that masks a vocal and one that does not.
  local _, _, kick, kb = level_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * 50 * i / SR)
  end)
  local _, _, gtr, gb = level_of(k, 1, function(i)
    return 0.5 * math.sin(2 * math.pi * 1500 * i / SR)
  end)
  local broad = math.abs(gtr - kick)
  local inband = gb - kb
  ok(broad < 2.5, "two beds of equal amplitude read alike broadband",
     string.format("%.1f dB apart", broad))
  ok(inband > 25,
     "and the one that actually masks a vocal reads far louder in the band",
     string.format("%.1f dB apart", inband))
  ok(inband > broad * 8,
     "so the band is what separates them, not the level")
end

do
  -- The filter state has to survive a block boundary and reset on _RESET, the
  -- same contract the DC blocker has. Measured on the second block of a
  -- continuous tone: if the state were dropped the filter would ring at the
  -- seam and the frame would read wrong.
  local cfg = cfg_of()
  local k = make(cfg, 1)
  local nsamp = Kernel.frame_sample(NF, k.hopf_level)
  local function tone(i) return 0.5 * math.sin(2 * math.pi * 1000 * i / SR) end

  fill(k, nsamp, 1, tone)
  k:level(0, NF, nsamp, true)                    -- first block, resets
  fill(k, nsamp, 1, function(i) return tone(i + nsamp) end)
  local _, cnt, bpsq = k:level(NF, NF, nsamp, false)
  local bb, nn = bpsq.table(1, NF), cnt.table(1, NF)
  local v = 10 * math.log(bb[2] / math.max(nn[2], 1), 10)
  near(v, -9.0309, 0.3, "the band-pass state carries across a block boundary")
end

----------------------------------------------------------------------- panel

do
  local UI = require "nl.ui"

  local _, err, log = UIFrame.run(UI, script_dir)
  ok(err == nil, "the panel renders a frame with nothing analysed",
     tostring(err))
  ok(log.dis == 0, "and leaves BeginDisabled balanced", tostring(log.dis))
  ok(log.push == log.pop, "and its style stack balanced",
     log.push .. " vs " .. log.pop)

  -- Again with results in hand, so the plots and every readout run.
  local F = { hop_s = 0.005, n = 0, item_pos = 0,
              ms = {}, level_db = {}, bp_ms = {}, bp_db = {},
              f0 = {}, aper = {} }
  local function seg(hz, n, dbv)
    for _ = 1, n do
      local i = F.n + 1
      F.n = i
      F.ms[i] = 10 ^ (dbv / 10)
      F.level_db[i] = dbv
      F.bp_ms[i] = F.ms[i]
      F.bp_db[i] = dbv
      F.f0[i] = hz or 0
      F.aper[i] = hz and 0.05 or 0.9
    end
  end
  seg(220, 120, -6) seg(nil, 60, -80) seg(261.626, 120, -40)
  seg(nil, 60, -80) seg(329.628, 120, -15)
  F.span = F.n * F.hop_s

  -- One analysis feeds both tabs, so the fixture is one `data` blob shaped
  -- like the read job's output and the panel derives the rest itself.
  local cfg0 = Config.new()
  local refs0 = { { n = F.n, hop_s = F.hop_s, item_pos = 0, bp_ms = {} } }
  for i = 1, F.n do refs0[1].bp_ms[i] = 10 ^ (-20 / 10) end
  local data0 = {
    targets = { { F = F, R = Reference.mix(refs0, F),
                  geo = { item_pos = 0, item_len = F.span, nchan = 1,
                          rate = 48000, playrate = 1 } } },
    refs = refs0,
  }

  local function populate(st)
    st.data = data0
    st.nd = Ride.notes_only(data0, cfg0)
    st.rd = Ride.derive(data0, cfg0)
    local d = st.nd[1]
    st.F, st.notes, st.points = d.F, d.notes, d.points
    st.geo, st.item, st.take = d.geo, d.item, d.take
    st.clip_idx, st.derived_sig = 1, nil
    st.status = "test"
  end

  local _, err2, log2 = UIFrame.run(UI, script_dir, populate)
  ok(err2 == nil, "the panel renders a frame with notes and an envelope",
     tostring(err2))
  ok(log2.dis == 0, "and still leaves BeginDisabled balanced", tostring(log2.dis))

  -- The rider tab, empty and populated. It has its own control column and its
  -- own three plots, and neither runs while the Notes tab is showing -- so
  -- without these two the whole of part 2's panel is untested and a renamed
  -- config key there would first be seen by a user.
  local _, err3, log3 = UIFrame.run(UI, script_dir, function(st)
    st.tab = "rider"
  end)
  ok(err3 == nil, "the rider tab renders with nothing analysed", tostring(err3))
  ok(log3.dis == 0, "and leaves BeginDisabled balanced", tostring(log3.dis))

  local _, err4, log4 = UIFrame.run(UI, script_dir, function(st)
    populate(st) st.tab = "rider"
  end)
  ok(err4 == nil, "the rider tab renders a full ride", tostring(err4))
  ok(log4.dis == 0, "and still leaves BeginDisabled balanced", tostring(log4.dis))

  -- Once more with every control reporting that it was just moved, so the code
  -- BEHIND each slider runs. A stub whose controls always answer false draws
  -- the panel and executes none of it.
  local _, err5, log5 = UIFrame.run(UI, script_dir, function(st)
    populate(st) st.tab = "rider"
  end, {}, true)
  ok(err5 == nil, "the rider tab survives every control being moved",
     tostring(err5))
  ok(log5.dis == 0, "and still leaves BeginDisabled balanced", tostring(log5.dis))

  local _, err6, log6 = UIFrame.run(UI, script_dir, populate, {}, true)
  ok(err6 == nil, "and so does the notes tab", tostring(err6))
  ok(log6.dis == 0, "with its stack balanced too", tostring(log6.dis))

  -- Glide mode is a different Envelope section: two sliders inside a disabled
  -- scope, five lines of help, and the note-to-note transition note gone. The
  -- disabled scope is the reason this is asserted rather than assumed -- an
  -- unbalanced BeginDisabled takes the whole defer loop down at the next End,
  -- and _init loads from ExtState, so which of the two arrangements the frames
  -- above drew depends on what the user last saved.
  local glide = function(st, c) populate(st) c.glide_notes = true end
  local _, err8, log8 = UIFrame.run(UI, script_dir, glide)
  ok(err8 == nil, "the notes tab renders with glide between notes on",
     tostring(err8))
  ok(log8.dis == 0, "and leaves BeginDisabled balanced", tostring(log8.dis))

  local _, err9, log9 = UIFrame.run(UI, script_dir, glide, {}, true)
  ok(err9 == nil, "and survives every control being moved under it",
     tostring(err9))
  ok(log9.dis == 0, "with its stack balanced too", tostring(log9.dis))

  -- Several target clips: the arrow pair in the top bar appears, and moving it
  -- has to leave BOTH tabs on the same clip. A per-tab index would let the
  -- Notes plots describe clip 1 while the rider readout described clip 2.
  local many = { targets = { data0.targets[1], data0.targets[1],
                             data0.targets[1] }, refs = refs0 }
  for _, tab in ipairs({ "notes", "rider" }) do
    local _, err7, log7 = UIFrame.run(UI, script_dir, function(st)
      populate(st)
      st.data = many
      st.nd = Ride.notes_only(many, cfg0)
      st.rd = Ride.derive(many, cfg0)
      st.clip_idx = 2
      st.tab = tab
    end, { ["<##clip"] = true, [">##clip"] = true }, false)
    ok(err7 == nil, "the " .. tab .. " tab renders with three clips and the " ..
       "clip arrows pressed", tostring(err7))
    ok(log7.dis == 0, "and still leaves BeginDisabled balanced", tostring(log7.dis))
  end
end

report()
