-- @noindex
-- AutoTilt -- stage 3: the tilt curve, and the search for the gain that matches.
--
-- Pure Lua. This file owns the one definition of what "a tilt of G dB" means,
-- and both the prediction and the render read it: solve.lua evaluates the
-- coefficients analytically to say what the render will do, and kernel.lua
-- hands the same coefficients to the EEL that does it. That shared definition
-- is what lets the selftest assert the measured response against the predicted
-- one instead of hoping they agree.
--
-- The curve: an RBJ low shelf at -G/2 and a high shelf at +G/2, both cornered
-- at the pivot. Each RBJ shelf reaches half its dB gain at its own corner, so
-- the pair is exactly unity at the pivot, asymptotes to -G/2 below and +G/2
-- above, and spans G dB overall. G is therefore the tilt, and at G = 0 every
-- coefficient collapses to a pass-through -- b and a become equal term for
-- term, so the render is bit-exact, not merely quiet.

local Config   = require "at.config"
local Spectrum = require "at.spectrum"

local M = {}

-- RBJ cookbook shelving biquads, normalised by a0. `S` is the shelf slope: 1
-- is the steepest that does not overshoot, and a tilt wants to be broader than
-- that.
--
-- Computed in Lua rather than EEL because it is the piece worth asserting
-- headlessly, and because the kernel then needs to know nothing but five
-- numbers per filter.
function M.shelf(kind, f0, rate, db_gain, S)
  -- Above Nyquist there is no filter to design, and a pivot dragged there
  -- should do nothing rather than produce NaNs.
  local ny = rate * 0.5
  if f0 <= 0 or f0 >= ny then return { 1, 0, 0, 0, 0 } end
  if S == nil or S <= 0 then S = 1 end

  local A  = 10 ^ (db_gain / 40)
  local w0 = 2 * math.pi * f0 / rate
  local cw, sw = math.cos(w0), math.sin(w0)
  local alpha = sw / 2 * math.sqrt((A + 1 / A) * (1 / S - 1) + 2)
  local beta  = 2 * math.sqrt(A) * alpha

  local b0, b1, b2, a0, a1, a2
  if kind == "low" then
    b0 =     A * ((A + 1) - (A - 1) * cw + beta)
    b1 = 2 * A * ((A - 1) - (A + 1) * cw)
    b2 =     A * ((A + 1) - (A - 1) * cw - beta)
    a0 =         (A + 1) + (A - 1) * cw + beta
    a1 =    -2 * ((A - 1) + (A + 1) * cw)
    a2 =         (A + 1) + (A - 1) * cw - beta
  else
    b0 =      A * ((A + 1) + (A - 1) * cw + beta)
    b1 = -2 * A * ((A - 1) + (A + 1) * cw)
    b2 =      A * ((A + 1) + (A - 1) * cw - beta)
    a0 =          (A + 1) - (A - 1) * cw + beta
    a1 =      2 * ((A - 1) - (A + 1) * cw)
    a2 =          (A + 1) - (A - 1) * cw - beta
  end
  return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 }
end

-- The two filters that make a tilt of G dB about the pivot.
function M.pair(cfg, rate, gain_db)
  local S = cfg.shelf_slope
  local f = cfg.pivot_hz
  return M.shelf("low",  f, rate, -gain_db / 2, S),
         M.shelf("high", f, rate,  gain_db / 2, S)
end

-- |H(e^jw)|^2 of one normalised biquad at frequency f.
function M.response_sq(c, f, rate)
  local w = 2 * math.pi * f / rate
  local c1, s1 = math.cos(w), math.sin(w)
  local c2, s2 = math.cos(2 * w), math.sin(2 * w)
  local nr = c[1] + c[2] * c1 + c[3] * c2
  local ni =      -(c[2] * s1 + c[3] * s2)
  local dr = 1 + c[4] * c1 + c[5] * c2
  local di =    -(c[4] * s1 + c[5] * s2)
  local den = dr * dr + di * di
  if den <= 0 then return 0 end
  return (nr * nr + ni * ni) / den
