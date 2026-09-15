-- @noindex
-- AutoTilt -- the EEL kernel wrapper.
--
-- The only file that knows an address. Lua owns the bottom of the heap for the
-- interleaved I/O buffers, the kernel allocates its own above _HEAP, and
-- everything above this file passes named values.
--
-- A change to channel count or FFT size changes the memory map, so it means a
-- NEW kernel rather than a reconfigure -- see Config.kernel_sig. The hop, and
-- the shelf coefficients, ride as parameters.

local Config = require "at.config"

local M = {}

-- Samples per channel per Execute. An Execute is atomic, so this block size
-- *is* the worst-case UI hitch; 8192 amortises the call overhead and still
-- lands near a frame.
M.BLOCK = 8192

local K = {}
K.__index = K

local function compile(ImGui, ctx, script_dir)
  local path = script_dir .. "at/dsp/tilt.eel"
  local fh = io.open(path, "rb")
  if not fh then return nil, "Cannot open " .. path end
  local code = fh:read("a")
  fh:close()
  local ok, func = pcall(ImGui.CreateFunctionFromEEL, code)
  if not ok or not func then
    return nil, "EEL compile failed: " .. tostring(func)
  end
  -- Attach, or it is garbage collected out from under us -- usually as a crash
  -- mid-render rather than a clean error.
  ImGui.Attach(ctx, func)
  return func
end

-- Doubles the kernel will ask for. Reported up front so a refusal can name a
-- figure rather than arriving as a wrong spectrum much later.
function M.heap_doubles(fft_size, nchan)
  local nbins = fft_size // 2 + 1
  return 2 * fft_size            -- fftbuf
       + fft_size                -- window
       + fft_size                -- twiddles (two half-length tables)
       + fft_size                -- bit reversal
       + nbins                   -- one frame
       + Config.NLEV             -- bucket counts
       + nchan * fft_size        -- input rings
       + nchan * 4               -- biquad state
       + Config.NLEV * nbins     -- the cube
end

function M.build(ImGui, ctx, script_dir, nchan, cfg)
  local func, err = compile(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local fft_size = Config.fft_size(cfg)
  local k = setmetatable({
    ImGui = ImGui, func = func, nchan = nchan,
    fft_size = fft_size, block = M.BLOCK,
    nlev = Config.NLEV, lev0 = Config.LEV0,
  }, K)

  local iolen = M.BLOCK * nchan
  k.inbuf  = reaper.new_array(iolen)
  k.outbuf = reaper.new_array(iolen)

  ImGui.Function_SetValue(func, "_IN", 0)
  ImGui.Function_SetValue(func, "_OUT", iolen)
  ImGui.Function_SetValue(func, "_HEAP", iolen * 2)
  ImGui.Function_SetValue(func, "_FFT", fft_size)
  ImGui.Function_SetValue(func, "_NCH", nchan)
  ImGui.Function_SetValue(func, "_HOP", Config.hop(cfg))
  k:exec(0)                              -- allocate, build tables, probe

  k.half     = ImGui.Function_GetValue(func, "half")
  k.nbins    = ImGui.Function_GetValue(func, "nbins")
  -- memtop is the top ADDRESS, and the kernel's heap starts above the
  -- Lua-owned I/O region -- so the size it actually asked for is the
  -- difference. Reporting the address instead overstates a mono 1024-point
  -- kernel by 16384 doubles, which is most of what it uses.
  k.heap_top  = ImGui.Function_GetValue(func, "memtop")
  k.heap_used = k.heap_top - iolen * 2
  k.addr = {
    cube  = ImGui.Function_GetValue(func, "cube"),
    cubeN = ImGui.Function_GetValue(func, "cubeN"),
  }

  if k.nbins <= 1 or k.addr.cube == 0 then
    return nil, "Kernel setup failed. ReaImGui version too old?"
  end
  if ImGui.Function_GetValue(func, "heap_ok") ~= 1 then
    return nil, string.format(
      "The EEL kernel could not allocate its %.1f MB of heap for %d channel%s " ..
      "at FFT %d. Try a smaller FFT size.",
      k.heap_used * 8 / 1048576, nchan, nchan == 1 and "" or "s", fft_size)
  end

  k.scratch_n = math.max(k.nbins, k.nlev)
  k.scratch = reaper.new_array(k.scratch_n)
  return k
end

function K:exec(task)
  self.ImGui.Function_SetValue(self.func, "_TASK", task)
  self.ImGui.Function_Execute(self.func)
end

function K:set_hop(hop)
  self.ImGui.Function_SetValue(self.func, "_HOP", math.max(1, math.floor(hop)))
end

-- Clears the cube, the counts and the ring together. Clearing one without the
-- other would have the next measurement divide stale sums by fresh counts.
function K:reset_analysis() self:exec(2) end

function K:reset_stream() self:exec(4) end

-- Push nsamp interleaved samples per channel; k.inbuf must already hold them.
function K:analyze(nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  self:exec(1)
  return IG.Function_GetValue(f, "ana_frames")
end

-- The five normalised coefficients per filter, plus the makeup gain. Named
-- values, so the kernel never computes a shelf and the two cannot drift.
function K:set_plan(plan)
  local IG, f = self.ImGui, self.func
  local names = { "B0", "B1", "B2", "A1", "A2" }
  for i, n in ipairs(names) do
    IG.Function_SetValue(f, "_LS" .. n, plan.low[i])
    IG.Function_SetValue(f, "_HS" .. n, plan.high[i])
  end
  IG.Function_SetValue(f, "_MAKEUP", plan.makeup or 1)
end

function K:render(nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  self:exec(3)
  IG.Function_SetValue(f, "_OUT", self.block * self.nchan)
  IG.Function_GetValue_Array(f, "_OUT", self.outbuf)
  return IG.Function_GetValue(f, "out_peak")
end

function K:read(addr, n)
  local IG, f = self.ImGui, self.func
  local arr = (n <= self.scratch_n) and self.scratch or reaper.new_array(n)
  IG.Function_SetValue(f, "_RD", addr)
  IG.Function_GetValue_Array(f, "_RD", arr)
  return arr.table(1, n)
end

function K:frames() return self.ImGui.Function_GetValue(self.func, "ana_frames") end

-- The frame-level histogram, 0-based to match the kernel's bucket numbering.
function K:counts()
  local t = self:read(self.addr.cubeN, self.nlev)
  local c = {}
  for b = 0, self.nlev - 1 do c[b] = t[b + 1] end
  return c
end

-- Only the occupied rows come back. A real take fills sixty of the hundred and
-- twenty-seven buckets, and reading the empty ones would cost more than every
-- sum taken over them afterwards.
function K:cube()
  local counts = self:counts()
  local rows = {}
  for lev = 0, self.nlev - 1 do
    if counts[lev] > 0 then
      rows[lev] = self:read(self.addr.cube + lev * self.nbins, self.nbins)
    end
  end
  return rows, counts
end


return M
