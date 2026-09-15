-- @noindex
-- AutoTilt -- stage 2: the level-bucketed cube reduced to one balance figure.
--
-- Pure Lua. Nothing here imports reaper, so the whole measurement is testable
-- against synthetic spectra with analytically known answers.
--
-- The one fact that makes the design work: the kernel hands up a cube of power
-- spectra bucketed by frame level, and every remaining choice -- where the
-- gate sits, where the band ends, where the pivot is -- is a choice made over
-- that cube rather than over the audio. `build` turns the cube into
-- cumulative-from-the-top rows *once*, so selecting a gate afterwards is an
-- array lookup rather than a sum over sixty rows, and dragging the pivot costs
-- one pass over 2049 bins. That is what makes the pivot a control you drag.

local Config = require "at.config"

local M = {}

M.FLOOR_DB = -120

-- Cube in, analysis record out.
--
--   rows[lev]   1-based power spectrum for frames in bucket lev, as the kernel
--               hands it back; absent for an empty bucket
--   counts[lev] frames in bucket lev
--
-- Returns cumulative rows: cum[lev][bin] is the power summed over every bucket
-- at or above lev, 0-based in bin, and cumN[lev] the frames behind it. Only
-- occupied levels get an entry, because a real take fills sixty of the
-- hundred and twenty-seven and the empty ones would cost more than the sums.
function M.build(rows, counts, nbins, nlev, lev0)
  local lev_min, lev_max
  for lev = 0, nlev - 1 do
    if (counts[lev] or 0) > 0 then
      lev_min = lev_min or lev
      lev_max = lev
    end
  end

  local ana = {
    nbins = nbins, nlev = nlev, lev0 = lev0,
    counts = counts, cum = {}, cumN = {},
    lev_min = lev_min, lev_max = lev_max, frames = 0,
  }
  if not lev_min then return ana end

  -- Walk down from the top so each row is the one above it plus this bucket.
  local acc = {}
  for k = 0, nbins - 1 do acc[k] = 0 end
  local accN = 0
  for lev = lev_max, lev_min, -1 do
    local r = rows[lev]
    if r then
      for k = 0, nbins - 1 do acc[k] = acc[k] + (r[k + 1] or 0) end
    end
    accN = accN + (counts[lev] or 0)
    local copy = {}
    for k = 0, nbins - 1 do copy[k] = acc[k] end
    ana.cum[lev] = copy
    ana.cumN[lev] = accN
  end
  ana.frames = accN
  return ana
end

-- The bucket exceeded by (100 - pct)% of frames -- the clip's own "loud".
--
-- Taken from the top rather than from the middle, which is what makes it
-- survive a clip that is mostly silence: the loudest 5% of frames of a take
-- with one word in it are still inside that word.
function M.loud_level(ana, pct)
  if not ana.lev_max then return nil end
  local want = ana.frames * (1 - (pct or 95) / 100)
  if want < 1 then want = 1 end
  local found = ana.lev_min
  for lev = ana.lev_max, ana.lev_min, -1 do
    if ana.cumN[lev] >= want then found = lev break end
  end
  return found
end

-- Bucket index -> the dB level it represents.
function M.level_db(ana, lev) return lev + ana.lev0 end

-- Which bucket the gate falls on, and the absolute dB it sits at.
function M.gate_level(ana, cfg)
  local loud = M.loud_level(ana, cfg.gate_pct)
  if not loud then return nil, nil end
  local g = loud - math.floor((cfg.gate_db or 30) + 0.5)
  if g < ana.lev_min then g = ana.lev_min end
  if g > ana.lev_max then g = ana.lev_max end
  return g, M.level_db(ana, g)
end

-- The gated mean power spectrum, 0-based in bin. Mean rather than sum so two
-- clips of different lengths are directly comparable in the plot; the ratio
-- itself would not care either way.
function M.gated(ana, cfg)
  local g = M.gate_level(ana, cfg)
  if not g then return nil, 0, 0 end
  local cum, n = ana.cum[g], ana.cumN[g]
  if not cum or n < 1 then return nil, 0, ana.frames end
  local spec = {}
  for k = 0, ana.nbins - 1 do spec[k] = cum[k] / n end
  return spec, n, ana.frames
end

