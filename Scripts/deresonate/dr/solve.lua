-- @noindex
-- Filter design and the gains to use.
--
-- The one thing worth knowing: a cut's gain is SOLVED, not set to the measured
-- prominence. For a single isolated bell the two agree by definition, but cuts
-- overlap -- a broad hump and a narrow line inside it are common -- and the
-- analysis window smears every peak. So each gain is found by bisecting the
-- real |H|^2 of the whole cascade against the cached spectrum until the
-- corrected level at the target frequency lands on the envelope.
--
-- Pure Lua: imports no `reaper`.

local M = {}

M.BISECT_ROUNDS = 40

-- RBJ cookbook peaking EQ, normalised by a0 so a1/a2 are ready for a
-- transposed direct form II section.
function M.peaking(f0, q, db_gain, rate)
  local A     = 10 ^ (db_gain / 40.0)
  local w0    = 2 * math.pi * f0 / rate
  local cw    = math.cos(w0)
  local alpha = math.sin(w0) / (2 * q)
  local a0    = 1 + alpha / A
  return {
    b0 = (1 + alpha * A) / a0,
    b1 = (-2 * cw) / a0,
    b2 = (1 - alpha * A) / a0,
    a1 = (-2 * cw) / a0,
    a2 = (1 - alpha / A) / a0,
    f0 = f0, q = q, db = db_gain,
  }
end

-- |H(e^jw)|^2 of one normalised biquad.
function M.response_sq(c, f, rate)
  local w   = 2 * math.pi * f / rate
  local c1, s1 = math.cos(w), math.sin(w)
  local c2, s2 = math.cos(2 * w), math.sin(2 * w)
  local nr = c.b0 + c.b1 * c1 + c.b2 * c2
  local ni = -(c.b1 * s1 + c.b2 * s2)
  local dr = 1 + c.a1 * c1 + c.a2 * c2
  local di = -(c.a1 * s1 + c.a2 * s2)
  local den = dr * dr + di * di
  if den <= 0 then return 1.0 end
  return (nr * nr + ni * ni) / den
end

function M.cascade_db(list, f, rate)
  local acc = 0.0
  for i = 1, #list do
    acc = acc + 10.0 * math.log(M.response_sq(list[i], f, rate), 10)
  end
  return acc
end

-- Solve one cut's gain so that the WHOLE cascade, this filter included,
-- delivers `want_db` of attenuation at f0. Both kinds of finding reduce to
-- this; they differ only in what they ask for:
--   narrow  want = envelope - level        (bring the peak down to the 1/3-oct
--                                           envelope it stands proud of)
--   broad   want = -hump                   (undo the measured deviation from
--                                           the 2-octave baseline)
-- Solving a broad hump against the 1/3-octave envelope instead is wrong and
-- silently produces almost no cut: that envelope FOLLOWS a hump an octave wide,
-- so the gap it measures is nearly zero. Measured on a real take, the 475 Hz
-- hump came out at -0.50 dB where it should have been -4.4.
function M.solve_cut(others, f0, q, rate, want_db, max_cut_db)
  local base = M.cascade_db(others, f0, rate)
  local function err(g)
    local c = M.peaking(f0, q, g, rate)
    return base + 10.0 * math.log(M.response_sq(c, f0, rate), 10) - want_db
  end
  local lo, hi = -max_cut_db, 0.0
  local elo, ehi = err(lo), err(hi)
  -- err is monotonically increasing in g; out of bracket means clamped, and
  -- saying so is better than silently returning the limit
  if elo > 0 then return lo, true end
  if ehi < 0 then return hi, true end
  for _ = 1, M.BISECT_ROUNDS do
    local mid = 0.5 * (lo + hi)
    if err(mid) < 0 then lo = mid else hi = mid end
  end
  return 0.5 * (lo + hi), false
end

-- Build the filter cascade for a set of accepted narrow candidates and broad
-- humps. `level_at(f)` and `target_at(f)` read the cached spectrum and the
-- envelope it should be brought back to.
function M.plan(cands, humps, level_at, target_at, cfg, rate)
  local out = {}
  local function add(f0, q, want_db, kind, label)
    if f0 <= 0 or f0 >= rate * 0.5 then return end
    if not want_db or want_db >= -0.05 then return end
    -- A measured Q runs to three figures on a near-sinusoidal line, and a
    -- biquad that narrow rings audibly and is numerically delicate at 48 kHz.
    q = math.max(0.3, math.min(cfg.max_q or 60, q))
    local g, clamped = M.solve_cut(out, f0, q, rate,
                                   want_db + cfg.target_headroom_db,
                                   cfg.max_cut_db)
    if g < -0.05 then
      local c = M.peaking(f0, q, g, rate)
      c.kind, c.label, c.clamped = kind, label, clamped
      c.want = want_db
      out[#out + 1] = c
    end
  end
  for _, c in ipairs(cands or {}) do
    if c.accepted and #out < cfg.max_bands then
      local lvl, tgt = level_at(c.hz), target_at(c.hz)
      if lvl and tgt then
        add(c.hz, (c.q or 10) * cfg.q_scale, tgt - lvl, "narrow", c.kind)
      end
    end
  end
  for _, h in ipairs(humps or {}) do
    if #out < cfg.max_bands then
      -- the hump's own measured deviation is what to undo
      add(h.hz, h.q, -h.db, "broad", h.source)
    end
  end
  return out
end

function M.describe(c)
  return string.format("%8.1f Hz  Q %5.2f  %+6.2f dB  %s%s",
    c.f0, c.q, c.db, c.kind or "?", c.clamped and "  (clamped)" or "")
end

return M
