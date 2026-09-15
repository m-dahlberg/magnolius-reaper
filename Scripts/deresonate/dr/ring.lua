-- @noindex
-- The ring test: does this frequency decay slowly?
--
-- A room resonance is defined by RINGING, not by level, and level alone cannot
-- find one. Measured on a real male take: 515.6 Hz stood +10 dB above its
-- neighbours in the long-term average and was nonetheless not a resonance -- it
-- was the third harmonic of a 169.5 Hz fundamental, and its ring index was
-- 0.94, slightly BELOW typical. A candidate has to show both.
--
-- The statistic is the fastest decay a band ever achieves, not a fit to a
-- chosen decay. A ringing band physically *cannot* decay quickly, so its
-- steepest slope is shallow; a band carrying only direct sound can stop dead.
--
-- Why not fit each decay: the obvious method -- find a peak, fit -5..-20 dB --
-- collapses at narrow bandwidth. On the real take it yielded 1-13 usable
-- segments per 1/6-octave band, and 3 at the very band under investigation.
-- The slope percentile uses every frame instead: 6741 samples per bin on the
-- same file, and a stable index across the whole region.
--
-- Pure Lua: imports no `reaper`.

local M = {}

M.MIN_SLOPES = 200   -- below this the percentile is not a statistic

-- Ring time of one band envelope, in seconds.
-- `env` is dB per frame, `dt` the frame period.
function M.ring_time(env, dt, cfg)
  local n = #env
  local w = math.max(1, math.floor((cfg.ring_win_ms / 1000.0) / dt + 0.5))
  if n <= w + 1 then return nil, 0 end

  local sorted = {}
  for i = 1, n do sorted[i] = env[i] end
  table.sort(sorted)
  local floor = sorted[math.max(1, math.floor(0.10 * n))]

  local slopes, ns = {}, 0
  local dtw = w * dt
  for i = 1, n - w do
    local a, b = env[i], env[i + w]
    -- both ends must be clear of the band's own floor, or the "decay" is just
    -- the noise floor being approached
    if a > floor + cfg.ring_head_db and b > floor + 3.0 then
      ns = ns + 1
      slopes[ns] = (b - a) / dtw
    end
  end
  if ns < M.MIN_SLOPES then return nil, ns end
  table.sort(slopes)
  local p = slopes[math.max(1, math.floor((cfg.ring_pct / 100.0) * ns))]
  if not p or p >= 0 then return nil, ns end
  return -60.0 / p, ns
end

-- The kernel form: the same statistic read out of a ring-time histogram
-- instead of an envelope, so nothing proportional to file length is kept.
--
-- Note the direction. The statistic is the FASTEST decay a band achieves --
-- the steepest slope, which is the SHORTEST ring time -- so this is a low
-- percentile of the ring-time axis, walked from the short end. A band that
-- rings cannot produce a short ring time at all, so its whole distribution
-- sits high and the percentile moves with it.
function M.time_from_hist(hist, cfg, time_of)
  local total = 0
  for i = 1, #hist do total = total + hist[i] end
  if total < M.MIN_SLOPES then return nil, total end
  local want, run = (cfg.ring_pct / 100.0) * total, 0
  for i = 1, #hist do
    run = run + hist[i]
    if run >= want then return time_of(i - 1), total end
  end
  return time_of(#hist - 1), total
end

-- Ring index: each band's ring time relative to the median of its neighbours
-- within +-`ring_span_oct` octaves. Relative, because the absolute figure
-- carries the whole room and we are looking for one band standing out of it.
function M.index(times, hz, cfg)
  local out = {}
  for i = 1, #times do
    if times[i] then
      local nb = {}
      for j = 1, #times do
        if times[j] and math.abs(math.log(hz[j] / hz[i], 2)) <= cfg.ring_span_oct then
          nb[#nb + 1] = times[j]
        end
      end
      if #nb > 0 then
        table.sort(nb)
        local med = nb[math.floor((#nb + 1) / 2)]
        out[i] = (med > 0) and (times[i] / med) or nil
      end
    end
  end
  return out
end

-- Convenience: envelopes -> ring times -> indices, in one call.
function M.run(envs, hz, dt, cfg)
  local times, counts = {}, {}
  for i = 1, #envs do
    times[i], counts[i] = M.ring_time(envs[i], dt, cfg)
  end
  return M.index(times, hz, cfg), times, counts
end

return M