end

function M.pair_response_sq(lo, hi, f, rate)
  return M.response_sq(lo, f, rate) * M.response_sq(hi, f, rate)
end

-- The pair's power gain per bin over the measured band. This is the *actual*
-- biquad response, not the ideal shelf asymptote -- which is the whole reason
-- the render and the prediction can be held to each other.
function M.curve(cfg, rate, b, gain_db)
  local lo, hi = M.pair(cfg, rate, gain_db)
  local out = {}
  for k = b.lo, b.hi do
    out[k] = M.pair_response_sq(lo, hi, b.hz[k], rate)
  end
  return out
end

function M.ratio_after(spec, cfg, rate, b, gain_db)
  return (Spectrum.ratio(spec, b, M.curve(cfg, rate, b, gain_db)))
end

-- The gain that makes this clip's balance equal `target_ratio`.
--
-- ratio_after is strictly increasing in G -- the low shelf only cuts further
-- and the high shelf only lifts further -- so a bisection cannot land on the
-- wrong root, and forty halvings of a 24 dB span settle it well past the
-- resolution of anything downstream.
function M.solve(spec, cfg, rate, b, target_ratio)
  local lim = math.abs(cfg.max_gain or 12)
  local out = { clamped = false, iters = 0 }

  local flo = M.ratio_after(spec, cfg, rate, b, -lim)
  local fhi = M.ratio_after(spec, cfg, rate, b,  lim)
  if not flo or not fhi then
    out.err = "no energy on one side of the pivot"
    return out
  end

  -- Outside the search span the answer is the edge of it, and saying so
  -- matters: silently returning the limit reads as a solved answer.
  if target_ratio <= flo then
    out.gain, out.clamped = -lim, true
    return out
  end
  if target_ratio >= fhi then
    out.gain, out.clamped = lim, true
    return out
  end

  -- Named glo/ghi rather than a/b: `b` is the band, and a bracket called `b`
  -- shadowed it here into passing a gain where the band was expected.
  local glo, ghi = -lim, lim
  for _ = 1, 40 do
    local m = (glo + ghi) / 2
    local r = M.ratio_after(spec, cfg, rate, b, m)
    if not r then break end
    if r < target_ratio then glo = m else ghi = m end
    out.iters = out.iters + 1
  end
  out.gain = (glo + ghi) / 2
  return out
end

-- The constant gain that holds the clip's in-band level where it was.
--
-- A tilt about 1 kHz changes overall level, because a vocal's energy is not
-- centred there; without this the match arrives with a level change attached
-- and reads as the tilt being wrong. Exactly 1 at G = 0.
function M.makeup(spec, cfg, rate, b, gain_db)
  if not cfg.compensate_level then return 1 end
  local before = Spectrum.band_power(spec, b)
  local after  = Spectrum.band_power(spec, b, M.curve(cfg, rate, b, gain_db))
  if before <= 0 or after <= 0 then return 1 end
  return math.sqrt(before / after)
end

-- What the render needs, in one call: the two filters and the makeup gain.
--
-- Two rates, because they can differ. The measurement read every clip at the
-- target's rate so both sides shared a bin mapping; the render writes the file
-- at the take's own source rate, so the coefficients have to be designed
-- there. Pass render_rate whenever the two are not the same -- a pivot is a
-- frequency, and a biquad designed at the wrong rate puts it somewhere else.
function M.plan(spec, cfg, ana_rate, gain_db, fft_size, render_rate)
  local b = Spectrum.band(cfg, ana_rate, fft_size)
  local lo, hi = M.pair(cfg, render_rate or ana_rate, gain_db)
  return {
    gain_db = gain_db,
    low = lo, high = hi,
    makeup = M.makeup(spec, cfg, ana_rate, b, gain_db),
  }
end

return M
