-- @noindex
-- AutoTilt -- 32-bit float WAV writer.
--
-- ReaScript can read audio through an accessor but has no sink, so the tilted
-- result is written here and handed back to REAPER as a media source.
-- Float, always: a tilt lifts one half of the spectrum, so a take that peaked
-- near 0 dBFS can overshoot it, and a float file simply carries that rather
-- than clipping.
--
-- Verbatim from DeClick's dc/wav.lua apart from this header.
--
-- Pure Lua. Sample packing is done a chunk at a time through a pre-built
-- format string -- string.pack once per sample is roughly an order of
-- magnitude slower, which is the difference between a few seconds and a minute
-- on a long take.

local M = {}

local CHUNK = 4096            -- samples per string.pack call

local Writer = {}
Writer.__index = Writer

-- Interleaved frames are pushed in; the header is patched on close, so the
-- length does not have to be known up front.
function M.create(path, nchan, samplerate)
  local fh, err = io.open(path, "wb")
  if not fh then return nil, err or ("cannot open " .. path) end

  local block_align = 4 * nchan
  -- WAVE_FORMAT_IEEE_FLOAT (3), 32 bit. Sizes are patched in close().
  fh:write("RIFF")
  fh:write(string.pack("<I4", 0))
  fh:write("WAVE")
  fh:write("fmt ")
  fh:write(string.pack("<I4I2I2I4I4I2I2", 16, 3, nchan, samplerate,
                       samplerate * block_align, block_align, 32))
  fh:write("data")
  fh:write(string.pack("<I4", 0))

  return setmetatable({
    fh = fh, path = path, nchan = nchan, rate = samplerate,
    bytes = 0, fmt = {}, peak = 0,
  }, Writer)
end

function Writer:_fmt(n)
  local f = self.fmt[n]
  if not f then
    f = "<" .. string.rep("f", n)
    self.fmt[n] = f
  end
  return f
end

-- t is a flat interleaved Lua array; writes t[from..to].
function Writer:write(t, from, to)
  local i = from
  local out = {}
  local no = 0
  while i <= to do
    local n = math.min(CHUNK, to - i + 1)
    no = no + 1
    out[no] = string.pack(self:_fmt(n), table.unpack(t, i, i + n - 1))
    i = i + n
  end
  local s = table.concat(out)
  self.fh:write(s)
  self.bytes = self.bytes + #s
  return true
end

function Writer:close()
  local fh = self.fh
  if not fh then return false, "already closed" end
  -- odd-sized data chunks need a pad byte; float32 data is always even
  fh:seek("set", 4)
  fh:write(string.pack("<I4", 36 + self.bytes))
  fh:seek("set", 40)
  fh:write(string.pack("<I4", self.bytes))
  fh:close()
  self.fh = nil
  return true
end

function Writer:abort()
  if self.fh then self.fh:close() self.fh = nil end
  os.remove(self.path)
end

-- A plain 32-bit float WAV tops out at 4 GB. Callers check up front rather
-- than discovering it after ten minutes of processing.
function M.will_overflow(nsamples, nchan)
  return nsamples * nchan * 4 + 44 >= 0xFFFFFFFF
end

return M
