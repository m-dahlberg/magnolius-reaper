-- @noindex
-- Adaptive De-Click -- parameter defaults and persistence.
--
-- Pure Lua beyond the load/save helpers, so autothresh and log can be
-- exercised headlessly.
--
-- The split that matters is ANALYSIS vs DETECT. Analysis parameters decide the
-- per-band step-peak envelopes, which are what the accessor pass produces and
-- what everything downstream reads; changing one invalidates the cache and
-- costs a re-read of the file. Detect parameters are pure functions of those
-- envelopes, so changing one is a ~50 ms kernel call and the panel stays live.

local M = {}

M.EXT_SECTION = "adaptive_declick"
M.VERSION = 2

-- Settings persist, so changing a default does nothing on an existing install:
-- load() reads ExtState back over the top of it. MIGRATIONS names, per version,
-- the stored keys to drop so the new default takes. Only keys whose default
-- actually moved are listed -- anything the user tuned that we did not change
-- survives untouched.
M.MIGRATIONS = {
  -- v2: the analysed span used to stop at 9.6 kHz, which is below where mouth
  -- clicks live. Measured on a real take, a click carrying 19 dB of contrast
  -- at 9.6-13 kHz and 16.5 dB at 13-17 kHz reached the detector as 6.5 dB in a
  -- single band: the only band that could see it was 6.8-9.6 kHz, and the
  -- detection bandpass is double width, so its skirt reached down into
  -- 2.4-4.8 kHz where the same click sits 12 dB BELOW the voice masking it.
  -- Widening the span to 20 kHz at 16 bands took that click to 12.0 dB against
  -- a 8.9 dB derived threshold, while the file's total detections went 35 ->
  -- 49 -- against 67 for the alternative of dropping the threshold 2 dB.
  [2] = { "fhi", "nbands", "det_hi_hz" },
}

-- Changing any of these changes the envelopes, so the audio must be re-read.
M.ANALYSIS_KEYS = { "step_ms", "nbands", "flo", "fhi", "nphases", "ignore_time_selection" }

-- Changing any of these changes detection but not the envelopes.
--
-- Three are excluded deliberately, for one reason: the overshoot histogram is
-- derived independently of them, so moving them must not force it to be
-- rebuilt. sens_db is the threshold the histogram exists to place. min_reach_hz
-- and max_event_ms are filters applied OVER the surveyed population rather than
-- part of what defines it -- see survey_cfg in detect.lua for what goes wrong
-- when they are allowed into the survey.
M.DETECT_KEYS = {
  "sep", "max_steps", "crackle_db", "xfade_ms", "max_cut_db", "sens_floor_db",
  "det_lo_hz", "det_hi_hz", "skip_silence",
}

