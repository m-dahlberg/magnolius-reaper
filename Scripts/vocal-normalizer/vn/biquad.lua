-- @noindex
-- Vocal Normalizer -- filter design.
--
-- Pure Lua, no reaper. Three things are designed here and nowhere else:
--
--   * the vocal measurement band -- a Butterworth high-pass and low-pass
--     cascade, which is what restricts the loudness measurement to the range
--     the melody's fundamentals actually live in;
--   * BS.1770 K-weighting, so the same kernel pass can also report the take's
--     ordinary LUFS and the panel can show the two numbers side by side. The
--     gap between them IS the bias this whole script exists to remove, so it
--     is worth measuring rather than asserting;
--   * the magnitude response of a section list, which is what the panel plots
--     and what the headless suite asserts against.
--
-- A section is { b0, b1, b2, a1, a2 }, already divided by a0, in cascade
-- order. That is exactly the layout vn/dsp/loudness.eel reads out of the
-- coefficient array, so this file and the kernel share one convention and no
-- conversion.
--
-- Why a CASCADE rather than one band-pass biquad: the band spans more than
-- three octaves (100 Hz to 1 kHz is 3.3), and a single band-pass biquad that
-- wide has Q < 0.3 -- a broad hump whose skirts still pass most of the
-- sibilance and most of the rumble the band is there to exclude. Two
-- Butterworth cascades give a flat passband and a slope you can state.

local M = {}

local pi, cos, sin, sqrt, log = math.pi, math.cos, math.sin, math.sqrt, math.log

local function db10(x) return 10 * log(x, 10) end

-- One RBJ cookbook section, normalised by a0.
--
-- `kind` is "hp" or "lp"; Q is the section Q. Frequencies at or above Nyquist
-- have no filter to design, so the degenerate coefficient sets are returned
-- instead: a high-pass that has run off the end of the band passes nothing, a
-- low-pass passes everything.
function M.rbj(kind, f0, rate, Q)
  local ny = rate * 0.5
  if kind == "hp" then
    if f0 <= 0 then return { 1, 0, 0, 0, 0 } end
    if f0 >= ny then return { 0, 0, 0, 0, 0 } end
  elseif kind == "lp" then
    if f0 >= ny then return { 1, 0, 0, 0, 0 } end
    if f0 <= 0 then return { 0, 0, 0, 0, 0 } end
  end

  local w0 = 2 * pi * f0 / rate
  local cw, sw = cos(w0), sin(w0)
  local alpha = sw / (2 * Q)
  local b0, b1, b2, a0, a1, a2

  if kind == "hp" then
    b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
    a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
  elseif kind == "lp" then
    b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
    a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
  else
    error("unknown filter kind: " .. tostring(kind), 2)
  end

  return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 }
end

