-- Reference transcription of the kernel's FFT, in Lua.
--
-- dn/dsp/denoise.eel implements its own radix-2 transform because ReaImGui's
-- EEL sandbox, unlike JSFX, does not provide fft(). That makes it the one
-- genuinely new piece of DSP in this script and the one most worth testing.
-- This file is the same algorithm with the same index arithmetic, so
-- test/headless.lua can check it against a naive DFT without REAPER; the EEL
-- version is then a mechanical transcription of code that is known to work.
--
-- Buffers are 0-based interleaved complex, exactly as in the kernel.

local M = {}

function M.tables(n)
  local lg, i = 0, 1
  while i < n do lg = lg + 1 i = i * 2 end
  local brev, twr, twi = {}, {}, {}
  for k = 0, n - 1 do
    local j, b = 0, k
    for _ = 1, lg do
      j = j * 2 + (b - math.floor(b * 0.5) * 2)
      b = math.floor(b * 0.5)
    end
    brev[k] = j
  end
  for k = 0, n / 2 - 1 do
    twr[k] = math.cos(2 * math.pi * k / n)
    twi[k] = -math.sin(2 * math.pi * k / n)
  end
  return { n = n, brev = brev, twr = twr, twi = twi }
end

function M.fwd(buf, T)
  local n, brev, twr, twi = T.n, T.brev, T.twr, T.twi
  for i = 0, n - 1 do
    local j = brev[i]
    if j > i then
      local tr, ti = buf[2 * i], buf[2 * i + 1]
      buf[2 * i], buf[2 * i + 1] = buf[2 * j], buf[2 * j + 1]
      buf[2 * j], buf[2 * j + 1] = tr, ti
    end
  end
  local len = 2
  while len <= n do
    local hf = len // 2
    local step = n // len
    local i = 0
    while i < n do
      local k = 0
      for j = 0, hf - 1 do
        local tr, ti = twr[k], twi[k]
        local i0, i1 = i + j, i + j + hf
        local ar, ai = buf[2 * i1], buf[2 * i1 + 1]
        local vr = ar * tr - ai * ti
        local vi = ar * ti + ai * tr
        local ur, ui = buf[2 * i0], buf[2 * i0 + 1]
        buf[2 * i0], buf[2 * i0 + 1] = ur + vr, ui + vi
        buf[2 * i1], buf[2 * i1 + 1] = ur - vr, ui - vi
        k = k + step
      end
      i = i + len
    end
    len = len * 2
  end
  return buf
end

-- Unscaled, matching the JSFX ifft() convention the kernel inherits: the 1/N
-- lives in outscale instead.
function M.inv(buf, T)
  for i = 0, T.n - 1 do buf[2 * i + 1] = -buf[2 * i + 1] end
  M.fwd(buf, T)
  for i = 0, T.n - 1 do buf[2 * i + 1] = -buf[2 * i + 1] end
  return buf
end

-- Naive DFT, for the transform to be checked against.
function M.dft(x, n)
  local out = {}
  for k = 0, n - 1 do
    local re, im = 0, 0
    for t = 0, n - 1 do
      local a = -2 * math.pi * k * t / n
      re = re + x[2 * t] * math.cos(a) - x[2 * t + 1] * math.sin(a)
      im = im + x[2 * t] * math.sin(a) + x[2 * t + 1] * math.cos(a)
    end
    out[2 * k], out[2 * k + 1] = re, im
  end
  return out
end

function M.hann(n)
  local w = {}
  for i = 0, n - 1 do w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n) end
  return w
end

return M