-- The measured band: which bins are in it, which side of the pivot each falls
-- on, and the octave span of each half.
--
-- The two halves are compared as energy PER OCTAVE -- each side's power sum
-- divided by its own log-frequency span. Two things follow, and both matter:
-- pink noise reads exactly 0.00 rather than the +0.3 dB the raw sums give for
-- a band that is 3.6 octaves below the pivot and 4.0 above; and the reading
-- stops moving when the band edges do, so a reference ratio captured at
-- 80-16000 still means the same thing at 100-12000.
--
-- Note what is NOT here: a per-bin 1/f weight. On a linear bin grid the plain
-- sum already IS the band's energy, so dividing by f would not make octaves
-- count equally -- it would tilt the measurement a second 3 dB per octave
-- toward the bass, and pink material would read -11 dB instead of 0.
--
-- Bin 0 is never included: it carries the frame's mean, which is an offset
-- rather than a tone.
function M.band(cfg, rate, fft_size)
  local lo, hi = Config.band_bins(cfg, rate, fft_size)
  local side, hz = {}, {}
  local piv = cfg.pivot_hz
  for k = lo, hi do
    local f = Config.bin_hz(k, rate, fft_size)
    hz[k] = f
    side[k] = (f < piv) and "lo" or "hi"
  end

  -- The spans are taken between BIN EDGES, not bin centres, and the split at
  -- the edge of the first bin that lands above the pivot -- because that is
  -- what the sums above actually cover. Using the centres instead leaves a
  -- half-bin of the band unaccounted for at each boundary, which showed up as
  -- pink material reading -0.13 dB instead of 0.00 and drifting with the band
  -- edges. Both sides share the bin width, so it cancels in the ratio.
  local function edge(k) return (k - 0.5) * rate / fft_size end
  local split = hi + 1
  for k = lo, hi do
    if side[k] == "hi" then split = k break end
  end

  local lo_hz = Config.bin_hz(lo, rate, fft_size)
  local hi_hz = Config.bin_hz(hi, rate, fft_size)
  local b = {
    lo = lo, hi = hi, side = side, hz = hz,
    lo_hz = lo_hz, hi_hz = hi_hz, pivot = piv,
    lo_edge = edge(lo), hi_edge = edge(hi + 1), split_edge = edge(split),
    span_lo = math.log(edge(split) / edge(lo)),
    span_hi = math.log(edge(hi + 1) / edge(split)),
  }
  -- A pivot dragged onto or past an edge leaves one side with no octaves in
  -- it. Refusing here, by name, beats dividing by zero and reporting inf.
  if b.span_lo <= 0 or b.span_hi <= 0 then
    b.degenerate = "The pivot is outside the measured band."
  end
  return b
end

-- The balance figure: 10*log10(high / low) in energy per octave. Pink-flat
-- reads 0.0.
--
-- `curve` is an optional per-bin power gain -- the shelf pair's |H|^2 -- which
-- is how the solver asks "what would this read after a tilt of G".
function M.ratio(spec, b, curve)
  if not spec or b.degenerate then return nil end
  local low, high = 0, 0
  for k = b.lo, b.hi do
    local p = spec[k]
    if curve then p = p * curve[k] end
    if b.side[k] == "lo" then low = low + p else high = high + p end
  end
  low  = low  / b.span_lo
  high = high / b.span_hi
  if low <= 0 or high <= 0 then return nil, low, high end
  return 10 * math.log(high / low, 10), low, high
end

-- Unweighted band-limited power, which is what level compensation holds
-- constant. The per-octave normalisation is right for the tone question and
-- wrong for the level question: the makeup gain has to answer "how much did
-- the actual energy change", which is the raw sum.
function M.band_power(spec, b, curve)
  if not spec then return 0 end
  local p = 0
  for k = b.lo, b.hi do
    local v = spec[k]
    if curve then v = v * curve[k] end
    p = p + v
  end
  return p
end

-- A 1/n-octave average for the plot, in dB per octave, so the drawn curve and
-- the reported number are the same measurement at different resolutions.
function M.octave_curve(spec, b, per_oct)
  if not spec then return {} end
  local step = math.log(2) / (per_oct or 6)
  local out = {}
  local u0 = math.log(b.lo_hz)
  local u1 = math.log(b.hi_hz)
  local nb = math.max(1, math.floor((u1 - u0) / step + 0.5))
  local acc, cnt, cur = 0, 0, 0
  for k = b.lo, b.hi do
    local i = math.floor((math.log(b.hz[k]) - u0) / step)
    if i > cur then
      if cnt > 0 then
        out[#out + 1] = {
          hz = math.exp(u0 + (cur + 0.5) * step),
          db = 10 * math.log(math.max(acc / cnt, 1e-30), 10),
        }
      end
      acc, cnt, cur = 0, 0, i
    end
    acc = acc + spec[k]
    cnt = cnt + 1
  end
  if cnt > 0 then
    out[#out + 1] = {
      hz = math.exp(u0 + (cur + 0.5) * step),
      db = 10 * math.log(math.max(acc / cnt, 1e-30), 10),
    }
  end
  out.nbands = nb
  return out
end

-- Everything the panel shows about one clip, in one call.
function M.measure(ana, cfg, rate, fft_size)
  local out = { frames = ana and ana.frames or 0 }
  if not ana or not ana.lev_max then
    out.err = "no frames"
    return out
  end
  local g, gdb = M.gate_level(ana, cfg)
  out.gate_lev, out.gate_db_abs = g, gdb
  local loud = M.loud_level(ana, cfg.gate_pct)
  out.loud_db = loud and M.level_db(ana, loud) or nil

  local spec, kept, total = M.gated(ana, cfg)
  out.spec, out.kept, out.total = spec, kept, total
  if not spec then
    out.err = "no frames above the gate"
    return out
  end

  local b = M.band(cfg, rate, fft_size)
  out.band = b
  if b.degenerate then
    out.err = b.degenerate
    return out
  end
  local r, low, high = M.ratio(spec, b)
  out.ratio, out.low, out.high = r, low, high
  if not r then
    out.err = "No energy on one side of the pivot."
  end
  return out
end

return M
