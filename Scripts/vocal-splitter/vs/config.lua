-- @noindex
-- Vocal Splitter -- parameter defaults and persistence.
--
-- Pure Lua, no reaper dependency beyond the optional load/save helpers, so the
-- detection stages can be exercised headlessly.

local M = {}

M.EXT_SECTION = "vocal_splitter"

-- Settings schema version. Bump it whenever a stored key changes what it
-- *means*, as opposed to what its default is.
--
-- ExtState persists every tunable, so a value saved under the old meaning is
-- reloaded under the new one and silently wins over the new default. That is
-- how this stage arrived: breath_sib_hi went from the upper edge of a graded
-- window -- where 0.0 was a harmless way of saying "score HF content
-- generously" -- to an absolute per-frame ceiling, where 0.0 rejects every
-- frame in the take. Someone who had been widening the sliders trying to make
-- the old detector find anything would upgrade and get zero breaths, from
-- settings that were a reasonable thing to have tried.
M.VERSION = 3
M.VERSION_KEY = "settings_version"

-- The keys each version redefined. Anything stored before that version is not
-- a preference any more, it is a number that used to mean something else, so
-- it is dropped back to the default instead of loaded.
M.migrations = {
  [2] = { "breath_sib_lo", "breath_sib_hi", "breath_rel_lo_db",
          "breath_rel_hi_db", "breath_sensitivity", "breath_voice_max",
          "breath_min_ms", "breath_max_ms", "breath_slope_max_db",
          "cons_closure_drop_db" },
  -- Sibilance and the hard consonants became one scan split by duration, so
  -- sib_min_ms stopped being "the shortest sibilant worth taking" and became
  -- the boundary between the two classes. A stored 25 there does not mean a
  -- shorter minimum any more; it means every hard consonant over 25 ms is
  -- filed as a sibilant.
  [3] = { "sib_min_ms", "sib_level_db", "cons_voice_max", "cons_max_ms",
          "cons_closure_drop_db" },
}

