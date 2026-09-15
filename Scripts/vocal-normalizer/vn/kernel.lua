-- @noindex
-- Vocal Normalizer -- the EEL kernel wrapper.
--
-- Owns the compiled kernel, the memory map it shares with Lua, and the one
-- pass it exposes. Nothing above this file knows an address.
--
-- Layout: Lua takes the bottom of the heap for the interleaved input buffer,
-- the four per-frame output arrays and the two coefficient arrays -- these are
-- the addresses the Function_*_Array calls write through -- and the kernel
-- allocates its filter state above _HEAP.
--
-- The coefficients are designed in Lua (vn/biquad.lua) rather than in EEL.
-- EEL has the trig, but designing them here means they can be asserted
-- headlessly against BS.1770's published table, and the kernel never has to
-- know a sample rate for anything.

local Biquad   = require "vn.biquad"
local Loudness = require "vn.loudness"

local M = {}

local K = {}
K.__index = K

-- Frames handed over per Execute. An Execute is atomic, so this IS the
-- worst-case UI hitch: four quarter-blocks is 400 ms of audio at the default
-- block length, which at 48 kHz stereo through ten biquads is a few tens of
-- milliseconds -- near a frame, and small enough that the progress bar moves.
M.FRAMES = 4

local function compile(ImGui, ctx, script_dir)
  local path = script_dir .. "vn/dsp/loudness.eel"
  local fh = io.open(path, "rb")
  if not fh then return nil, "Cannot open " .. path end
  local code = fh:read("a")
  fh:close()
  local ok, func = pcall(ImGui.CreateFunctionFromEEL, code)
  if not ok or not func then
    return nil, "EEL compile failed: " .. tostring(func)
  end
  -- Attach, or it is garbage collected out from under us -- usually as a crash
  -- mid-analysis rather than a clean error.
  ImGui.Attach(ctx, func)
  return func
end

