-- @noindex
-- Broad colouration: humps an octave wide, and whether the room or the source
-- put them there.
--
-- This stage exists because of a measurement that contradicted the whole
-- narrow-peak approach. On a real male take the user could plainly hear a
-- resonance "around 550 Hz", and four narrow detectors -- p20 prominence,
-- the same conditioned on no harmonic present, p99 prominence, and the ring
-- index -- all returned NOTHING there, several of them returning a dip.
--
-- The reason is structural: measuring a 1/3-octave curve against its own
-- 1/3-octave envelope cancels any feature that wide. A broad hump is invisible
-- to it by construction. Measuring a 1/1-octave curve against a 2-octave
-- baseline instead found it at once -- +4.1 dB centred 476 Hz, spanning roughly
-- 400-635 Hz, which is what the ear had been calling "550".
--
-- Attribution matters as much as detection. Run the same measurement on the
-- direct-dominated percentile and the tail-dominated one:
--   hump stronger in the DIRECT field  -> source, mic, proximity or a boundary
--   hump stronger in the TAIL          -> genuinely the room
-- On that take the 476 Hz hump was 2.2 dB *weaker* in the tail, so it is the
-- microphone or the voice, not the room -- worth cutting either way, but the
-- user should be told which they are fixing.
--
-- Pure Lua: imports no `reaper`.

local Spectrum = require "dr.spectrum"

local M = {}

-- Deviation of the measurement scale from the baseline scale.
function M.deviation(curve, hz, cfg)
  local meas = Spectrum.smooth_db(curve, hz, cfg.broad_oct)
  local base = Spectrum.smooth_db(curve, hz, cfg.broad_base_oct)
  return Spectrum.subtract(meas, base), meas, base
end

-- Humps in `direct`, attributed by comparison with `tail`.
-- Either curve may be nil; with only one, everything is reported unattributed.
--
-- `lo_hz` overrides cfg.search_lo_hz and should be set to just above the
-- singer's own fundamental range. Without it the strongest "hump" on a real
-- take is simply where the voice puts its fundamental -- measured: 152 Hz on a
-- male take whose f0 median is 169 Hz, and 285 Hz on a female take at 308 Hz.
-- That is the voice's spectral balance, a mix decision, not a room defect.
function M.humps(direct, tail, hz, cfg, lo_hz)
  lo_hz = lo_hz or cfg.search_lo_hz
  local dd = M.deviation(direct, hz, cfg)
  local dt = tail and M.deviation(tail, hz, cfg) or nil
  local out = {}
  local n = #hz
  for i = 2, n - 1 do
    local v = dd[i]
    if v and dd[i - 1] and dd[i + 1]
       and v > dd[i - 1] and v >= dd[i + 1]
       and v >= cfg.min_broad_db
       and hz[i] >= lo_hz and hz[i] <= cfg.search_hi_hz then
      -- span: out to where the deviation falls to half the peak
      local half = v * 0.5
      local a, b = i, i
      while a > 1 and dd[a - 1] and dd[a - 1] > half do a = a - 1 end
      while b < n and dd[b + 1] and dd[b + 1] > half do b = b + 1 end
      local width_oct = math.log(hz[b] / hz[a], 2)
      local tv = dt and dt[i] or nil
      local source, margin
      if tv then
        margin = tv - v
        source = (margin > 0.5) and "room" or "source"
      else
        source = "unknown"
      end
      out[#out + 1] = {
        hz         = hz[i],
        db         = v,
        direct_db  = v,
        tail_db    = tv,
        margin     = margin,
        source     = source,
        lo_hz      = hz[a],
        hi_hz      = hz[b],
        width_oct  = width_oct,
        -- a broad hump wants a wide bell, not a notch; derive Q from the
        -- measured width rather than assuming one
        q          = (width_oct > 0) and (1.0 / width_oct) or cfg.broad_q,
      }
    end
  end
  table.sort(out, function(x, y) return x.db > y.db end)

  -- A broad hump spans many points, so its deviation curve carries several
  -- adjacent maxima and each becomes a candidate. They are one hump: merge
  -- anything whose span overlaps an already-accepted peak, keeping the
  -- strongest. Without this a single feature is reported six times.
  local merged = {}
  for _, h in ipairs(out) do
    local dup = false
    for _, m in ipairs(merged) do
      if h.hz >= m.lo_hz and h.hz <= m.hi_hz then dup = true; break end
    end
    if not dup then merged[#merged + 1] = h end
  end
  return merged
end

function M.describe(h)
  return string.format("%.0f Hz  %+.1f dB over %.2f oct (%.0f-%.0f Hz), Q %.1f, %s",
    h.hz, h.db, h.width_oct, h.lo_hz, h.hi_hz, h.q,
    h.source == "room" and "room" or
    (h.source == "source" and "source/mic" or "unattributed"))
end

return M
