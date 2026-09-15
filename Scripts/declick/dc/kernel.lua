-- @noindex
-- Adaptive De-Click -- the EEL kernel wrapper.
--
-- Owns the compiled kernel, the memory map shared with it, and the five tasks
-- it exposes. Nothing above this file knows an address.
--
-- Layout: Lua owns the bottom of the heap (the interleaved I/O buffers, whose
-- addresses Function_SetValue_Array writes through) and the kernel allocates
-- everything of its own above _HEAP.
--
-- The envelope cache is sized from the take's length, so unlike DeNoise's the
-- memory map depends on the *item* and not only on the settings. That is what
-- makes the up-front size check worth having: a five minute stereo take at 30
-- bands wants a third of a gigabyte, and finding that out ten minutes into a
-- render is the wrong time.

local Config = require "dc.config"

local M = {}

local K = {}
K.__index = K

-- Samples per channel per Execute. An Execute is atomic, so this *is* the
-- worst-case UI hitch; 8192 amortises the call overhead against the filter
-- bank without leaving a frame.
M.BLOCK = 8192

-- Waveform / marker display buckets. Fixed, so the panel never has to care how
-- long the item is.
M.WAVB = 2048

M.MAX_HEAP_MB = 384

local DETECT_VALS = {
  _SENS = "sens_db", _CRACKLE = "crackle_db", _MAXSTEPS = "max_steps",
  _SEP = "sep", _XFADE = "xfade_ms", _MAXCUT = "max_cut_db",
  _MAXEVENT = "max_event_ms",
}

local function compile(ImGui, ctx, script_dir)
  local path = script_dir .. "dc/dsp/declick.eel"
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

-- Everything that fixes the memory map. A change in any of these means a new
-- kernel rather than a reconfigure -- and, because they are the analysis
-- parameters, a re-read of the audio as well.
function M.signature(geo, cfg)
  return table.concat({
    geo.nchan, geo.rate, geo.total_samples, Config.analysis_sig(cfg),
  }, "|")
end

