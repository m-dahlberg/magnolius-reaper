-- @noindex
-- Adaptive De-Click -- stage 2: turn the envelope cache into a repair plan.
--
-- Two kernel calls with a decision between them.
--
--   survey  detect at a deliberately low floor, so nearly every candidate is
--           emitted, and keep the histogram of their overshoots. This is the
--           distribution the threshold is read off, and it does not depend on
--           the threshold -- so it survives every move of the sensitivity
--           control and only has to be rebuilt when a detection parameter
--           other than sensitivity changes.
--
--   commit  detect for real at the derived threshold. This one is
--           authoritative: it builds the gain envelopes the render applies,
--           the event list, and the tallies the panel draws.
--
-- The caveat worth stating: lowering the threshold also lowers det_thresh
-- (= sqrt of it), which moves the per-band boundary bar, so the surveyed
-- population is not exactly the population that would be found at each higher
-- threshold. It is close, and monotone, which is all that placing a threshold
-- in a gap requires. The committed count is the real one, and the panel shows
-- it next to the histogram rather than a count read off the curve.

local AutoThresh = require "dc.autothresh"
local Silence    = require "dc.silence"

local M = {}

-- The survey must see the WHOLE candidate population, because the threshold is
-- read off the shape of it: the taper is the transient population and the gap
-- is where that population ends. The reach and event-length tests exist to
-- remove exactly that population, by a different axis -- so leaving them on
-- during the survey empties the histogram of the very thing the estimators fit.
--
-- Measured on a real take with the reach test at 3 kHz: the survey fell from
-- 9308 candidates to 86, both estimators reported no gap, and the 98th
-- percentile fallback landed at 18.9 dB and committed nothing. The panel said
-- "no gap found", which was true and entirely misleading -- there was no gap
-- because the filter had already done the separating.
--
-- So they are applied at commit and not at survey. This is the same reason
-- sens_db is excluded from DETECT_KEYS: they are filters OVER the surveyed
-- population, not part of what defines it, and moving them must not force the
-- histogram to be rebuilt.
local function survey_cfg(cfg)
  local c = {}
  for key, v in pairs(cfg) do c[key] = v end
  c.min_reach_hz, c.max_event_ms = 0, 0
  return c
end

-- Detect at the analysis floor and keep the overshoot distribution.
--
-- Twice, and the second pass is the one that counts. Overshoot is a ratio
-- against a candidate's own local background, so a passage holding no audio at
-- all still produces candidates -- the dither fluctuating against itself. They
-- never survive a threshold, but they dilute the distribution the threshold is
-- READ off, and `tail_departure` anchors its fit on percentiles of exactly
-- that distribution. See dc/silence.lua for the measured drift.
--
-- The first pass runs with no absolute floor and fills the level histogram;
-- Silence.floor reads the floor off it; the second re-surveys with it. Both
-- are kernel calls over the cached envelopes, not re-reads of the take, which
-- is the whole reason a second pass costs nothing worth mentioning.
function M.survey(k, cfg)
  local sc = survey_cfg(cfg)
  local stats = k:detect(sc, cfg.sens_floor_db)

  local sil
  if cfg.skip_silence ~= false then
    sil = Silence.floor(k:level_histogram())
    if sil.floor_db then
      stats = k:detect(sc, cfg.sens_floor_db, sil.floor_db)
    end
  end

  local hist = k:histogram()
  hist.truncated = stats.events > stats.kept
  hist.events = stats.events
  hist.silence = sil
  return hist
end

-- Derive the threshold, detect at it, and back off if the result would repair
-- more of the file than the budget allows.
--
-- The retry loop is the spec's single most valuable guard, and it is only
-- affordable because re-detection no longer touches audio: each attempt is a
-- kernel call over the cached envelopes, not a re-read of the take.
function M.commit(k, cfg, hist)
  local th
  if cfg.thresh_auto then
    th = AutoThresh.derive(hist, cfg)
  else
    th = { final_db = cfg.sens_db, manual = true }
  end

  local sens = th.final_db
  local budget = cfg.repair_budget_pct / 100
  local retries, stats = 0, nil

  while true do
    stats = k:detect(cfg, sens)
    stats.repaired = stats.nsteps > 0 and (stats.cut_steps / stats.nsteps) or 0
    if not cfg.use_budget or stats.repaired <= budget then break end
    if retries >= cfg.max_retries then
      th.budget_exceeded = true
      break
    end
    retries = retries + 1
    sens = sens + cfg.db_step_on_retry
  end

  th.retries = retries
  th.sens_used = sens
  th.stats = stats
  if retries > 0 then
    th.budget_note = string.format(
      "Repair budget exceeded at %.1f dB; raised to %.1f dB over %d %s.",
      th.final_db, sens, retries, retries == 1 and "retry" or "retries")
  end
  if th.budget_exceeded then
    th.warning = string.format(
      "Still repairing %.2f%% of the file after %d retries (budget %.2f%%). " ..
      "Either this take is genuinely full of clicks or detection is wrong -- " ..
      "audit the markers before applying.",
      stats.repaired * 100, retries, cfg.repair_budget_pct)
  end
  return th
end

return M