-- Flatten a section list into the { b0,b1,b2,a1,a2 } * n array the kernel
-- reads. The order here and the indexing in loudness.eel are one convention;
-- they are deliberately the same shape as what Biquad returns so there is no
-- third format to get wrong.
--
-- Written element by element into the reaper array rather than built as a Lua
-- table and handed to `copy`, and that is not a style choice. Measured on 7.75:
--
--   local t = {}
--   t[1], t[2], t[3], t[4], t[5] = a, b, c, d, e     -- five at once
--   t[6], t[7], t[8], t[9], t[10] = f, g, h, i, j
--   arr.copy(t)                                      -- arr[9] and arr[10] SWAP
--
-- A multiple assignment wide enough to outrun the table's array part leaves
-- the last keys in the hash part, and `reaper.array.copy` does not read a Lua
-- table in integer-key order when they are there. `#t` is still 10 and every
-- t[i] reads back correctly, so nothing about the table looks wrong -- the
-- damage appears only on the far side of `copy`. Filling the same table one
-- index at a time, or in pairs, or with a constructor, is all fine; it is the
-- five-at-once form that does it.
--
-- The cost of getting this wrong is a filter with its a1 and a2 transposed,
-- which is an unstable pole pair -- so the symptom was a K-weighted level of
-- `inf`, not a slightly wrong number. Not using `copy` at all removes the
-- question, and the round-trip check in M.new below makes sure it stays
-- removed.
local function pack(sections)
  local a = reaper.new_array(#sections * 5)
  for i, s in ipairs(sections) do
    local b = (i - 1) * 5
    for j = 1, 5 do a[b + j] = s[j] end
  end
  return a
end

-- Read a coefficient array back out of the kernel. The only reason this
-- exists is to prove the transfer landed: it is the one place where a silent
-- corruption between Lua and EEL would produce plausible audio rather than an
-- error, and it costs two calls at setup.
local function readback(ImGui, func, name, addr, n)
  local a = reaper.new_array(n)
  a.clear(0)
  ImGui.Function_SetValue(func, name, addr)
  ImGui.Function_GetValue_Array(func, name, a)
  return a
end

-- The channel count and the number of band sections fix the memory map, and
-- the source rate fixes the coefficients, so a change in any of them means a
-- new kernel rather than a reconfigure -- which is what Config.kernel_sig
-- exists to detect. The gate, the target and the limits are not here at all:
-- they never reach the kernel.
function M.new(ImGui, ctx, script_dir, nchan, cfg, rate)
  local func, err = compile(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local sections  = Biquad.band(cfg, rate)
  local ksections = Biquad.kweight(rate)
  local hop_s = Loudness.hop_s(cfg)

  local k = setmetatable({
    ImGui = ImGui, func = func, nchan = nchan, rate = rate,
    hop_s = hop_s, hopf = hop_s * rate,
    nsect = #sections, sections = sections, ksections = ksections,
    frames = M.FRAMES,
  }, K)

  -- The longest read a frame block can need, plus a sample of slack for the
  -- rounding at each end.
  k.maxsamp = math.ceil(M.FRAMES * k.hopf) + 2
  local iolen = k.maxsamp * nchan
  k.inbuf = reaper.new_array(iolen)

  local addr = iolen
  k.out, k.names = {}, { "ZB", "ZK", "N", "PK" }
  for _, name in ipairs(k.names) do
    k.out[name] = reaper.new_array(M.FRAMES)
    k.out[name .. "_addr"] = addr
    ImGui.Function_SetValue(func, "_OUT_" .. name, addr)
    addr = addr + M.FRAMES
  end

  -- The coefficients live in the Lua-owned region and are written once. The
  -- kernel reads them every sample, so they must not be overwritten by
  -- anything else -- which is why they get their own slots here rather than
  -- riding in the input buffer.
  local coef, kcoef = pack(sections), pack(ksections)
  local coef_addr, kcoef_addr = addr, addr + #coef
  ImGui.Function_SetValue(func, "_COEF", coef_addr)
  ImGui.Function_SetValue_Array(func, "_COEF", coef)
  ImGui.Function_SetValue(func, "_KCOEF", kcoef_addr)
  ImGui.Function_SetValue_Array(func, "_KCOEF", kcoef)
  addr = kcoef_addr + #kcoef

  ImGui.Function_SetValue(func, "_IN", 0)
  ImGui.Function_SetValue(func, "_HEAP", addr)
  ImGui.Function_SetValue(func, "_NCHAN", nchan)
  ImGui.Function_SetValue(func, "_NSECT", #sections)
  ImGui.Function_SetValue(func, "_MAXSAMP", k.maxsamp)
  ImGui.Function_SetValue(func, "_RESET", 0)

  k:exec(0)                                   -- allocate and clear

  -- The kernel echoes back the section count it actually set up with. If that
  -- disagrees with what Lua packed, every sample after this would be filtered
  -- through the wrong number of stages, so say so here rather than produce
  -- quiet nonsense.
  local echo = ImGui.Function_GetValue(func, "nsect_echo")
  if echo ~= #sections then
    return nil, string.format(
      "Kernel set up %d filter sections, Lua packed %d", echo, #sections)
  end

  -- Prove the coefficients arrived. Every filter in this script is designed in
  -- Lua and used in EEL, so this transfer is the single point where a correct
  -- design can become a wrong filter -- and a wrong filter does not raise, it
  -- just measures something else. Comparing what came back against what went
  -- out turns that into a startup error.
  k.coef_addr, k.kcoef_addr = coef_addr, kcoef_addr
  local function verify(name, addr, want, label)
    local got = readback(ImGui, func, name, addr, #want)
    for i = 1, #want do
      if got[i] ~= want[i] then
        return string.format(
          "%s coefficient %d did not survive the transfer: %.17g came back as %.17g",
          label, i, want[i], got[i])
      end
    end
  end
  local terr = verify("_COEF", coef_addr, coef, "Band")
             or verify("_KCOEF", kcoef_addr, kcoef, "K-weighting")
  if terr then return nil, terr end

  k.heap_used = ImGui.Function_GetValue(func, "memtop")
  if ImGui.Function_GetValue(func, "heap_ok") ~= 1 then
    return nil, string.format(
      "The EEL kernel could not allocate its heap for %d channels and %d sections.",
      nchan, #sections)
  end
  return k
end

function K:exec(task)
  self.ImGui.Function_SetValue(self.func, "_TASK", task)
  self.ImGui.Function_Execute(self.func)
end

-- Where frame f starts, in samples. Lua and the kernel round identically --
-- this expression appears in both -- which is what keeps the two on the same
-- instants over a take long enough for a half-sample-per-frame drift to matter.
function M.frame_sample(f, hopf) return math.floor(f * hopf + 0.5) end

-- Consume one block. `first` resets the filter state and must be true on the
-- first call of a pass and false on every other, or the take's opening
-- milliseconds are measured through whatever the last take left behind.
--
-- Returns the four reaper arrays; the caller pulls Lua tables out of them.
function K:measure(foff, nframes, nsamp, first)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  IG.Function_SetValue(f, "_NFRAMES", nframes)
  IG.Function_SetValue(f, "_FOFF", foff)
  IG.Function_SetValue(f, "_SOFF", M.frame_sample(foff, self.hopf))
  IG.Function_SetValue(f, "_HOPF", self.hopf)
  IG.Function_SetValue(f, "_RESET", first and 1 or 0)
  self:exec(1)
  for _, name in ipairs(self.names) do
    IG.Function_SetValue(f, "_OUT_" .. name, self.out[name .. "_addr"])
    IG.Function_GetValue_Array(f, "_OUT_" .. name, self.out[name])
  end
  return self.out.ZB, self.out.ZK, self.out.N, self.out.PK
end

-- The coefficients as the kernel holds them, for the selftest. Reading them
-- through here rather than from the addresses directly keeps the rule that
-- nothing above this file knows an address.
function K:coefficients()
  return readback(self.ImGui, self.func, "_COEF", self.coef_addr, self.nsect * 5),
         readback(self.ImGui, self.func, "_KCOEF", self.kcoef_addr, 10)
end

function M.detach(ImGui, ctx, k)
  if k and k.func then pcall(ImGui.Detach, ctx, k.func) end
end

return M