M.defaults = {
  -- A time selection narrows what is analysed and what is written; this overrides that back
  -- to the whole item without making you clear the selection. In ANALYSIS_KEYS because it
  -- changes which samples get read.
  ignore_time_selection = false,

  -- Analysis (JSFX sliders 4, 8, 9, 10; "passes" reinterpreted) --------------
  step_ms       = 5,      -- step-peak envelope resolution
  nbands        = 16,     -- log-spaced detection bands
  flo           = 150,    -- lowest band edge, Hz
  -- Not the plugin's 9600. A mouth click's energy peaks well above a voice's,
  -- and the voice falls away fastest exactly where the click does not, so the
  -- top of the span is where the contrast is -- see MIGRATIONS[2]. 20 kHz is
  -- under 0.47*srate for any rate from 44.1 kHz up; below that the kernel
  -- clamps the top band centres and they stop being distinct.
  fhi           = 20000,  -- highest band edge, Hz
  nphases       = 2,      -- staggered step grids analysed in parallel

  -- Threshold ---------------------------------------------------------------
  -- The spec's "find the gap": the sensitivity threshold is derived from the
  -- file's own overshoot distribution rather than dialled in.
  thresh_auto   = true,
  sens_db       = 6.0,    -- used when thresh_auto is off (the JSFX default)
  sens_offset_db = 0.0,   -- bias on the derived value. THE tuning knob.
  sens_floor_db = 1.0,    -- analysis floor: low enough to emit every candidate
  -- Candidates from passages that hold no audio -- stripped pauses, a hard
  -- gate, a 16-bit master's dither -- never survive a threshold, but they do
  -- dilute the distribution the threshold is READ off, and always towards a
  -- more aggressive setting. See dc/silence.lua. Off is for diagnosis.
  skip_silence  = true,
  sweep_min_db  = 2.0,    -- knee search bounds
  sweep_max_db  = 30.0,
  tail_factor   = 3.0,    -- excess over the fitted taper marking the crossover

  -- Detection (JSFX sliders 5, 6, 7) ----------------------------------------
  max_steps     = 2,      -- hard cap on click length, in steps
  sep           = 3,      -- min time between clicks, in steps

  -- Longest an event may last and still be called a click, measured in the
  -- band that carried it. 0 disables it, which is the DEFAULT, and the reason
  -- is worth writing down because the control is easy to over-trust.
  --
  -- It covers an axis max_steps and sep genuinely do not. max_steps caps the
  -- width of the click; sep asks for quiet within +-(sep + sep/3) steps, which
  -- at the default is only +-20 ms -- short enough that a fluctuation inside a
  -- fricative still reads as a peak with quiet on both sides. Measured on a
  -- real take, raising sep from 3 to 6 did not thin the long population at all
  -- and at 8 the candidate set collapsed to a single detection.
  --
  -- What could NOT be shown is that it helps on real vocal material. On both
  -- test takes a 25 ms cap removed 0-2 detections out of 49 and 268: with the
  -- background-referenced floor the test needs to be fair to low-overshoot
  -- events, almost nothing measures as sustained. Replacing the contiguous run
  -- with an occupancy count over +-200 ms did fire, but removed events at
  -- 18 dB and over at the same rate as the rest (selectivity 1.0-1.1x), which
  -- is a filter that is not distinguishing anything.
  --
  -- So it ships off. selftest_in_reaper proves the mechanism does what it says
  -- on a signal built to need it; whether a given take needs it is a question
  -- for the take, and Dry run with take markers is how to answer it.
  max_event_ms  = 0,
  crackle_db    = -45,    -- dense-click (crackle) threshold

  -- Which of the analysed bands detection actually listens to. The band
  -- LAYOUT above decides the envelopes and so costs a re-read to change; this
  -- only selects among them, so it is live -- which is what makes it usable as
  -- a tuning control rather than a setting.
  --
  -- Mouth clicks are short broadband bursts with most of their energy well
  -- above the voice's fundamental. Plosives and vowel onsets carry real
  -- low-mid energy, so lifting det_lo_hz is what stops them being detected.
  det_lo_hz     = 150,
  det_hi_hz     = 20000,

  -- How high the event's RESIDUAL -- what repair would remove -- must still
  -- stand over its own background for the event to count as a click. 0 is off.
  --
  -- This is not det_hi_hz, and it is not a level. Every band is measured
  -- against its own local background, so the voice underneath divides out and
  -- what is left is the spectrum of the thing being removed. A mouth click is
  -- a step discontinuity: flat, and still plainly there at the top of the
  -- spectrum. A plosive or a vowel onset is a low-frequency event with nothing
  -- up there at all -- which is exactly what the two look like in an isolate
  -- render, and it is why measuring absolute band levels finds nothing: those
  -- are dominated by the voice and read the same for both.
  --
  -- Measured on the two test takes, the highest frequency at which the
  -- residual still clears 6 dB is sharply bimodal: 31% of detections stop
  -- below 1.5 kHz, 49% run past 10 kHz, and 6% land in between. 3000 sits in
  -- that empty valley. On the take this was tuned against it drops 17 of 49
  -- detections, and an independent measure agrees the dropped ones are the
  -- long ones: median high-passed transient width 3.5 ms against 1.5 ms for
  -- the ones it keeps.
  min_reach_hz  = 3000,

  -- Repair (JSFX slider 11, plus the spec's bounded-damage guards) -----------
  xfade_ms      = 5,      -- crossfade widen on each repair
  max_cut_db    = 24,     -- clamp on cut depth, magnitude in dB
  use_budget    = true,
  -- % of steps carrying any cut before we back off. NOT the spec's 0.3: that
  -- figure was written for a sample-level interpolation metric, where the
  -- repaired fraction is the audio actually replaced. Here a "cut step" is
  -- 5 ms of gently ducked band energy, and the crossfade widens every repair,
  -- so one click occupies about two steps -- the same amount of intervention
  -- measures 20-40x larger. Measured on real vocal material: the plugin's own
  -- 6 dB default lands at 1.8-8.1%, and a derived threshold at 3.9% and 0.8%.
  -- 10 leaves all of those alone and still catches a runaway by a wide margin
  -- (a threshold collapse saturates this at ~100%).
  repair_budget_pct = 10.0,
  max_retries   = 3,
  db_step_on_retry = 2.0,

  -- Workflow ----------------------------------------------------------------
  isolate       = false,  -- render the difference instead of the repair
  dry_run       = false,  -- detect and mark, write no audio
  place_take_markers = true,
  write_log     = true,

  -- Output ------------------------------------------------------------------
  new_take      = true,
  select_take   = true,
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- In place, because the panel holds one cfg table as an upvalue and hands it to
-- the kernel and the render -- swapping the table would leave those pointing at
-- the old one. Keys the panel added for itself go too, so a reset really is the
-- state a fresh install starts in.
function M.reset(cfg)
  local extra = {}
  for k in pairs(cfg) do
    if M.defaults[k] == nil then extra[#extra + 1] = k end
  end
  for _, k in ipairs(extra) do
    cfg[k] = nil
    if reaper then reaper.DeleteExtState(M.EXT_SECTION, k, true) end
  end
  for k, v in pairs(M.defaults) do cfg[k] = v end
  M.save(cfg)
  return cfg
end

local function signature(cfg, keys)
  local t = {}
  for i, k in ipairs(keys) do t[i] = tostring(cfg[k]) end
  return table.concat(t, "|")
end

function M.analysis_sig(cfg) return signature(cfg, M.ANALYSIS_KEYS) end
function M.detect_sig(cfg)   return signature(cfg, M.DETECT_KEYS)   end

-- Step size in samples, and the derived quantities the kernel and the panel
-- both need. Kept here so no two callers can disagree about them.
-- The band layout, matching the kernel's exactly: nbands log-spaced bands
-- between flo and fhi, each band's centre the geometric mean of its edges.
-- Kept here, in pure Lua, so the panel can label a band without the kernel and
-- the two cannot drift apart.
function M.band_edges(cfg)
  local flo = math.min(cfg.flo, cfg.fhi)
  local fhi = math.max(cfg.flo, cfg.fhi)
  return flo, fhi, math.max(1, math.floor(cfg.nbands + 0.5))
end

function M.band_center(cfg, b)
  local flo, fhi, nb = M.band_edges(cfg)
  if fhi <= flo * 1.001 then return flo end
  local fb = flo * (fhi / flo) ^ (b / nb)
  local ft = flo * (fhi / flo) ^ ((b + 1) / nb)
  return math.sqrt(fb * ft)
end

-- Hz -> inclusive band index range. Clamped into the analysed span, because a
-- range outside it would silently select no bands and detect nothing at all,
-- which is indistinguishable from "this file is clean".
function M.band_range(cfg)
  local flo, fhi, nb = M.band_edges(cfg)
  if fhi <= flo * 1.001 then return 0, nb - 1 end
  local function idx(hz)
    if hz <= flo then return 0 end
    if hz >= fhi then return nb - 1 end
    local i = math.floor(math.log(hz / flo) / math.log(fhi / flo) * nb)
    return math.max(0, math.min(nb - 1, i))
  end
  local lo_hz = math.min(cfg.det_lo_hz, cfg.det_hi_hz)
  local hi_hz = math.max(cfg.det_lo_hz, cfg.det_hi_hz)
  local b0, b1 = idx(lo_hz), idx(hi_hz)
  if b1 < b0 then b1 = b0 end
  return b0, b1
end

-- Band index at or above which the residual must still stand over background,
-- or -1 when the test is off. Clamped into the analysed span: a value above
-- fhi would qualify no band at all and so reject every event, which in the
-- panel is indistinguishable from "this file is clean".
function M.reach_band(cfg)
  local hz = cfg.min_reach_hz or 0
  if hz <= 0 then return -1 end
  local flo, fhi, nb = M.band_edges(cfg)
  if fhi <= flo * 1.001 or hz <= flo then return 0 end
  if hz >= fhi then return nb - 1 end
  local i = math.floor(math.log(hz / flo) / math.log(fhi / flo) * nb)
  return math.max(0, math.min(nb - 1, i))
end

function M.step_samples(cfg, srate)
  return math.max(1, math.floor(srate * cfg.step_ms * 0.001 + 0.5))
end

function M.nsteps(cfg, srate, total_samples)
  return math.floor(total_samples / M.step_samples(cfg, srate)) + 2
end

-- Doubles the kernel must allocate for a take of this length. The envelope
-- cache dominates everything else, and on a long stereo take at 30 bands it is
-- large enough to be worth refusing up front rather than discovering mid-run.
function M.heap_doubles(cfg, srate, total_samples, nchan)
  local ns = M.nsteps(cfg, srate, total_samples)
  local nb, np = cfg.nbands, cfg.nphases
  return ns * (nb * np * nchan     -- step peaks
             + np * nchan          -- broadband, for the crackle test
             + nb * nchan)         -- gain envelopes
end

-- Persistence ----------------------------------------------------------------
-- Values round-trip through ExtState as strings; the type is recovered from the
-- default, so an absent or corrupt key falls back rather than erroring.

-- Kept outside cfg so save() cannot round-trip it as an ordinary setting and
-- reset() cannot mistake it for a key the panel added.
local VERSION_KEY = "__cfg_version"

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
  end
  reaper.SetExtState(M.EXT_SECTION, VERSION_KEY, tostring(M.VERSION), true)
end

-- Drop the stored values for every key whose default moved since the version
-- this install last wrote. An install that predates the version key reads as
-- 1, and a fresh one has nothing to delete, so both land on the defaults.
-- Returns the keys actually dropped, so a caller can say what it changed.
function M.migrate()
  if not reaper then return {} end
  local from = tonumber(reaper.GetExtState(M.EXT_SECTION, VERSION_KEY)) or 1
  local dropped = {}
  if from < M.VERSION then
    for v = from + 1, M.VERSION do
      for _, k in ipairs(M.MIGRATIONS[v] or {}) do
        if reaper.HasExtState(M.EXT_SECTION, k) then
          reaper.DeleteExtState(M.EXT_SECTION, k, true)
          dropped[#dropped + 1] = k
        end
      end
    end
    reaper.SetExtState(M.EXT_SECTION, VERSION_KEY, tostring(M.VERSION), true)
  end
  return dropped
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  M.migrated = M.migrate()
  for k, default in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      local s = reaper.GetExtState(M.EXT_SECTION, k)
      if type(default) == "number" then
        cfg[k] = tonumber(s) or default
      elseif type(default) == "boolean" then
        cfg[k] = (s == "true")
      else
        cfg[k] = s
      end
    end
  end
  return cfg
end

return M
