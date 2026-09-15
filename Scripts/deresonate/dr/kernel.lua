-- @noindex
-- The spectral kernel: compiles `dsp/deresonate.eel` and owns its memory map.
--
-- This is the only file in the script that knows an address. Lua takes the
-- bottom of the heap for the interleaved input buffer; the kernel bump-
-- allocates its own state above `_HEAP` and reports the addresses back, which
-- are then read through the `_RD` scratch variable.
--
-- Kernel identity is (nchan, fft_size, ring_fft, modal_rate, pitch_rate):
-- those are baked into the memory map, so changing any of them means a NEW
-- kernel, not a reconfigure. Everything else rides as a parameter.

local Spectrum = require "dr.spectrum"
local Gate     = require "dr.gate"

local M = {}

-- An Execute is atomic, so this block size IS the worst-case UI hitch.
M.BLOCK = 8192

M.NLEV      = 160
M.LEV0      = -140
M.NRING     = 80
M.NLEVCLASS = 20
M.LEVCLASS_DB = 8
M.RING_LO   = 0.02
M.RING_HI   = 5.0
M.MAXBAND   = 128
M.MAXW      = 64
M.HALFMAX   = 2049
M.MAXBQ     = 16
M.MAXCH     = 2
M.DMAX      = 40
M.DRYLEN    = 8192

-- Ring-time value at the centre of bucket i (0-based), the inverse of the
-- kernel's logarithmic binning. Kept here beside the constants it depends on.
function M.ring_time_of(i)
  local r = (i + 0.5) / M.NRING
  return M.RING_LO * (M.RING_HI / M.RING_LO) ^ r
end

-- Lower edge in dB of coarse start-level class c (0-based).
function M.levclass_db(c) return M.LEV0 + c * M.LEVCLASS_DB end

function M.heap_doubles(cfg, nchan)
  local io_n = 2 * M.BLOCK * nchan          -- interleaved in and out
  local k = 4096 + 2048 + 2048            -- brev, twr, twi
          + 4096 + 4096                   -- two windows
          + 4096 * 2                      -- transform scratch
          + 4096 + 4096                   -- two input rings
          + M.HALFMAX * M.NLEV            -- modal cube
          + M.HALFMAX                     -- bin -> band map
          + M.MAXBAND                     -- band centres
          + M.MAXBAND * M.NLEV            -- ring level histograms
          + M.MAXBAND * M.NLEVCLASS * M.NRING
          + M.MAXBAND * M.MAXW
          + M.MAXBAND
          + M.MAXBAND * M.NRING           -- decay cube: T60 per band, binned
          + M.MAXBAND * 7                 -- its per-band fit state
          + M.MAXBQ * 5 + M.MAXBQ * M.MAXCH * 2   -- render cascade
          + 4096                                   -- dereverb window
          + M.MAXCH * 4096 * 2                     -- ring + overlap-add
          + M.MAXCH * M.DMAX * M.HALFMAX           -- past magnitudes
          + M.HALFMAX * 2                          -- per-bin T60 and gain
          + M.MAXCH * M.DRYLEN                     -- latency-aligned dry path
          + M.MAXBAND * M.NLEV                     -- the pause-level cube
          + M.MAXCH * 4096 * 2                     -- per-channel spectrum, so
                                                   -- the gate can pool bands
                                                   -- across channels
          + M.HALFMAX * 2                          -- bin -> gate band, and the
                                                   -- crossfade weight
          + Gate.NBANDS * 8                        -- thr range rel acc g hold
                                                   -- lin, and the band level
          + 7 * 4 * 5 + 7 * 5                      -- filterbank coefficients
          + 7 * 4 * M.MAXCH * 2                    -- its biquad state
          + 7 * Gate.NBANDS * M.MAXCH * 2          -- and its allpass state
          + Gate.NBANDS * (M.MAXCH + 7)            -- bands, env, coeffs, gains
          + 2 * M.MAXCH                            -- one sample, every channel
  return io_n + k + 16
end

local K = {}
K.__index = K