-- Analysis ------------------------------------------------------------------
-- hop is the resolution everything downstream sees. 128 samples is ~2.7 ms at
-- 48 kHz, fine enough to resolve a plosive burst.
M.defaults = {
  -- A time selection narrows what is analysed and where the splits land; this overrides that
  -- back to the whole item without making you clear the selection.
  ignore_time_selection = false,

  hop            = 128,
  max_rate       = 48000,   -- analysis rate ceiling; accessor resamples for free
  min_rate       = 24000,   -- below this sibilance (5-10 kHz) is lost
  block_frames   = 375,     -- block = block_frames * hop samples

  -- 1 kHz, not 500 Hz: a sung or spoken vowel puts F0 and F1 below 500 but
  -- most voices carry real energy in F2 (1-2.5 kHz) too, and a 500 Hz corner
  -- scores an ordinary vowel around 0.06 -- well under voice_thresh. At 1 kHz
  -- a vowel lands at 0.6-0.8 while an /s/ at 7 kHz is still ~0.0005.
  dc_hz          = 20,      -- DC blocker in the kernel, ahead of every
                            -- accumulator so level and the two bands agree
  lo_hz          = 1000,    -- voicing band, lowpass corner
  hi_hz          = 4500,    -- sibilance band, highpass corner
  svf_q          = 0.7071,

  -- Gate ---------------------------------------------------------------------
  gate_auto      = true,
  gate_db        = -35,     -- used when gate_auto is off
  noise_margin_db = 6,      -- auto gate sits this far above the noise floor
  gate_min_db    = -70,
  gate_max_db    = -35,     -- ceiling: guarantees room tone and hiss are cut
  gate_hyst_db   = 3,       -- open this far above the gate, close at it
  env_fast_rel   = 0.010,   -- peak-hold decay, stops mid-syllable dips chattering
  min_silence_ms = 120,
  min_segment_ms = 40,

  -- Hierarchy ----------------------------------------------------------------
  -- Each level can be switched off independently so a single process can be
  -- run and judged on its own. Switching a level off collapses it into one
  -- node spanning its parent, so the reference a lower level measures against
  -- falls back automatically: no phrases -> the section, no sections either
  -- -> the whole file.
  enable_section = true,
  enable_phrase  = true,

  gap_auto       = true,    -- k-means suggestion for the two gap thresholds
  section_gap_ms = 1500,
  phrase_gap_ms  = 350,

  -- Cut placement ------------------------------------------------------------
  tail_guard_ms  = 30,      -- protect decays and reverb tails
  onset_guard_ms = 15,      -- protect plosive closures before a burst
  crossfade_ms   = 20,
  crossfade_min_ms = 2,
  sib_crossfade_ms = 5,     -- sibilance edges are not in a gap

  -- Element detection --------------------------------------------------------
  voice_thresh   = 0.40,    -- voice_ratio above this counts as voiced

  -- Breaths are scanned on the frame features across the whole take, not
  -- classified out of gate segments -- the gate has to sit above room tone by
  -- more than a breath stands above it, so it cannot resolve one.
  --
  -- Detection is scored, not ANDed: the level, HF and steadiness windows below
  -- each grade 0..1 with soft edges and the average must clear
  -- breath_sensitivity. Voicing, HF presence, prominence over the local floor
  -- and duration are the absolute tests. The graded windows are deliberately
  -- wide -- a breath's HF content depends on the mic and the distance, and a
  -- close-mic'd one can sit 8 dB under its phrase.
  breath_sensitivity = 60,  -- 0 = only a textbook breath, 100 = anything unvoiced
  breath_min_ms  = 100,
  breath_max_ms  = 900,
  -- Relative to the singing around the breath, measured locally -- not to
  -- the phrase node, which is the breath itself whenever the gate resolved
  -- one. A distant breath in a long pause really can sit 40 dB down.
  breath_rel_lo_db = -40,
  breath_rel_hi_db = -6,
  breath_sib_lo  = 0.10,
  -- Above this it is a fricative, not a breath. Measured on real material a
  -- breath's high-band fraction runs 0.15-0.25 and an /s/ runs 0.5-0.85, so
  -- the old 0.70 sat on top of the sibilant lobe and scored every /s/ in the
  -- take a perfect 1 for "HF content".
  breath_sib_hi  = 0.45,
  breath_voice_max = 0.45,  -- above this it is a sung note, not a breath
  -- Prominence over local room tone. This, not an absolute level, is what
  -- separates a breath from the room it was recorded in: the room's own floor
  -- moves, and a breath is only a handful of dB above it.
  breath_floor_db = 5,
  breath_join_ms = 40,      -- bridge dropouts: a breath is noise, and noise
                            -- crosses any per-frame test back and forth
  -- The clip has to hold the whole breath or the gain step lands inside it.
  -- Detection finds the core; these two decide how far out of it the extent
  -- reaches, against a looser HF fraction and a smaller margin over the room.
  breath_edge_frac = 0.4,   -- fraction of breath_sib_lo an edge frame must keep
  breath_edge_db  = 2,      -- and how far it must still stand above room tone
  breath_edge_smooth_ms = 16,-- the edge test reads features smoothed this far;
                            -- per-frame they flicker across any threshold
  -- Then each end snaps to the bottom of the valley beside it, which is where
  -- the breath really starts and stops and the quietest place to cut.
  breath_valley_ms = 200,   -- how far out to look for the bottom
  breath_valley_rise_db = 3,-- and how far it may climb back out before giving up
  breath_slope_max_db = 9,
  breath_attack_skip_ms = 15,-- ignore the onset step in the slope test

  -- Shortest run the fricative scan will call an element at all. Below this a
  -- run is noise in the feature, not a sound.
  element_min_ms = 12,

  cons_min_ms    = 5,
  -- Also the boundary against sibilance for a *burst*. The fricative scan uses
  -- sib_min_ms for the same job.
  cons_max_ms    = 100,
  cons_onset_db  = 12,      -- rise over ~10 ms
  -- Above this the onset is a vowel, not a burst. 0.45, not 0.30: a voiced
  -- plosive really is half-voiced through its burst -- the one at 14.25 s
  -- in the test take means 0.31 -- while a vowel onset reads 0.8-1.2, so
  -- there is a wide margin either side of this.
  cons_voice_max = 0.45,
  cons_join_ms   = 15,      -- bridge voiced flicker inside a burst
  cons_closure_ms = 40,     -- window searched for the closure before a burst
  -- The closure must sit this far below the burst peak. 10 dB, not the 15 it
  -- was: that figure was calibrated while the "burst peak" was accidentally
  -- the peak of the following vowel, which is 5-15 dB louder, so the same
  -- physical closure used to measure that much deeper than it is.
  cons_closure_drop_db = 10,

  sib_auto       = true,
  sib_thresh     = 0.45,
  -- The boundary between a hard consonant and a sibilant. One scan finds both
  -- -- four of the nine hard consonants in the test take are fricative
  -- releases with no burst to detect -- and length is what tells them apart:
  -- on that take every hard consonant runs 8-91 ms and every sibilant runs
  -- 117-248 ms.
  sib_min_ms     = 105,
  sib_max_ms     = 300,
  -- A quiet consonant sits only 6 dB over the gate; at 12 the two fricative
  -- releases at 21.46 and 27.69 s were below the bar and invisible.
  sib_level_db   = 6,
  -- Where the extent stops on the way down: this far above local room tone,
  -- not at the gate. A fricative tail runs below the gate and is still the
  -- fricative.
  sib_floor_db   = 6,
  -- The clip has to hold the whole fricative or the gain step lands inside it
  -- and is heard as a stutter. Detection finds the core; the extent grows out
  -- of it both ways until the high band falls this far below its own peak.
  sib_extend_db  = 18,      -- envelope arm: follow the tail this far down
  sib_edge_frac  = 0.6,     -- ratio arm: fraction of sib_thresh an edge frame
                            -- must still reach. Fixed, never a fraction of the
                            -- sound's own peak -- that made a purer /s/ harder
                            -- to span than a dull one.

  -- Gain cascade -------------------------------------------------------------
  level_mode     = "voiced",  -- voiced | above_gate
  section_target_db = -18,
  section_pct    = 100,
  phrase_pct     = 70,
  -- Element offsets are relative: the clip cut out for a detected element is
  -- turned down by exactly this much, on top of its phrase's gain.
  breath_offset_db    = -6,
  cons_offset_db      = -3,
  sib_offset_db       = -5,
  min_voiced_frames = 20,   -- below this a node inherits its parent's gain

  -- Apply --------------------------------------------------------------------
  split_only_on_change = true,
  colour_items   = true,
  enable_breath  = true,
  enable_cons    = true,
  enable_sib     = true,
}

