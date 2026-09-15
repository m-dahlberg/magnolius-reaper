-- @noindex
-- Narrow-resonance detection: candidates, and the three tests each must pass.
--
-- A candidate has to clear:
--   PROMINENCE  it stands above the 1/3-octave energy envelope
--   NARROWNESS  its Q is high enough to be a resonance and not a formant
--   OCCUPANCY   the singer was not usually putting a harmonic there
--
-- The ring index is measured and REPORTED but does not gate. It was a gate,
-- and `test/inject_in_reaper.lua` showed it could not detect a resonance
-- injected into the real take at 420 Hz with T60 0.30 s -- index 1.07 against
-- a 1.25 threshold, and no percentile of the distribution separated the
-- injected band from its neighbours. The cause is the time-frequency
-- trade-off, not the tuning: T60 0.30 s means a 7.3 Hz bandwidth, resolving
-- 7.3 Hz needs ~137 ms of window, and that is already half the decay being
-- measured. A gate that rejects everything, including a known true positive,
-- is worse than no gate.
--
-- Q is the primary false-positive guard and the reason this is not just a peak
-- picker. A room mode at T60 0.4 s is 2.2/T60 = 5.5 Hz wide, so Q ~ 18 at
-- 100 Hz; a vowel formant is 50-150 Hz wide, Q 5-10. Without the Q gate a
-- singer who favours one vowel reads as a roomful of modes.
--
-- The ring test is what stops the converse mistake. Measured on a real take,
-- 515.6 Hz stood +10 dB proud of its neighbours and was still not a resonance:
-- it was H3 of a 169.5 Hz fundamental and its ring index was 0.94.
--
-- Pure Lua: imports no `reaper`.

local Spectrum = require "dr.spectrum"

local M = {}

-- -3 dB mainlobe width of a periodic Hann window, in bins. The measured
-- bandwidth of any peak is at least this, so it is removed in quadrature
-- before Q is computed -- otherwise every line reads as Q = f/(1.44*bin_hz)
-- and a hum line looks like a mode.
M.WINDOW_BW_BINS = 1.44

function M.parabolic(curve, k)
  local a, b, c = curve[k - 1], curve[k], curve[k + 1]
  if not (a and b and c) then return 0.0 end
  local den = a - 2 * b + c
  if den == 0 then return 0.0 end
  local s = 0.5 * (a - c) / den
  if s < -1 or s > 1 then return 0.0 end
  return s
end

-- Interpolated -3 dB bandwidth around a peak, with the window's own width
-- deconvolved. Returns nil when the peak does not fall 3 dB on both sides
-- inside the array -- which is the honest answer, not a guess.
function M.bandwidth(curve, hz, k, bin_hz)
  local top = curve[k]
  if not top then return nil end
  local tgt = top - 3.0
  local lo
  local j = k
  while j > 1 and curve[j] and curve[j] > tgt do j = j - 1 end
  if j == k or not curve[j] then return nil end
  local d = curve[j + 1] - curve[j]
  lo = (d ~= 0) and (hz[j] + (tgt - curve[j]) / d * (hz[j + 1] - hz[j])) or hz[j]
  local hi
  j = k
  while j < #curve and curve[j] and curve[j] > tgt do j = j + 1 end
  if j == k or not curve[j] then return nil end
  d = curve[j - 1] - curve[j]
  hi = (d ~= 0) and (hz[j] - (tgt - curve[j]) / d * (hz[j] - hz[j - 1])) or hz[j]

  local meas = hi - lo
  local wbw  = M.WINDOW_BW_BINS * bin_hz
  local corr = meas * meas - wbw * wbw
  -- a peak narrower than the window is a line; report the window limit rather
  -- than an imaginary bandwidth
  if corr <= 0 then return 0.3 * wbw, true end
  return math.sqrt(corr), false
end

