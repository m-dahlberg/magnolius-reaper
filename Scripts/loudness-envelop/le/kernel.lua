-- @noindex
-- Loudness Envelope -- the EEL kernel wrapper.
--
-- Owns the compiled kernel and the memory map it shares with Lua. Nothing
-- above this file knows an address.
--
-- Layout: Lua takes the bottom of the heap for the interleaved input buffer
-- and the two per-frame output arrays; the kernel keeps nothing of its own
-- above _HEAP but the probe slots.

local Config = require "le.config"

local M = {}

local K = {}
K.__index = K

-- Frames handed over per Execute. An Execute is atomic, so this IS the
-- worst-case UI hitch: 400 frames of 10 ms is four seconds of audio, which at
-- 48 kHz stereo is about 400k multiply-compares -- a few milliseconds.
M.FRAMES = 400

local function compile(ImGui, ctx, script_dir)
  local path = script_dir .. "le/dsp/energy.eel"
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

-- Where frame f starts, in samples. Lua and the kernel round identically --
-- this expression appears in both -- which is what keeps the two on the same
-- instants over a take long enough for a half-sample-per-frame drift to matter.
function M.frame_sample(f, hopf) return math.floor(f * hopf + 0.5) end

-- The channel count fixes the interleave and the rate fixes the frame length,
-- so a change in either means a new kernel -- which Config.kernel_sig detects.
function M.new(ImGui, ctx, script_dir, nchan, rate)
  local func, err = compile(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local hop_s = Config.FRAME_S
  local k = setmetatable({
    ImGui = ImGui, func = func, nchan = nchan, rate = rate,
    hop_s = hop_s, hopf = hop_s * rate, frames = M.FRAMES,
  }, K)

  -- The longest read a frame block can need, plus a sample of slack for the
  -- rounding at each end.
  k.maxsamp = math.ceil(M.FRAMES * k.hopf) + 2
  local iolen = k.maxsamp * nchan
  k.inbuf = reaper.new_array(iolen)

  local addr = iolen
  k.out, k.names = {}, { "E", "N" }
  for _, name in ipairs(k.names) do
    k.out[name] = reaper.new_array(M.FRAMES)
    k.out[name .. "_addr"] = addr
    ImGui.Function_SetValue(func, "_OUT_" .. name, addr)
    addr = addr + M.FRAMES
  end

  ImGui.Function_SetValue(func, "_IN", 0)
  ImGui.Function_SetValue(func, "_HEAP", addr)
  ImGui.Function_SetValue(func, "_NCHAN", nchan)

  k:exec(0)

  if ImGui.Function_GetValue(func, "nch_echo") ~= nchan then
    return nil, "The kernel did not take the channel count it was given."
  end
  k.heap_used = ImGui.Function_GetValue(func, "memtop")
  if ImGui.Function_GetValue(func, "heap_ok") ~= 1 then
    return nil, string.format(
      "The EEL kernel could not address its heap for %d channels.", nchan)
  end
  return k
end

function K:exec(task)
  self.ImGui.Function_SetValue(self.func, "_TASK", task)
  self.ImGui.Function_Execute(self.func)
end

-- Consume one block of `nsamp` interleaved samples already in self.inbuf,
-- covering frames foff .. foff + nframes - 1. Returns the two reaper arrays.
function K:measure(foff, nframes, nsamp)
  local IG, f = self.ImGui, self.func
  IG.Function_SetValue(f, "_IN", 0)
  IG.Function_SetValue_Array(f, "_IN", self.inbuf)
  IG.Function_SetValue(f, "_NSAMP", nsamp)
  IG.Function_SetValue(f, "_NFRAMES", nframes)
  IG.Function_SetValue(f, "_FOFF", foff)
  IG.Function_SetValue(f, "_SOFF", M.frame_sample(foff, self.hopf))
  IG.Function_SetValue(f, "_HOPF", self.hopf)
  self:exec(1)
  for _, name in ipairs(self.names) do
    IG.Function_SetValue(f, "_OUT_" .. name, self.out[name .. "_addr"])
    IG.Function_GetValue_Array(f, "_OUT_" .. name, self.out[name])
  end
  return self.out.E, self.out.N
end

function M.detach(ImGui, ctx, k)
  if k and k.func then pcall(ImGui.Detach, ctx, k.func) end
end

return M
