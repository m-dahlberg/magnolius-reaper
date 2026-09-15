-- @noindex
-- T60 read out of the decay cube.
--
-- The ring figure is the fastest decay a band ever achieves, and `dr/auto.lua`
-- turns it into a T60 through a power law because the two are not
-- proportional. That law is calibrated, but it is a calibration of a PROXY,
-- and the proxy saturates: measured over combs of known decay, a 10.7x range
-- of real T60 arrives as a 2.3x range of ring figure. The reason is that the
-- statistic takes the fastest decay, and in a live room the singer stops
-- faster than the room does -- so above about 0.5 s it is measuring the voice.
--
-- The decay cube measures T60 directly instead, conditioned on the voice
-- having stopped, which is the one condition that removes the singer from the
-- statistic. Against the same combs (test/t60_calib_in_reaper.lua):
--
--   known T60   0.30   0.60   1.00   1.50
--   ring law    0.29   0.55   1.02   1.25     (27 % worst error, saturating)
--   decay cube  0.30   0.61   1.09   1.61     (7 % worst error)
--
-- What it cannot do is work without pauses. Each fit needs a pause of at least
-- EDCMINQ frames in which the band falls 8 dB, and a take with few pauses
-- gives few fits -- so the median is refused below `edc_min_gaps` and the ring
-- law is used instead. That refusal is the whole reason both estimators are
-- kept.
--
-- Pure Lua: imports no `reaper`.

local M = {}

-- A band's T60 is the median of the fits it collected, not their mean: a pause
-- that held a breath, a chair or a distant door produces one wrong fit, and a
-- median absorbs it where a mean carries it.
function M.t60_from_hist(hist, cfg, time_of)
  local total = 0
  for i = 1, #hist do total = total + hist[i] end
  if total < (cfg.edc_min_gaps or 6) then return nil, total end
  local want, run = 0.5 * total, 0
  for i = 1, #hist do
    run = run + hist[i]
    if run >= want then return time_of(i - 1), total end
  end
  return time_of(#hist - 1), total
end

-- Every band at once. Returns the per-band times, the per-band fit counts, and
-- how many bands produced a figure.
function M.run(hists, cfg, time_of, nband)
  local times, counts, n = {}, {}, 0
  for b = 1, nband do
    times[b], counts[b] = M.t60_from_hist(hists[b], cfg, time_of)
    if times[b] then n = n + 1 end
  end
  return times, counts, n
end

-- The median across the bands that produced one. This is a T60 in seconds, not
-- a relative figure, and unlike the ring figure it can be read as one.
function M.median(times, nband)
  local all = {}
  for b = 1, nband do if times[b] then all[#all + 1] = times[b] end end
  table.sort(all)
  if #all == 0 then return nil, 0 end
  return all[math.max(1, math.floor(0.5 * #all))], #all
end

return M