local function topographic(curve, k, radius)
  local lo, hi
  for j = math.max(1, k - radius), k - 1 do
    if curve[j] and (not lo or curve[j] < lo) then lo = curve[j] end
  end
  for j = k + 1, math.min(#curve, k + radius) do
    if curve[j] and (not hi or curve[j] < hi) then hi = curve[j] end
  end
  if not (lo and hi) then return nil end
  return curve[k] - math.max(lo, hi)
end

M.PEAK_RADIUS = 8

-- `ring_at(f)` returns the ring index at a frequency, or nil if unmeasured.
function M.run(curve, hz, occ, ring_at, cfg, bin_hz)
  local env = Spectrum.smooth_power(curve, hz, 1.0 / cfg.smooth_oct)
  local prom = Spectrum.subtract(curve, env)
  local out = {}
  for k = 2, #curve - 1 do
    local f = hz[k]
    if curve[k] and prom[k] and f >= cfg.search_lo_hz and f <= cfg.search_hi_hz
       and curve[k - 1] and curve[k + 1]
       and curve[k] > curve[k - 1] and curve[k] >= curve[k + 1]
       and prom[k] >= cfg.min_prominence_db then
      local topo = topographic(curve, k, M.PEAK_RADIUS)
      if topo and topo >= cfg.min_topo_db then
        local fr = (k + M.parabolic(curve, k)) * bin_hz
        local bw, is_line = M.bandwidth(curve, hz, k, bin_hz)
        local q = (bw and bw > 0) and (fr / bw) or nil
        local o = occ[k] or 0.0
        for j = math.max(1, k - 1), math.min(#occ, k + 1) do
          if occ[j] and occ[j] > o then o = occ[j] end
        end
        local ri = ring_at and ring_at(fr) or nil
        local c = {
          hz = fr, bin = k, prominence = prom[k], topo = topo,
          bw_hz = bw, q = q, is_line = is_line,
          occupancy = o, confidence = 1.0 - o,
          ring_index = ri, level_db = curve[k],
        }
        c.reasons = {}
        if not q or q < cfg.min_q then c.reasons[#c.reasons + 1] = "low Q" end
        if o > cfg.max_occupancy then c.reasons[#c.reasons + 1] = "sung here" end
        -- diagnostic only; see the header for why this does not gate
        c.rings = (ri ~= nil) and (ri >= cfg.min_ring_index) or nil
        c.accepted = (#c.reasons == 0)
        c.kind = M.classify(c, cfg)
        c.score = c.prominence * c.confidence * (ri or 1.0)
        out[#out + 1] = c
      end
    end
  end
  table.sort(out, function(a, b)
    if a.accepted ~= b.accepted then return a.accepted end
    return a.score > b.score
  end)
  return out, env, prom
end

-- Schroeder frequency: above it, modes overlap into a diffuse field and there
-- are no discrete modes to find. A narrow peak up there is a reflection or a
-- resonant object, and must not be called a mode.
function M.schroeder_hz(t60, volume_m3)
  if not t60 or t60 <= 0 or not volume_m3 or volume_m3 <= 0 then return nil end
  return 2000.0 * math.sqrt(t60 / volume_m3)
end

function M.classify(c, cfg)
  -- Mains labelling is capped at 500 Hz and the tenth harmonic. Above that a
  -- multiple of 50 is a coincidence, not evidence: 1000 Hz is a perfect 50 Hz
  -- harmonic and is far more likely to be anything else.
  if c.hz <= 500.0 then
    for _, mains in ipairs({ 50, 60 }) do
      local n = math.floor(c.hz / mains + 0.5)
      if n >= 1 and n <= 10 and math.abs(c.hz - n * mains) < math.max(1.0, 0.004 * c.hz) then
        return "hum " .. mains .. " Hz"
      end
    end
  end
  if c.is_line then return "tonal line" end
  local sch = cfg._schroeder_hz
  if sch and c.hz > sch then return "reflection" end
  return "mode"
end

function M.describe(c)
  local q = c.q and string.format("Q %.0f", c.q) or "Q -"
  local r = c.ring_index and string.format("ring %.2f", c.ring_index) or "ring -"
  return string.format("%8.1f Hz  %+.1f dB  %s  %s  occ %.2f  %s%s",
    c.hz, c.prominence, q, r, c.occupancy, c.kind,
    c.accepted and "" or ("  [rejected: " .. table.concat(c.reasons, ", ") .. "]"))
end

return M
