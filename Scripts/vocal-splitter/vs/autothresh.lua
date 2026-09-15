-- @noindex
-- Vocal Splitter -- stage 2: derive thresholds from the material itself.
--
-- Pure Lua. Every function here takes plain tables and returns numbers, so the
-- whole stage is testable without REAPER.

local M = {}

local BIN_LO, BIN_HI = -90, 6   -- dB, 1 dB bins

-- A level histogram serves two purposes: percentiles in O(n) rather than a
-- sort, and the display the UI draws the gate line onto. Vocal material is
-- bimodal -- a noise floor lobe and a signal lobe -- and seeing that split is
-- the fastest way to tell whether a gate value is sane.
function M.histogram(level_db, n)
  local bins, total = {}, 0
  for i = BIN_LO, BIN_HI do bins[i] = 0 end
  for i = 1, n do
    local b = math.floor(level_db[i] + 0.5)
    if b < BIN_LO then b = BIN_LO elseif b > BIN_HI then b = BIN_HI end
    bins[b] = bins[b] + 1
    total = total + 1
  end
  return { bins = bins, total = total, lo = BIN_LO, hi = BIN_HI }
end

function M.percentile(hist, p)
  local want = hist.total * p / 100
  local cum = 0
  for b = hist.lo, hist.hi do
    local c = hist.bins[b]
    if cum + c >= want then
      -- interpolate inside the bin so a coarse histogram still gives a smooth
      -- answer as the slider moves
      local frac = c > 0 and (want - cum) / c or 0
      return b - 0.5 + frac
    end
    cum = cum + c
  end
  return hist.hi
end

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- Gate: sit a margin above the noise floor, but never above gate_max_db --
-- that ceiling is what guarantees room tone and hiss are cut regardless of
-- what the distribution says.
function M.gate(F, cfg)
  local hist = M.histogram(F.level_db, F.n)
  local noise_floor = M.percentile(hist, 10)
  local signal_ref  = M.percentile(hist, 85)

  local auto = noise_floor + cfg.noise_margin_db
  local gate = cfg.gate_auto
    and clamp(auto, cfg.gate_min_db, cfg.gate_max_db)
    or cfg.gate_db

  return {
    hist = hist,
    noise_floor = noise_floor,
    signal_ref = signal_ref,
    gate_auto_db = auto,
    gate_db = gate,
  }
end

-- Sibilance threshold, placed at half the strongest fricative in the file.
--
-- Not a percentile of the mixture: sib_ratio is bimodal (vowels near zero,
-- fricatives near one), so a percentile lands wherever the sibilance
-- *fraction* happens to fall. At a realistic ~9% sibilance the 92nd percentile
-- sits on top of the sibilant lobe itself and nothing clears it. Half the
-- strongest fricative sits in the valley between the lobes no matter how much
-- sibilance the take contains.
--
-- Floored, because on a take with no sibilance at all this would otherwise
-- manufacture detections out of ordinary vowel HF.
function M.sib_threshold(F, gate_db, cfg)
  if not cfg.sib_auto then return cfg.sib_thresh end
  local vals, n = {}, 0
  for i = 1, F.n do
    if F.level_db[i] > gate_db + cfg.sib_level_db then
      n = n + 1
      vals[n] = F.sib_ratio[i]
    end
  end
  if n < 50 then return cfg.sib_thresh end
  table.sort(vals)
  local peak = vals[math.max(1, math.floor(n * 0.99))]
  return math.max(cfg.sib_thresh, peak * 0.5)
end

-- 1-D k-means over log gap duration. Speech and singing group pauses into
-- roughly three families -- within-phrase, phrase, section -- and fitting the
-- boundaries to this performance beats fixed constants that assume a tempo.
local function kmeans3(xs)
  local n = #xs
  if n < 6 then return nil end
  table.sort(xs)
  local c = {
    xs[math.max(1, math.floor(n * 0.17))],
    xs[math.max(1, math.floor(n * 0.50))],
    xs[math.max(1, math.floor(n * 0.83))],
  }
  if c[1] >= c[3] then return nil end   -- degenerate: all gaps alike

  for _ = 1, 30 do
    local sum, cnt = { 0, 0, 0 }, { 0, 0, 0 }
    for i = 1, n do
      local x, best, bd = xs[i], 1, math.huge
      for k = 1, 3 do
        local d = math.abs(x - c[k])
        if d < bd then bd, best = d, k end
      end
      sum[best] = sum[best] + x
      cnt[best] = cnt[best] + 1
    end
    local moved = false
    for k = 1, 3 do
      if cnt[k] > 0 then
        local nc = sum[k] / cnt[k]
        if math.abs(nc - c[k]) > 1e-9 then moved = true end
        c[k] = nc
      end
    end
    if not moved then break end
  end
  table.sort(c)
  return c
end

-- Returns suggested { section_gap_ms, phrase_gap_ms }. Midpoints between
-- adjacent cluster centres in log space become the split durations.
function M.gap_thresholds(gaps, cfg)
  local out = { section_gap_ms = cfg.section_gap_ms,
                phrase_gap_ms  = cfg.phrase_gap_ms }
  if not cfg.gap_auto then return out end

  local xs = {}
  for i = 1, #gaps do
    local d = gaps[i].dur
    if d > 0 then xs[#xs + 1] = math.log(d) end
  end

  local c = kmeans3(xs)
  if not c then return out end

  local phrase_s  = math.exp((c[1] + c[2]) / 2)
  local section_s = math.exp((c[2] + c[3]) / 2)

  out.phrase_gap_ms  = clamp(phrase_s  * 1000, 150, 1200)
  out.section_gap_ms = clamp(section_s * 1000, out.phrase_gap_ms * 1.5, 6000)
  return out
end

M.clamp = clamp
return M