M.CLASSES = { "section", "phrase", "breath", "consonant", "sibilance" }

-- Item colours, native BGR with the 0x1000000 "set" flag added at apply time.
M.class_colour = {
  phrase    = { 0.35, 0.45, 0.60 },
  breath    = { 0.55, 0.35, 0.60 },
  consonant = { 0.65, 0.50, 0.25 },
  sibilance = { 0.65, 0.30, 0.30 },
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- Persistence ---------------------------------------------------------------
-- Values round-trip through ExtState as strings; type is recovered from the
-- default, so a key that is absent or corrupt falls back rather than erroring.

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
  end
  reaper.SetExtState(M.EXT_SECTION, M.VERSION_KEY, tostring(M.VERSION), true)
end

-- Returns the config, plus the list of keys a migration reset, so the panel
-- can say so rather than leaving the user to notice their sliders moved.
function M.load()
  local cfg = M.new()
  if not reaper then return cfg, {} end

  local stored = tonumber(reaper.GetExtState(M.EXT_SECTION, M.VERSION_KEY)) or 1
  local stale, reset = {}, {}
  if stored < M.VERSION then
    for v = stored + 1, M.VERSION do
      for _, k in ipairs(M.migrations[v] or {}) do
        if reaper.HasExtState(M.EXT_SECTION, k)
           and reaper.GetExtState(M.EXT_SECTION, k) ~= tostring(M.defaults[k]) then
          reset[#reset + 1] = k
        end
        stale[k] = true
      end
    end
    table.sort(reset)
  end

  for k, default in pairs(M.defaults) do
    if stale[k] then goto continue end
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
    ::continue::
  end

  if stored < M.VERSION then M.save(cfg) end
  return cfg, reset
end

return M