-- Butterworth section Qs. An order-N Butterworth factors into N/2 second-order
-- sections whose Qs are fixed by the order alone -- the pole angles of the
-- Butterworth circle -- so this is a table, not a design step.
--   order 2 -> { 0.7071 }            12 dB/oct
--   order 4 -> { 0.5412, 1.3066 }    24 dB/oct
function M.butterworth_qs(order)
  if order % 2 ~= 0 or order < 2 then
    error("Butterworth order must be even and at least 2, got " ..
          tostring(order), 2)
  end
  local qs = {}
  for k = 0, order // 2 - 1 do
    qs[#qs + 1] = 1 / (2 * cos((2 * k + 1) * pi / (2 * order)))
  end
  return qs
end

function M.butterworth(kind, f0, rate, order)
  local out = {}
  for _, q in ipairs(M.butterworth_qs(order)) do
    out[#out + 1] = M.rbj(kind, f0, rate, q)
  end
  return out
end

-- K-weighting ---------------------------------------------------------------
--
-- BS.1770 does not define K-weighting as an analog prototype. It defines it as
-- two sets of digital coefficients AT 48 kHz, and says nothing about any other
-- rate -- so a 44.1 or 96 kHz take needs those same filters re-derived, not a
-- curve that slides with the sample rate.
--
-- The obvious shortcut is to fit an RBJ high-shelf to stage 1 and re-run the
-- cookbook at the new rate. Measured: the best fit reachable that way is
-- 0.16 dB off the standard's own curve around 1 kHz, because stage 1 simply is
-- not an RBJ shelf. That is small, and it is still ten times the agreement
-- this script wants with REAPER's loudness analysis, so it is not the method.
--
-- Instead the poles and zeros of the tabulated 48 kHz filters are mapped back
-- through the bilinear transform and forward again at the target rate. The
-- round trip composes into one real Mobius map,
--
--     z' = ((r1 + r0) z + (r1 - r0)) / ((r1 - r0) z + (r1 + r0))
--
-- which is the identity when r1 == r0. So at 48 kHz this reproduces the
-- standard's coefficients exactly -- the suite asserts it to 1e-12 -- and at
-- every other rate it is the same analog filter, correctly discretised.

-- BS.1770-4's tabulated 48 kHz coefficients, as { b0,b1,b2,a1,a2 }.
M.K48 = {
  { 1.53512485958697, -2.69169618940638, 1.19839281085285,
    -1.69065929318241, 0.73248077421585 },
  { 1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621 },
}
M.K48_RATE = 48000

-- Roots of z^2 + p z + q, as two complex numbers (re, im). Real roots come
-- back with zero imaginary parts; a complex pair comes back conjugated, which
-- is what lets the caller rebuild a real quadratic from them unconditionally.
local function roots2(p, q)
  local disc = p * p - 4 * q
  if disc >= 0 then
    local r = sqrt(disc)
    return (-p + r) / 2, 0, (-p - r) / 2, 0
  end
  local r = sqrt(-disc)
  return -p / 2, r / 2, -p / 2, -r / 2
end

local function mobius(zr, zi, r0, r1)
  local p, m = r1 + r0, r1 - r0
  local nr, ni = p * zr + m, p * zi
  local dr, di = m * zr + p, m * zi
  local d = dr * dr + di * di
  return (nr * dr + ni * di) / d, (ni * dr - nr * di) / d
end

-- Rebuild the monic quadratic z^2 + p z + q whose roots are the given pair.
-- Both cases are covered by the same two lines: a conjugate pair (a+bi, a-bi)
-- gives p = -2a and q = a^2 + b^2, and two reals give p = -(r1+r2), q = r1*r2.
local function quad_from(z1r, z1i, z2r, z2i)
  return -(z1r + z2r), z1r * z2r - z1i * z2i
end

-- |H(z)| at z = +-1, where the response is real: the sum of the coefficients
-- with alternating signs at Nyquist.
local function edge_gain(s, at_dc)
  local n, d
  if at_dc then
    n, d = s[1] + s[2] + s[3], 1 + s[4] + s[5]
  else
    n, d = s[1] - s[2] + s[3], 1 - s[4] + s[5]
  end
  return d ~= 0 and (n / d) or 0
end

-- Re-rate one section. `from` and `to` are sample rates.
--
-- The gain is fixed by matching the original at one point where both filters
-- are flat and the response is purely real: DC for the shelf (whose DC gain is
-- exactly 1), Nyquist for the high-pass (whose DC gain is exactly 0 and whose
-- passband runs flat from ~100 Hz upward, so both rates' Nyquist sit in it).
function M.rerate(s, from, to)
  if from == to then return { s[1], s[2], s[3], s[4], s[5] } end

  local pr1, pi1, pr2, pi2 = roots2(s[4], s[5])
  pr1, pi1 = mobius(pr1, pi1, from, to)
  pr2, pi2 = mobius(pr2, pi2, from, to)
  local a1, a2 = quad_from(pr1, pi1, pr2, pi2)

  local b0, b1, b2 = s[1], s[2], s[3]
  local B1, B2
  if b0 ~= 0 then
    local zr1, zi1, zr2, zi2 = roots2(b1 / b0, b2 / b0)
    zr1, zi1 = mobius(zr1, zi1, from, to)
    zr2, zi2 = mobius(zr2, zi2, from, to)
    B1, B2 = quad_from(zr1, zi1, zr2, zi2)
  else
    -- Degenerate numerator: nothing here produces one, but a silent wrong
    -- answer would be worse than saying so.
    error("rerate needs a second-order numerator", 2)
  end

  local at_dc = math.abs(edge_gain(s, true)) > 1e-9
  local out = { 1, B1, B2, a1, a2 }
  local want, have = edge_gain(s, at_dc), edge_gain(out, at_dc)
  local g = have ~= 0 and (want / have) or 1
  out[1], out[2], out[3] = g, B1 * g, B2 * g
  return out
end

function M.kweight(rate)
  local out = {}
  for i, s in ipairs(M.K48) do out[i] = M.rerate(s, M.K48_RATE, rate) end
  return out
end

-- The measurement band ------------------------------------------------------
--
-- High-pass then low-pass, each `order` poles, optionally followed by the
-- K-weighting pair. K is off by default and it is worth saying why: the shelf
-- lifts everything above ~1.5 kHz by 4 dB and the RLB high-pass turns over at
-- 38 Hz, so inside a 100..1000 Hz band K-weighting is flat to within a tenth
-- of a dB and does nothing but cost two biquads. It exists as an option so
-- that opening the band to the full spectrum and switching K on reproduces
-- ordinary LUFS exactly -- which is how the whole chain gets checked against
-- REAPER's own loudness analysis.
function M.band(cfg, rate)
  local out = {}
  for _, s in ipairs(M.butterworth("hp", cfg.band_lo_hz, rate, cfg.band_order)) do
    out[#out + 1] = s
  end
  for _, s in ipairs(M.butterworth("lp", cfg.band_hi_hz, rate, cfg.band_order)) do
    out[#out + 1] = s
  end
  if cfg.kweight then
    for _, s in ipairs(M.kweight(rate)) do out[#out + 1] = s end
  end
  return out
end

-- Magnitude response ---------------------------------------------------------
-- |H(e^jw)| of one section, then of a cascade, in dB. Used by the panel's band
-- plot and by the suite; nothing in the signal path calls it.
function M.section_db(s, f, rate)
  local w = 2 * pi * f / rate
  local c1, s1 = cos(w), sin(w)
  local c2, s2 = cos(2 * w), sin(2 * w)
  local nr = s[1] + s[2] * c1 + s[3] * c2
  local ni =      -s[2] * s1 - s[3] * s2
  local dr = 1    + s[4] * c1 + s[5] * c2
  local di =      -s[4] * s1 - s[5] * s2
  local num = nr * nr + ni * ni
  local den = dr * dr + di * di
  if den <= 0 then return -math.huge end
  if num <= 0 then return -math.huge end
  return db10(num / den)
end

function M.response_db(sections, f, rate)
  local total = 0
  for _, s in ipairs(sections) do
    local d = M.section_db(s, f, rate)
    if d == -math.huge then return -math.huge end
    total = total + d
  end
  return total
end

return M
