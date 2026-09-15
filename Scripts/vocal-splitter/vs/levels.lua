-- @noindex
-- Vocal Splitter -- stage 4: reference levels and the cascading gain model.
--
-- Pure Lua. Testable without REAPER.

local M = {}

local FLOOR_DB = -90

-- class -> the config flag that switches its detection on
local ENABLE_KEY = {
  breath = "enable_breath", consonant = "enable_cons", sibilance = "enable_sib",
}

local function db(ms)
  if ms <= 0 then return FLOOR_DB end
  local v = 10 * math.log(ms, 10)
  return v < FLOOR_DB and FLOOR_DB or v
end

-- Measure a node's reference level over frames [i0, i1].
--
-- Default is voiced frames only, and that choice has teeth:
--   * Including silence would make a section with long pauses measure quieter
--     than a dense one, so normalisation would chase pause density rather than
--     the performance.
--   * Including breaths and sibilance would let a breathy phrase drag its own
--     reference down and get boosted for it.
--
-- `owned` is the set of frames a detected element has claimed, and they are
-- excluded outright. The voiced filter alone was not enough: it only excludes
-- them while the voiced path is in use, and the fallback below puts every
-- gated frame back in. Measuring after detection is what makes this possible,
-- and it is why build() now measures levels only once the elements are known.
--
-- Voiced-frame RMS is the stable anchor. Below min_voiced_frames the estimate
-- is not trustworthy and the caller is expected to inherit instead.
function M.measure(F, i0, i1, cfg, gate_db, owned)
  local sum_v, n_v = 0, 0
  local sum_g, n_g = 0, 0
  for i = i0, i1 do
    if F.level_db[i] > gate_db and not (owned and owned[i]) then
      sum_g = sum_g + F.ms[i]; n_g = n_g + 1
      if F.voice_ratio[i] > cfg.voice_thresh then
        sum_v = sum_v + F.ms[i]; n_v = n_v + 1
      end
    end
  end

  local use_voiced = (cfg.level_mode == "voiced") and n_v >= cfg.min_voiced_frames
  local sum, n = (use_voiced and sum_v or sum_g), (use_voiced and n_v or n_g)

  -- Reliable means *the estimate that was actually used* can be trusted, which
  -- is not the same as "there were enough frames of some kind". In voiced mode
  -- a node with one voiced frame and thirty gated ones used to come back
  -- reliable on the strength of the gated count, and then get normalised as
  -- though its gated mean were a voiced reference. The node that does this is
  -- a breath the gate happened to isolate: it becomes a segment, the segment
  -- becomes a phrase, and the phrase is then driven up to its section --
  -- +20.3 dB on the test take, putting the breath 24 dB up while everything
  -- around it moved 9.
  local enough = (cfg.level_mode == "voiced") and n_v or math.max(n_v, n_g)

  return {
    db = n > 0 and db(sum / n) or FLOOR_DB,
    voiced_frames = n_v,
    gated_frames = n_g,
    reliable = enough >= cfg.min_voiced_frames,
    from_voiced = use_voiced,
  }
end

-- Measure a leaf element. Elements are short and often unvoiced by nature
-- (a breath, an /s/), so voiced-frame filtering makes no sense here -- use
-- every frame the element owns, floor excluded.
function M.measure_element(F, i0, i1)
  local sum, n = 0, 0
  for i = i0, i1 do
    sum = sum + F.ms[i]; n = n + 1
  end
  return n > 0 and db(sum / n) or FLOOR_DB
end

-- The cascade.
--
--   g_section = p_s * (T   - L_s)
--   g_phrase  = p_p * (L_s - L_p)
--   g_element = off_e
--
-- Sections and phrases *normalise*: they measure a reference level and drive it
-- toward a target. Elements do not. An element offset is a plain relative
-- attenuation applied to the clip that was cut out for it -- a sibilant inside
-- a phrase that ended up at -23 dB, with the offset at -6 dB, is turned down to
-- -29 dB, whatever the sibilant's own level happened to be.
--
-- This used to drive elements to phrase + offset, as a target or (with
-- attenuate_only) a ceiling, and that was wrong in a way worth recording. A
-- breath sits some 20 dB below its phrase, so "bring it to phrase - 6" is a
-- *boost* of about 14 dB; the attenuate-only cap then turned that into exactly
-- 0 dB, and every detected breath was cut into its own clip and then left
-- completely untouched. Levelling an element against its phrase also fights the
-- performance -- a breath is quiet because the singer breathed quietly, and a
-- soft /s/ needs no de-essing.
--
-- Because the offset no longer depends on the element's measured level, there
-- is nothing left for a clamp to protect against: the number the user typed is
-- the number of dB applied, and max_change_db used to silently cap it.
-- el.level_db is still measured, for the panel to show.
--
-- g_phrase falls out of the spec once the algebra is done: a phrase normalising
-- p_p of the way toward its post-section-gain section level has the section
-- gain cancel from both sides. So every level is computable independently --
-- moving the section target cannot disturb the phrase or element balance, which
-- is what makes the sliders behave predictably.
function M.cascade(tree, cfg)
  local T = cfg.section_target_db
  local p_s = cfg.section_pct / 100
  local p_p = cfg.phrase_pct / 100

  local offsets = {
    breath    = cfg.breath_offset_db,
    consonant = cfg.cons_offset_db,
    sibilance = cfg.sib_offset_db,
  }

  for _, sec in ipairs(tree.sections) do
    local L_s = sec.level.db
    sec.gain = (cfg.enable_section and sec.level.reliable)
               and (p_s * (T - L_s)) or 0

    for _, phr in ipairs(sec.phrases) do
      local L_p = phr.level.db
      -- An unreliable phrase inherits the section gain rather than being
      -- normalised off a bad estimate. With phrases disabled there is one
      -- phrase per section, so L_p is L_s and elements reference the section
      -- (or, with sections off too, the whole file) without further work.
      phr.gain = (cfg.enable_phrase and phr.level.reliable)
                 and (p_p * (L_s - L_p)) or 0
      phr.total_gain = sec.gain + phr.gain

      for _, el in ipairs(phr.elements) do
        -- Only a detected element is ever moved. Everything else in the phrase
        -- -- the "phrase" class, which is the residual left between elements --
        -- carries the phrase gain unchanged.
        local off = offsets[el.class]
        el.gain = (off and cfg[ENABLE_KEY[el.class]]) and off or 0
        el.total_gain = phr.total_gain + el.gain
      end
    end
  end

  return tree
end

M.db = db
M.FLOOR_DB = FLOOR_DB
return M