function M.new(ImGui, ctx, script_dir, nchan, cfg)
  local path = script_dir .. "dr/dsp/deresonate.eel"
  local fh = io.open(path, "r")
  if not fh then return nil, "cannot open " .. path end
  local code = fh:read("*a"); fh:close()

  local ok, func = pcall(ImGui.CreateFunctionFromEEL, code)
  if not ok or not func then
    return nil, "EEL would not compile: " .. tostring(func)
  end
  -- or it is garbage collected out from under us, usually as a crash mid-run
  ImGui.Attach(ctx, func)

  local self = setmetatable({
    IG = ImGui, func = func, nchan = nchan,
    block = M.BLOCK,
    inbuf  = reaper.new_array(M.BLOCK * nchan),
    outbuf = reaper.new_array(M.BLOCK * nchan),
    fft_size = cfg.fft_size, ring_fft = cfg.ring_fft,
    modal_rate = cfg.modal_rate, pitch_rate = cfg.pitch_rate,
  }, K)

  local set = function(n, v) ImGui.Function_SetValue(func, n, v) end
  set("_IN", 0)
  set("_OUT", M.BLOCK * nchan)
  set("_HEAP", 2 * M.BLOCK * nchan)
  set("_SRATE", cfg.modal_rate)
  set("_NBQ", 0)
  set("_DEREV", 0)
  set("_GATE", 0)
  set("_GATEFB", 0)
  set("_GMODE", 0)
  set("_GRATIO", 1)
  set("_FBOFF", Gate.FB_OFFSET_DB)
  set("_RESID", 0)
  set("_DFFT", cfg.rfft_size)
  set("_DDELAY", cfg.delay_frames)
  set("_REDUCTION", cfg.reduction)
  set("_STRENGTH", cfg.strength)
  set("_NCH", nchan)
  set("_FFT", cfg.fft_size)
  set("_RFFT", cfg.ring_fft)
  set("_MRATE", cfg.modal_rate)
  set("_PRATE", cfg.pitch_rate)
  set("_ANAHOP", cfg.ana_hop)
  set("_RHOP", cfg.ring_hop)
  set("_RLO", cfg.search_lo_hz)
  set("_RHI", cfg.search_hi_hz)
  set("_EDCGATE", cfg.edc_gate_db)
  self:set_ring_window(cfg)
  set("_TASK", 0)
  ImGui.Function_Execute(func)

  local g = function(n) return ImGui.Function_GetValue(func, n) end
  self.half   = g("half")
  self.nband  = g("nband")
  self.nlev   = g("nlev")
  self.lev0   = g("lev0")
  self.nring  = g("nring")
  self.nlevclass = g("nlevclass")
  self.memtop = g("memtop")
  self.addr = {
    mcube  = g("mcube"),  rlev   = g("rlev"),
    plev   = g("plev"),
    gbandi = g("gbandi"), gmix   = g("gmix"),
    gthr   = g("gthr"),   grange = g("grange"), grel = g("grel"),
    -- read back by the selftest, to check the EEL's band level and gain
    -- against the Lua law they must reproduce
    glev   = g("glev"),   gg     = g("gg"),
    fbco   = g("fbco"),   fbap   = g("fbap"),
    fbdc   = g("fbdc"),   fbac   = g("fbac"),   fbgg = g("fbgg"),
    rslope = g("rslope"), rhz    = g("rhz"),
    rbandi = g("rbandi"),
    bq     = g("bq"),
    dt60   = g("dt60"),
    edch   = g("edch"),
  }
  self.heap_used = self.memtop
  if g("heap_ok") ~= 1 then
    return nil, string.format(
      "the EEL heap is too small for this take: %d doubles needed",
      M.heap_doubles(cfg, nchan))
  end
  if self.half ~= cfg.fft_size / 2 then
    return nil, "kernel geometry disagrees with the config"
  end
  return self
end

function K:set_ring_window(cfg)
  local dt = cfg.ring_hop / cfg.pitch_rate
  local w = math.max(1, math.floor((cfg.ring_win_ms / 1000.0) / dt + 0.5))
  if w > M.MAXW then w = M.MAXW end
  self.ring_w = w
  self.ring_dt = dt
  self.IG.Function_SetValue(self.func, "_RWIN", w)
  self.IG.Function_SetValue(self.func, "_RDT", dt)
  return w
end

function K:exec(task)
  self.IG.Function_SetValue(self.func, "_TASK", task)
  self.IG.Function_Execute(self.func)
