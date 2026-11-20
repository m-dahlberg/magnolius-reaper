-- @noindex
-- Loudness Envelope -- parameter defaults, persistence and parameter classes.
--
-- Pure Lua apart from the load/save helpers, which are guarded, so the curve
-- stages can be exercised headlessly.
--
-- The one fact the panel's responsiveness rests on: the audio is read ONCE,
-- into a 10 ms energy table, and every control below -- even the detector
-- window -- re-derives the curve from that table. Only the source (which
-- track, which items, whether the time selection limits it) costs a re-read.

local Trackpick = require "le.trackpick"

local M = {}

M.EXT_SECTION = "magnolius_loudness_envelope"

-- The Vocal Rider's Target level slider spans -40..0 dB. A point outside that
-- range would be clamped by REAPER anyway; clamping here means the plot shows
-- what will actually be written.
M.TARGET_MIN = -40
M.TARGET_MAX = 0

-- The kernel's frame hop and the curve's output grid. Constants rather than
-- settings: 10 ms is fine enough to run the rider's 50 ms detector on, and a
-- 50 ms grid is far finer than any outline this script exists to draw.
M.FRAME_S = 0.010
M.GRID_S  = 0.050

M.defaults = {
  -- Source --------------------------------------------------------------------
  -- Off: every audio item on the source track. On: only what lies inside the
  -- time selection, so one chorus can be outlined without touching the rest of
  -- the lane.
  use_timesel = false,

  -- Measurement -- in the rider's own scale -----------------------------------
  -- The rider measures max(L^2, R^2) through a one-pole of this time constant
  -- (its "Vocal loudness window", default 50 ms). The curve is a TARGET for
  -- that detector, so it has to be in the detector's units: same squares, same
  -- smoothing. Match this to the rider's slider if you have moved it.
  detector_ms = 50,
  -- Frames below this are not singing. -50 is the rider's own Noise floor
  -- default, below which it stops riding.
  gate_abs_db = -50,
  -- And frames more than this far below the take's typical sung level are
  -- breaths, tails and room tone, however loud the room is.
  gate_rel_db = 20,

  -- Outline -------------------------------------------------------------------
  -- The sliding median's width. This is what removes syllables: a median over
  -- two seconds of singing does not move for a loud vowel or a soft
  -- consonant, it moves when the whole phrase gets louder.
  outline_s = 2.0,
  -- Gaussian sigma of the zero-phase smoothing that follows. It rounds the
  -- median's steps into slopes and carries a phrase's level a little way into
  -- the gaps either side of it.
  smooth_s = 1.0,

  -- Range ---------------------------------------------------------------------
  -- How much of the measured movement to keep, around the curve's median.
  -- 100% is the source as measured; 50% half of its phrase-to-phrase
  -- movement; 0% a flat line at the median.
  depth_pct = 100,
  -- The most the curve may depart from its median, either way, after depth.
  range_db = 6,
  -- Added to everything. The curve is the source's ABSOLUTE level; use this
  -- when the destination's chain puts the rider at a different level than the
  -- raw source was measured at.
  offset_db = 0,

  -- Output --------------------------------------------------------------------
  -- Ramer-Douglas-Peucker tolerance: the most any written point may let the
  -- envelope drift from the computed curve.
  tolerance_db = 0.1,
}

-- The destination track, as the shared trackpick widget stores it.
for k, v in pairs(Trackpick.defaults("dest")) do M.defaults[k] = v end

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- In place, because the panel holds one cfg table as an upvalue.
function M.reset(cfg)
  for k in pairs(cfg) do
    if M.defaults[k] == nil then cfg[k] = nil end
  end
  for k, v in pairs(M.defaults) do cfg[k] = v end
  M.save(cfg)
  return cfg
end

-- Parameter classes -----------------------------------------------------------
--
-- ANALYSIS changes which samples get read, so it throws away the frame table.
-- CURVE re-derives the curve from frames in memory. OUTPUT changes only what
-- gets written (and where). The destination is OUTPUT: picking a different
-- track must never cost a re-read of the source.

M.ANALYSIS_KEYS = { "use_timesel" }
M.CURVE_KEYS    = { "detector_ms", "gate_abs_db", "gate_rel_db",
                    "outline_s", "smooth_s",
                    "depth_pct", "range_db", "offset_db", "tolerance_db" }
M.OUTPUT_KEYS   = Trackpick.sig_keys("dest")

local function signature(cfg, keys)
  local t = {}
  for i, k in ipairs(keys) do t[i] = tostring(cfg[k]) end
  return table.concat(t, "|")
end

function M.analysis_sig(cfg) return signature(cfg, M.ANALYSIS_KEYS) end
function M.curve_sig(cfg)    return signature(cfg, M.CURVE_KEYS)    end

-- The kernel's memory map is fixed by the channel count, and its frame length
-- by the rate, so either changing means a new kernel.
function M.kernel_sig(nchan, rate)
  return string.format("%d|%.6f", nchan, rate)
end

-- Persistence -----------------------------------------------------------------
-- Values round-trip through ExtState as strings; the type is recovered from
-- the default, so an absent or corrupt key falls back rather than erroring.

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    if M.defaults[k] ~= nil then
      reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
    end
  end
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
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
