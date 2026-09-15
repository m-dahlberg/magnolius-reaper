-- @noindex
-- Spectral DeNoise -- the EEL kernel wrapper.
--
-- Owns the compiled kernel, the memory map shared with it, and the four calls
-- it exposes. Nothing above this file knows an address.
--
-- Layout: Lua owns the bottom of the heap (the interleaved I/O buffers, whose
-- addresses Function_SetValue_Array writes through) and the kernel allocates
-- everything of its own above _HEAP.

local M = {}

local K = {}
K.__index = K

-- Samples per channel handed over per Execute. Large enough that the per-call
-- overhead disappears against the FFT work, small enough that one call stays
-- near a UI frame: an Execute is atomic, so the block size *is* the worst-case
-- hitch during a render. At the 2048 default this is sixteen hops.
M.BLOCK = 8192

local PARAMS = {
  _REDUCTION = "reduction", _STRENGTH = "strength", _SMOOTHING = "smoothing",
  _WHITENING = "whitening", _MODE = "mode",
  _GTHRESH = "gthresh", _GATTACK = "gattack", _GHOLD = "ghold",
  _GRELEASE = "grelease", _GMODE = "gmode", _GRATIO = "gratio",
  _NLM = "nlm",
}
local FLAGS = {
  _RESIDUAL = "residual", _GATE_ON = "gate_on", _GAUTO = "gauto",
}

local function compile(ImGui, ctx, script_dir)
  local path = script_dir .. "dn/dsp/denoise.eel"
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

-- nchan and fft size are baked into the memory map, so a change in either
-- means a new kernel rather than a reconfigure. NLM is not: its rings are
-- always allocated at the Full size, so it rides along as an ordinary
-- parameter and can be toggled without touching the histogram.
function M.new(ImGui, ctx, script_dir, nchan, fft_size, nlm, srate)
  local func, err = compile(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local k = setmetatable({
    ImGui = ImGui, func = func, nchan = nchan, fft_size = fft_size,
    nlm = nlm, srate = srate, block = M.BLOCK,
  }, K)

  local iolen = M.BLOCK * nchan
  k.inbuf  = reaper.new_array(iolen)
  k.outbuf = reaper.new_array(iolen)

  ImGui.Function_SetValue(func, "_IN", 0)
  ImGui.Function_SetValue(func, "_OUT", iolen)
  ImGui.Function_SetValue(func, "_HEAP", iolen * 2)
  ImGui.Function_SetValue(func, "_FFT", fft_size)
  ImGui.Function_SetValue(func, "_NCH", nchan)
  ImGui.Function_SetValue(func, "_NLM", nlm)
  ImGui.Function_SetValue(func, "_SRATE", srate)
  ImGui.Function_SetValue(func, "_ANAHOP", fft_size / 2)
  ImGui.Function_SetValue(func, "_BANDLO", 0)
  ImGui.Function_SetValue(func, "_BANDHI", 0)
  ImGui.Function_SetValue(func, "_PROFOFF", 0)
  for name in pairs(PARAMS) do ImGui.Function_SetValue(func, name, 0) end
  for name in pairs(FLAGS) do ImGui.Function_SetValue(func, name, 0) end

  k:exec(0)                            -- allocate and clear

  k.half = ImGui.Function_GetValue(func, "half")
  k.nbins = k.half + 1
  k.nlev = ImGui.Function_GetValue(func, "nlev")
  k.lev0 = ImGui.Function_GetValue(func, "lev0")
  k.addr = {
    cubeN = ImGui.Function_GetValue(func, "cubeN"),
    prof  = ImGui.Function_GetValue(func, "prof"),
    meanS = ImGui.Function_GetValue(func, "meanS"),
    dispS = ImGui.Function_GetValue(func, "dispS"),
  }
  k.heap_used = ImGui.Function_GetValue(func, "memtop")
  if k.nbins <= 1 or k.addr.cubeN == 0 then
    return nil, "Kernel setup failed. ReaImGui version too old?"
  end
  if ImGui.Function_GetValue(func, "heap_ok") ~= 1 then
    return nil, string.format(
      "The EEL kernel could not allocate its %.1f MB of heap for %d channels " ..
      "at FFT %d. Try a smaller FFT size.",
      k.heap_used * 8 / 1048576, nchan, fft_size)
  end

  k.scratch_n = math.max(k.nbins, k.nlev)
  k.scratch = reaper.new_array(k.scratch_n)
  return k
end

function K:exec(task)
  self.ImGui.Function_SetValue(self.func, "_TASK", task)
  self.ImGui.Function_Execute(self.func)
end

function K:set_params(cfg)
  local f, IG = self.func, self.ImGui
  for name, key in pairs(PARAMS) do IG.Function_SetValue(f, name, cfg[key]) end
  for name, key in pairs(FLAGS) do
    IG.Function_SetValue(f, name, cfg[key] and 1 or 0)
  end
end

-- Analysis stride. One frame every half an FFT is far more than a mean power
-- spectrum needs; on a long file it is stretched further so the analysis stays
-- bounded no matter how much audio is thrown at it.
function K:set_stride(total_samples, max_frames)
  local hop = self.fft_size / 2
  local want = math.ceil(total_samples / math.max(max_frames, 100))
  if want > hop then hop = math.ceil(want / 64) * 64 end
  self.ana_hop = hop
  self.ImGui.Function_SetValue(self.func, "_ANAHOP", hop)
  return hop
end

function K:reset() self:exec(4) end

-- Clears the streaming state *and* the histogram, for a fresh analysis run.
-- Both halves of the histogram -- the per-level power sums and the frame
-- counts -- have to be cleared together, or the next profile divides stale
-- sums by fresh counts.
function K:reset_analysis() self:exec(5) end

-- Push nsamp interleaved samples per channel; k.inbuf must already hold them.
function K:analyze(nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  self:exec(1)
  return IG.Function_GetValue(f, "ana_frames")
end

function K:process(nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  self:exec(3)
  IG.Function_SetValue(f, "_OUT", self.block * self.nchan)
  IG.Function_GetValue_Array(f, "_OUT", self.outbuf)
  return IG.Function_GetValue(f, "out_peak")
end

-- Average the histogram rows in [lo_bin, hi_bin] into the noise profile.
function K:build_profile(lo_bin, hi_bin, offset_db)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_BANDLO", lo_bin)
  IG.Function_SetValue(f, "_BANDHI", hi_bin)
  IG.Function_SetValue(f, "_PROFOFF", offset_db or 0)
  self:exec(2)
  return IG.Function_GetValue(f, "prof_frames")
end

function K:read(addr, n)
  local IG, f = self.ImGui, self.func
  local arr = (n <= self.scratch_n) and self.scratch or reaper.new_array(n)
  IG.Function_SetValue(f, "_RD", addr)
  IG.Function_GetValue_Array(f, "_RD", arr)
  return arr.table(1, n)
end

-- The frame-level histogram, 0-based to match the kernel's bin numbering.
function K:counts()
  local t = self:read(self.addr.cubeN, self.nlev)
  local c = {}
  for b = 0, self.nlev - 1 do c[b] = t[b + 1] end
  return c
end

function K:profile_spectrum() return self:read(self.addr.prof, self.nbins) end
function K:mean_spectrum()    return self:read(self.addr.dispS, self.nbins) end
function K:frames() return self.ImGui.Function_GetValue(self.func, "ana_frames") end

return M
