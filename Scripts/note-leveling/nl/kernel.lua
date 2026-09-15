-- @noindex
-- Note Leveling -- the EEL kernel wrapper.
--
-- Owns the compiled kernel, the memory map shared with it, and the two passes
-- it exposes. Nothing above this file knows an address.
--
-- Layout: Lua owns the bottom of the heap (the interleaved input buffer and
-- the four per-frame output arrays, whose addresses the Function_*_Array calls
-- write through) and the kernel allocates its own scratch above _HEAP.

local M = {}

local K = {}
K.__index = K

-- Frames handed over per Execute. An Execute is atomic, so the block size *is*
-- the worst-case UI hitch. The two passes differ by an order of magnitude in
-- cost per frame -- the level pass is a handful of adds, YIN is win * taumax
-- multiply-accumulates -- so they get different budgets.
M.LEVEL_FRAMES = 256
M.PITCH_FRAMES = 128
local OUT_FRAMES = math.max(M.LEVEL_FRAMES, M.PITCH_FRAMES)

local DC_HZ = 20

-- The vocal band, and why it is a constant rather than a slider ---------------
--
-- Both the rider's reference measurement and its target measurement run
-- through this band. It is fixed because it belongs to the *question* being
-- asked -- "how hard is the arrangement masking the voice" -- rather than to
-- taste, and because it is an ANALYSIS parameter: making it a slider would put
-- a control in the panel that silently invalidates the pitch pass and demands
-- another Analyse, which is a bad trade for a number that has one sensible
-- value. 300 Hz is below the lowest vocal formant and above most of the kick
-- and bass; 4 kHz is above the sibilance that carries intelligibility.
M.BAND_LO_HZ = 300
M.BAND_HI_HZ = 4000

-- RBJ cookbook biquads, computed here rather than in EEL: EEL has the trig,
-- but doing it in Lua means the coefficients can be asserted headlessly, and
-- the kernel never has to know the source rate for anything else.
--
-- Both are Butterworth (Q = 1/sqrt(2)), 12 dB/octave. A single band-pass
-- biquad would have to span more than three octaves, which makes Q < 0.25 --
-- a broad hump rather than a band, with the skirts still passing most of the
-- bass it is there to reject.
local function rbj(kind, f0, rate)
  -- Above Nyquist there is no filter to design. A high-pass that has run off
  -- the end of the band should pass nothing and a low-pass everything, which
  -- is what these degenerate coefficient sets do.
  local ny = rate * 0.5
  if f0 >= ny then
    return kind == "hp" and { 0, 0, 0, 0, 0 } or { 1, 0, 0, 0, 0 }
  end
  if f0 <= 0 then
    return kind == "hp" and { 1, 0, 0, 0, 0 } or { 1, 0, 0, 0, 0 }
  end
  local w  = 2 * math.pi * f0 / rate
  local cw, sw = math.cos(w), math.sin(w)
  local alpha = sw / (2 * (1 / math.sqrt(2)))
  local a0, b0, b1, b2
  if kind == "hp" then
    b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
  else
    b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
  end
  a0 = 1 + alpha
  local a1, a2 = -2 * cw, 1 - alpha
  return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 }
end

M.rbj = rbj

-- The tau range and window, derived the same way the kernel derives them. Lua
-- needs them before setup to size the input buffer, and reads the kernel's own
-- values back afterwards to prove the two agree.
function M.geometry(cfg)
  local rate = cfg.pitch_rate
  local taumin = math.floor(rate / math.max(cfg.max_hz, 1))
  if taumin < 2 then taumin = 2 end
  local taumax = math.ceil(rate / math.max(cfg.min_hz, 1))
  if taumax < taumin + 2 then taumax = taumin + 2 end
  local win = 2 * taumax
  return { taumin = taumin, taumax = taumax, win = win, need = win + taumax }
end

local function compile(ImGui, ctx, script_dir)
  local path = script_dir .. "nl/dsp/pitch.eel"
  local fh = io.open(path, "rb")
  if not fh then return nil, "Cannot open " .. path end
  local code = fh:read("a")
  fh:close()
  local ok, func = pcall(ImGui.CreateFunctionFromEEL, code)
  if not ok or not func then
    return nil, "EEL compile failed: " .. tostring(func)
  end
  -- Attach, or it is garbage collected out from under us.
  ImGui.Attach(ctx, func)
  return func
end