end

function K:reset()  self:exec(3) end
function K:rewind() self:exec(4) end

local function push(self, nsamp, task)
  self.IG.Function_SetValue(self.func, "_NSAMP", nsamp)
  -- _IN is re-set before every array transfer: the array call moves it
  self.IG.Function_SetValue(self.func, "_IN", 0)
  self.IG.Function_SetValue_Array(self.func, "_IN", self.inbuf)
  self:exec(task)
end

function K:modal(nsamp) push(self, nsamp, 1); return self:frames() end
function K:ring(nsamp)  push(self, nsamp, 2); return self:rframes() end

function K:frames()  return self.IG.Function_GetValue(self.func, "mframes") end
function K:rframes() return self.IG.Function_GetValue(self.func, "rframes") end

-- Write a Lua table into a heap region through the scratch address variable.
-- `_RD` is re-set before every transfer because the array call moves it.
function K:write(addr, tbl)
  local arr = reaper.new_array(#tbl)
  for i = 1, #tbl do arr[i] = tbl[i] end
  self.IG.Function_SetValue(self.func, "_RD", addr)
  self.IG.Function_SetValue_Array(self.func, "_RD", arr)
end

-- Read any heap region back through the scratch address variable.
function K:read(addr, n)
  local arr = reaper.new_array(n)
  arr.clear(0)
  self.IG.Function_SetValue(self.func, "_RD", addr)
  self.IG.Function_GetValue_Array(self.func, "_RD", arr)
  return arr.table(1, n)
end

-- The modal cube as one histogram per bin, 1-based, ready for `spectrum.lua`.
function K:modal_cube()
  local flat = self:read(self.addr.mcube, self.half * self.nlev)
  local cube = {}
  for k = 1, self.half do
    local h, base = {}, (k - 1) * self.nlev
    for b = 1, self.nlev do h[b] = flat[base + b] end
    cube[k] = h
  end
  return cube
end

function K:ring_hz()
  return self:read(self.addr.rhz, self.nband)
end

-- Ring-time histograms per band, already gated: only start-level classes at or
-- above (band floor + head_db) are summed in. Doing the gate here, from the
-- level histogram the same pass produced, is what removes the need for a
-- second read of the audio.
-- The decay cube: one T60 histogram per band, filled from the pauses. Unlike
-- `ring_hist` this needs no level gate -- the gate that produced it was "the
-- voice has stopped", which is the condition that makes the number a T60.
function K:edc_hist()
  local flat = self:read(self.addr.edch, self.nband * self.nring)
  local out = {}
  for b = 1, self.nband do
    local base, h = (b - 1) * self.nring, {}
    for i = 1, self.nring do h[i] = flat[base + i] end
    out[b] = h
  end
  return out, self.IG.Function_GetValue(self.func, "egaps")
end

function K:ring_hist(cfg)
  local lev = self:read(self.addr.rlev, self.nband * self.nlev)
  local slo = self:read(self.addr.rslope,
                        self.nband * self.nlevclass * self.nring)
  local out, floors = {}, {}
  for b = 1, self.nband do
    local base = (b - 1) * self.nlev
    local hist = {}
    for i = 1, self.nlev do hist[i] = lev[base + i] end

    -- The band's own noise floor is p10 of its level distribution -- which is
    -- only its noise floor if every frame is a frame of the recording. Edited
    -- silence is a population at the very bottom, and at 10 % it takes even
    -- less of it than the modal cube's p20 needs to pin the floor to the axis.
    -- Measured on a take with stripped pauses: every band reported -140, the
    -- bottom of the axis, so the `floor_db + ring_head_db` gate below admitted
    -- everything and the ring times were taken over dither decay.
    local from = cfg.skip_silence == false and 1 or Spectrum.floor_bin(hist)
    local total = 0
    for i = from, self.nlev do total = total + hist[i] end
    local floor_db
    if total > 0 then
      local want, run = 0.10 * total, 0
      for i = from, self.nlev do
        run = run + hist[i]
        if run >= want then floor_db = self.lev0 + (i - 1); break end
      end
    end
    floors[b] = floor_db
    local h = {}
    for i = 1, self.nring do h[i] = 0 end
    if floor_db then
      -- the gate quantises to one class width; take the nearest edge rather
      -- than the next one up, or the gate is systematically too strict
      local gate = floor_db + cfg.ring_head_db - M.LEVCLASS_DB * 0.5
      for c = 0, self.nlevclass - 1 do
        if M.levclass_db(c) >= gate then
          local sb = ((b - 1) * self.nlevclass + c) * self.nring
          for i = 1, self.nring do h[i] = h[i] + slo[sb + i] end
        end
      end
    end
    out[b] = h
  end
  return out, floors
end

-- The three per-band levels the gate's thresholds are derived from, out of the
-- two level histograms the ring pass already filled -- so this costs no second
-- read of the audio, the same argument `ring_hist` above rests on.
--
-- `pause` is the one that did not exist before: the band's level distribution
-- restricted to frames where the decay cube's gate said the voice had stopped.
-- That is the TAIL, and a threshold is only meaningful if it lands between the
-- tail and the working level.
function K:gate_levels(cfg)
  local plv = self:read(self.addr.plev, self.nband * self.nlev)
  local lev = self:read(self.addr.rlev, self.nband * self.nlev)
  local pause, voice, floor, pause_n = {}, {}, {}, {}
  for b = 1, self.nband do
    local base = (b - 1) * self.nlev
    local ph, lh = {}, {}
    for i = 1, self.nlev do
      ph[i] = plv[base + i]
      lh[i] = lev[base + i]
    end
    -- edited-in silence is stepped over here too: it is a population at the
    -- very bottom of both histograms, and a percentile that lands inside it
    -- reports the master's dither rather than the room
    local raw = cfg.skip_silence == false
    local pf = raw and 1 or Spectrum.floor_bin(ph)
    local lf = raw and 1 or Spectrum.floor_bin(lh)
    pause[b], pause_n[b] = Gate.percentile_db(ph, self.lev0, Gate.PAUSE_PCT, pf)
    voice[b] = Gate.percentile_db(lh, self.lev0, Gate.VOICE_PCT, lf)
    floor[b] = Gate.percentile_db(lh, self.lev0, Gate.FLOOR_PCT, lf)
  end
  return pause, voice, floor, pause_n
end

-- ------------------------------------------------------------------ render

-- Load the peaking cascade. `list` comes from `solve.lua`; sections beyond
-- MAXBQ are dropped rather than silently wrapping.
function K:set_filters(list)
  local n = math.min(#list, M.MAXBQ)
  local flat = {}
  for i = 1, n do
    local c = list[i]
    local b = (i - 1) * 5
    flat[b + 1], flat[b + 2], flat[b + 3] = c.b0, c.b1, c.b2
    flat[b + 4], flat[b + 5] = c.a1, c.a2
  end
  if n > 0 then self:write(self.addr.bq, flat) end
  self.IG.Function_SetValue(self.func, "_NBQ", n)
  self.nbq = n
  return n
end

-- Per-bin T60 for the dereverb. `t60_of(hz)` may vary with frequency, which is
-- how the tail-vs-direct measurement is used: the room is not equally live
-- everywhere.
function K:set_t60(t60_of, rate, dfft)
  local half = dfft / 2
  local t = {}
  for k = 0, half do
    local f = k * rate / dfft
    t[k + 1] = (type(t60_of) == "function") and (t60_of(f) or 0) or t60_of
  end
  self:write(self.addr.dt60, t)
end

-- The gate's per-bin band map and its three per-band parameters.
--
-- The band GEOMETRY stays in `dr/gate.lua`: the kernel only ever receives an
-- index and a crossfade weight per bin, which is what lets the edges be
-- checked headlessly. `sug` is the analysis's suggestion or nil, and
-- `Gate.effective_band` decides between it and the hand-set keys -- so auto
-- mode never writes into `gate_thr1..8`.
function K:set_gate(cfg, sug, rate, dfft)
  local half = dfft / 2
  local bi, mx = {}, {}
  for k = 0, half do
    local b, m = Gate.bin_band(k * rate / dfft)
    bi[k + 1] = b - 1                    -- the EEL side is 0-based
    mx[k + 1] = m
  end
  self:write(self.addr.gbandi, bi)
  self:write(self.addr.gmix, mx)
  local thr, rng, rel = {}, {}, {}
  for g = 1, Gate.NBANDS do
    thr[g], rng[g], rel[g] = Gate.effective_band(cfg, sug, g)
  end
  self:write(self.addr.gthr, thr)
  self:write(self.addr.grange, rng)
  self:write(self.addr.grel, rel)

  -- The filterbank's coefficients, designed at the take's own rate. A
  -- crossover designed at the wrong rate puts its edge somewhere else, exactly
  -- as a peaking section would.
  if cfg.gate_domain == "filterbank" then
    local xo = Gate.crossovers(rate)
    local co, ap = {}, {}
    for i = 1, #xo do
      -- lp lp hp hp, so the kernel can run one uniform loop over the pair
      local secs = { xo[i].lp, xo[i].lp, xo[i].hp, xo[i].hp }
      for j = 1, 4 do
        local b = ((i - 1) * 4 + (j - 1)) * 5
        local c = secs[j]
        co[b+1], co[b+2], co[b+3], co[b+4], co[b+5] = c.b0, c.b1, c.b2, c.a1, c.a2
      end
      local b = (i - 1) * 5
      ap[b+1], ap[b+2], ap[b+3], ap[b+4], ap[b+5] =
        xo[i].ap.b0, xo[i].ap.b1, xo[i].ap.b2, xo[i].ap.a1, xo[i].ap.a2
    end
    self:write(self.addr.fbco, co)
    self:write(self.addr.fbap, ap)
    -- detector and attack as one-pole coefficients: this side knows the rate,
    -- and the floors that keep a low band from tracking its own waveform live
    -- with the band geometry in dr/gate.lua
    local dc, ac = {}, {}
    for g = 1, Gate.NBANDS do
      local det, att = Gate.detect_times(g)
      dc[g] = math.exp(-1.0 / (rate * det))
      ac[g] = 1.0 - math.exp(-1.0 / (rate * att))
    end
    self:write(self.addr.fbdc, dc)
    self:write(self.addr.fbac, ac)
  end
  return thr, rng, rel
end

-- Prepare the render chain. `rate` is the take's own source rate: a biquad
-- designed at the wrong rate puts its centre somewhere else.
function K:begin_render(cfg, rate, filters, t60_of)
  local set = function(n, v) self.IG.Function_SetValue(self.func, n, v) end
  set("_SRATE", rate)
  set("_DEREV", cfg.dereverb_on and 1 or 0)
  local fb = cfg.gate_on and cfg.gate_domain == "filterbank"
  set("_GATE", (cfg.gate_on and not fb) and 1 or 0)
  set("_GATEFB", fb and 1 or 0)
  set("_GMODE", cfg.gate_mode == "gate" and 1 or 0)
  set("_GRATIO", cfg.gate_ratio or 1)
  set("_FBOFF", Gate.FB_OFFSET_DB)
  set("_RESID", cfg.residual and 1 or 0)
  set("_DFFT", cfg.rfft_size)
  set("_DDELAY", cfg.delay_frames)
  set("_REDUCTION", cfg.reduction)
  set("_STRENGTH", cfg.strength)
  -- suppression off means no cascade at all, not a cascade of zero-gain
  -- sections: an empty cascade is a bit-exact pass-through
  self:set_filters((cfg.suppress_on ~= false) and (filters or {}) or {})
  if cfg.dereverb_on then self:set_t60(t60_of or cfg.t60, rate, cfg.rfft_size) end
  -- `_gate` is the suggestion `Config.effective` attached; nil means the
  -- hand-set thresholds, which is also what every headless caller gets
  if cfg.gate_on then self:set_gate(cfg, cfg._gate, rate, cfg.rfft_size) end
  self:exec(5)                      -- clear render state, latch parameters
end

function K:render(nsamp)
  self.IG.Function_SetValue(self.func, "_NSAMP", nsamp)
  self.IG.Function_SetValue(self.func, "_IN", 0)
  self.IG.Function_SetValue_Array(self.func, "_IN", self.inbuf)
  self:exec(6)
  self.IG.Function_SetValue(self.func, "_OUT", M.BLOCK * self.nchan)
  self.IG.Function_GetValue_Array(self.func, "_OUT", self.outbuf)
  return self.IG.Function_GetValue(self.func, "out_peak")
end

return M