function M.new(ImGui, ctx, script_dir, geo, cfg)
  local doubles = Config.heap_doubles(cfg, geo.rate, geo.total_samples, geo.nchan)
  local mb = doubles * 8 / 1048576
  if mb > M.MAX_HEAP_MB then
    return nil, string.format(
      "This take needs %.0f MB of envelope cache (%d bands x %d phases x %d ch " ..
      "over %.1f minutes). Raise the step size, or use fewer bands or phases.",
      mb, cfg.nbands, cfg.nphases, geo.nchan, geo.acc_len / 60)
  end

  local func, err = compile(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local k = setmetatable({
    ImGui = ImGui, func = func, geo = geo,
    nchan = geo.nchan, rate = geo.rate, block = M.BLOCK, wavb = M.WAVB,
    nbands = cfg.nbands, nphases = cfg.nphases,
    stepsz = Config.step_samples(cfg, geo.rate),
    nsteps = Config.nsteps(cfg, geo.rate, geo.total_samples),
    heap_mb = mb,
  }, K)

  local iolen = M.BLOCK * geo.nchan
  k.inbuf  = reaper.new_array(iolen)
  k.outbuf = reaper.new_array(iolen)

  local function set(n, v) ImGui.Function_SetValue(func, n, v) end
  set("_IN", 0)
  set("_OUT", iolen)
  set("_HEAP", iolen * 2)
  set("_NCH", geo.nchan)
  set("_SRATE", geo.rate)
  set("_TOTAL", geo.total_samples)
  set("_NSTEPS", k.nsteps)
  set("_WAVB", M.WAVB)
  set("_NB", cfg.nbands)
  set("_NPH", cfg.nphases)
  set("_STEPSZ", k.stepsz)
  set("_FLO", cfg.flo)
  set("_FHI", cfg.fhi)
  set("_ISOLATE", 0)
  set("_BREACH", -1)
  set("_BLO", 0)
  set("_BHI", cfg.nbands - 1)
  set("_NSAMP", 0)
  set("_RD", 0)
  set("_ABSFLOOR", 0)
  for name in pairs(DETECT_VALS) do set(name, 0) end

  k:exec(0)                            -- allocate and clear

  local function get(n) return ImGui.Function_GetValue(func, n) end
  k.nhist    = get("nhist")
  k.hist_lo  = get("hist_lo")
  k.hist_bin = get("hist_bin")
  k.nlhist    = get("nlhist")
  k.lhist_lo  = get("lhist_lo")
  k.lhist_bin = get("lhist_bin")
  k.maxev    = get("maxev")
  k.wbucket  = math.max(1, math.ceil(geo.total_samples / M.WAVB))
  k.addr = {
    hist = get("hist"), ckmax = get("ckmax"),
    wmin = get("wmin"), wmax = get("wmax"),
    bandcnt = get("bandcnt"), bandsum = get("bandsum"), ev = get("ev"),
    lhist = get("lhist"),
  }
  k.heap_used = get("memtop")

  if k.nhist <= 1 or k.addr.hist == 0 or k.nlhist <= 1
     or k.addr.lhist == 0 then
    return nil, "Kernel setup failed. ReaImGui version too old?"
  end
  if get("heap_ok") ~= 1 then
    return nil, string.format(
      "The EEL kernel could not allocate its %.0f MB for %d bands x %d phases " ..
      "x %d channels over %.1f minutes. Raise the step size, or use fewer " ..
      "bands or phases.",
      k.heap_used * 8 / 1048576, cfg.nbands, cfg.nphases, geo.nchan,
      geo.acc_len / 60)
  end

  k.scratch_n = math.max(k.nhist, k.nlhist, M.WAVB, 64)
  k.scratch = reaper.new_array(k.scratch_n)
  return k
end

function K:exec(task)
  self.ImGui.Function_SetValue(self.func, "_TASK", task)
  self.ImGui.Function_Execute(self.func)
end

function K:get(name) return self.ImGui.Function_GetValue(self.func, name) end

-- Push nsamp interleaved samples per channel; k.inbuf must already hold them.
function K:analyze(nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  self:exec(1)
  return IG.Function_GetValue(f, "ana_steps")
end

-- Walk the cached envelopes at `sens_db`, rebuilding the gain envelopes, the
-- overshoot histogram, the event list and the tallies. Pure over the cache, so
-- it can run on every slider move -- which is the whole point of the design.
-- `abs_floor_db` rejects any candidate whose foreground peak never reaches it,
-- in dBFS; 0 (or nil) disables it. It is not a cfg key on purpose: the survey
-- runs twice, once with it off to fill the level histogram the floor is read
-- off and once with it on, so the value is a result of detection rather than
-- a setting that goes into it. See dc/detect.lua.
function K:detect(cfg, sens_db, abs_floor_db)
  local IG, f = self.ImGui, self.func
  for name, key in pairs(DETECT_VALS) do
    IG.Function_SetValue(f, name, cfg[key])
  end
  IG.Function_SetValue(f, "_SENS", sens_db)
  IG.Function_SetValue(f, "_ABSFLOOR", abs_floor_db or 0)
  -- Band selection is resolved to indices here rather than in the kernel, so
  -- the panel and the kernel read the layout from one place.
  local blo, bhi = Config.band_range(cfg)
  IG.Function_SetValue(f, "_BLO", blo)
  IG.Function_SetValue(f, "_BHI", bhi)
  IG.Function_SetValue(f, "_BREACH", Config.reach_band(cfg))
  self:exec(2)
  return {
    events     = IG.Function_GetValue(f, "nev"),
    kept       = IG.Function_GetValue(f, "nev_kept"),
    cut_steps  = IG.Function_GetValue(f, "cut_steps"),
    nsteps     = self.nsteps,
    sens_db    = sens_db,
    band_lo    = blo,
    band_hi    = bhi,
  }
end

function K:process(nsamp, isolate)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_ISOLATE", isolate and 1 or 0)
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  self:exec(3)
  IG.Function_SetValue(f, "_OUT", self.block * self.nchan)
  IG.Function_GetValue_Array(f, "_OUT", self.outbuf)
  return IG.Function_GetValue(f, "out_peak")
end

-- Streaming state only; the envelope cache survives, which is what lets the
-- render run off an analysis done once.
function K:reset_stream() self:exec(4) end

function K:read(addr, n)
  local IG, f = self.ImGui, self.func
  local arr = (n <= self.scratch_n) and self.scratch or reaper.new_array(n)
  IG.Function_SetValue(f, "_RD", addr)
  IG.Function_GetValue_Array(f, "_RD", arr)
  return arr.table(1, n)
end

-- The level a candidate's foreground peak sat at, as a histogram over dBFS.
-- The overshoot histogram deliberately throws this away -- overshoot is a
-- ratio against the candidate's own background -- which is exactly why it
-- cannot see that a whole population of candidates came from a passage that
-- holds no audio at all. See dc/silence.lua.
function K:level_histogram()
  local t = self:read(self.addr.lhist, self.nlhist)
  local c = {}
  for b = 0, self.nlhist - 1 do c[b] = t[b + 1] end
  return { counts = c, n = self.nlhist, lo = self.lhist_lo, bin = self.lhist_bin }
end

-- The overshoot histogram, 0-based to match the kernel's bin numbering, with
-- the axis it lives on.
function K:histogram()
  local t = self:read(self.addr.hist, self.nhist)
  local c = {}
  for b = 0, self.nhist - 1 do c[b] = t[b + 1] end
  return { counts = c, n = self.nhist, lo = self.hist_lo, bin = self.hist_bin }
end

function K:waveform()
  return self:read(self.addr.wmin, self.wavb),
         self:read(self.addr.wmax, self.wavb),
         self:read(self.addr.ckmax, self.wavb)
end

function K:bands()
  return self:read(self.addr.bandcnt, self.nbands),
         self:read(self.addr.bandsum, self.nbands)
end

-- The full event list, one flat read. Only wanted at apply time, for take
-- markers and the log; the panel uses the ckmax raster instead.
function K:events(n)
  n = math.min(n or 0, self.maxev)
  if n < 1 then return {} end
  local flat = self:read(self.addr.ev, n * 4)
  local out = {}
  for i = 1, n do
    local o = (i - 1) * 4
    out[i] = {
      pos = flat[o + 1], over_db = flat[o + 2],
      width = flat[o + 3], bands = flat[o + 4],
    }
  end
  return out
end

return M