-- Channel count and the tau range are baked into the memory map, so a change
-- in either means a new kernel rather than a reconfigure. The YIN threshold is
-- not: it only picks a winner out of an already-computed curve, so it rides
-- along as an ordinary parameter and can be moved without rebuilding anything.
function M.new(ImGui, ctx, script_dir, nchan, cfg, src_rate)
  local func, err = compile(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local g = M.geometry(cfg)
  local hop_s = cfg.hop_ms / 1000

  -- Frames are placed on a grid defined in TIME, not in samples: frame f
  -- starts at exactly f * hop_s seconds in both passes. An integer sample hop
  -- would be wrong at 44100 (5 ms is 220.5 samples), and rounding it down
  -- drifts half a sample per frame -- 0.4 s over a three minute take, which
  -- would slide every note against the audio it was measured from. So the
  -- fractional hop goes to the kernel and each frame rounds its own start.
  local k = setmetatable({
    ImGui = ImGui, func = func, nchan = nchan,
    src_rate = src_rate, pitch_rate = cfg.pitch_rate,
    hop_s = hop_s,
    hopf_level = hop_s * src_rate,
    hopf_pitch = hop_s * cfg.pitch_rate,
    taumin = g.taumin, taumax = g.taumax, win = g.win, need = g.need,
    level_frames = M.LEVEL_FRAMES, pitch_frames = M.PITCH_FRAMES,
  }, K)

  k.maxsamp = math.max(
    math.ceil(M.LEVEL_FRAMES * k.hopf_level) + 2,
    math.ceil(M.PITCH_FRAMES * k.hopf_pitch) + g.need + 2)

  local iolen = k.maxsamp * nchan
  k.inbuf = reaper.new_array(iolen)

  k.out = {}
  local addr, names = iolen, { "SUMSQ", "BPSQ", "N", "F0", "APER" }
  for _, name in ipairs(names) do
    k.out[name] = reaper.new_array(OUT_FRAMES)
    k.out[name .. "_addr"] = addr
    ImGui.Function_SetValue(func, "_OUT_" .. name, addr)
    addr = addr + OUT_FRAMES
  end
  k.names = names

  ImGui.Function_SetValue(func, "_IN", 0)
  ImGui.Function_SetValue(func, "_HEAP", addr)
  ImGui.Function_SetValue(func, "_NCHAN", nchan)
  ImGui.Function_SetValue(func, "_RATE", cfg.pitch_rate)
  ImGui.Function_SetValue(func, "_MINHZ", cfg.min_hz)
  ImGui.Function_SetValue(func, "_MAXHZ", cfg.max_hz)
  ImGui.Function_SetValue(func, "_MAXSAMP", k.maxsamp)
  ImGui.Function_SetValue(func, "_YINTHRESH", cfg.yin_threshold)
  ImGui.Function_SetValue(func, "_RDC", math.exp(-2 * math.pi * DC_HZ / src_rate))
  local NAMED = { "B0", "B1", "B2", "A1", "A2" }
  for prefix, kind in pairs({ HP = "hp", LP = "lp" }) do
    local hz = (kind == "hp") and M.BAND_LO_HZ or M.BAND_HI_HZ
    local co = rbj(kind, hz, src_rate)
    for i, suffix in ipairs(NAMED) do
      ImGui.Function_SetValue(func, "_" .. prefix .. "_" .. suffix, co[i])
    end
  end
  ImGui.Function_SetValue(func, "_RESET", 0)

  k:exec(0)                            -- allocate and clear

  -- The kernel derived tau and the window itself. If its numbers disagree with
  -- the ones the input buffer was sized from, every read after this would be
  -- the wrong length, so say so here rather than produce quiet nonsense.
  local ktaumin = ImGui.Function_GetValue(func, "taumin")
  local ktaumax = ImGui.Function_GetValue(func, "taumax")
  local kneed   = ImGui.Function_GetValue(func, "need")
  if ktaumin ~= g.taumin or ktaumax ~= g.taumax or kneed ~= g.need then
    return nil, string.format(
      "Kernel geometry disagrees with Lua: tau %d..%d need %d vs %d..%d need %d",
      ktaumin, ktaumax, kneed, g.taumin, g.taumax, g.need)
  end

  k.heap_used = ImGui.Function_GetValue(func, "memtop")
  if ImGui.Function_GetValue(func, "heap_ok") ~= 1 then
    return nil, string.format(
      "The EEL kernel could not allocate its %.1f MB of heap for %d channels.",
      k.heap_used * 8 / 1048576, nchan)
  end
  return k
end

function K:exec(task)
  self.ImGui.Function_SetValue(self.func, "_TASK", task)
  self.ImGui.Function_Execute(self.func)
end

function K:set_yin_threshold(v)
  self.ImGui.Function_SetValue(self.func, "_YINTHRESH", v)
end

-- Sample span frame f0 (inclusive) to f1 (exclusive) occupies at `hopf`
-- samples per frame. Both passes and the driver round identically, which is
-- what keeps the two grids on the same instants.
function M.frame_sample(f, hopf) return math.floor(f * hopf + 0.5) end

local function run(self, task, foff, nframes, nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  IG.Function_SetValue(f, "_NFRAMES", nframes)
  IG.Function_SetValue(f, "_FOFF", foff)
  IG.Function_SetValue(f, "_SOFF", M.frame_sample(foff,
    task == 1 and self.hopf_level or self.hopf_pitch))
  IG.Function_SetValue(f, "_HOPF",
    task == 1 and self.hopf_level or self.hopf_pitch)
  self:exec(task)
end

-- Both return the reaper arrays; the caller pulls Lua tables out of them.
function K:level(foff, nframes, nsamp, first)
  self.ImGui.Function_SetValue(self.func, "_RESET", first and 1 or 0)
  run(self, 1, foff, nframes, nsamp)
  local IG, f = self.ImGui, self.func
  for _, name in ipairs({ "SUMSQ", "BPSQ", "N" }) do
    IG.Function_SetValue(f, "_OUT_" .. name, self.out[name .. "_addr"])
    IG.Function_GetValue_Array(f, "_OUT_" .. name, self.out[name])
  end
  return self.out.SUMSQ, self.out.N, self.out.BPSQ
end

function K:pitch(foff, nframes, nsamp)
  run(self, 2, foff, nframes, nsamp)
  local IG, f = self.ImGui, self.func
  for _, name in ipairs({ "F0", "APER" }) do
    IG.Function_SetValue(f, "_OUT_" .. name, self.out[name .. "_addr"])
    IG.Function_GetValue_Array(f, "_OUT_" .. name, self.out[name])
  end
  return self.out.F0, self.out.APER
end

return M
