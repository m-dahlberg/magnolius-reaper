-- Synthetic frame fixture shared by the headless tests.
local M = {}

------------------------------------------------------------------ frame builder

local RATE, HOP = 48000, 128

function M.builder()
  local F = {
    n = 0, rate = RATE, hop = HOP,
    -- playrate 1, so the two frame durations coincide. Written out separately
    -- anyway, because a fixture that defines only one of them cannot catch a
    -- stage reaching for the other.
    acc_frame_dur = HOP / RATE, src_frame_dur = HOP / RATE,
    playrate = 1, nchan = 1,
    ms = {}, level_db = {}, sib_ratio = {}, voice_ratio = {},
    crest = {}, zcr = {}, slope_db = {},
  }

  -- Emit `dur` seconds at a given level and band balance. The trailing label
  -- is documentation for the fixture layout below; nothing reads it.
  function F.emit(dur, level_db, voice, sib, _label)
    local nf = math.floor(dur / F.acc_frame_dur + 0.5)
    for _ = 1, nf do
      local k = F.n + 1
      F.level_db[k] = level_db
      F.ms[k] = 10 ^ (level_db / 10)
      F.voice_ratio[k] = voice
      F.sib_ratio[k] = sib
      F.crest[k] = 3
      F.zcr[k] = 1000
      F.n = k
    end
    return F
  end

  -- Linear ramps in every feature at once, for edges that are not cliffs.
  -- Real fricatives fade in and out; a fixture made of rectangles cannot show
  -- whether an extent rule finds the whole sound or only its core.
  function F.ramp(dur, l0, l1, v0, v1, s0, s1)
    local nf = math.floor(dur / F.acc_frame_dur + 0.5)
    for i = 1, nf do
      local t = (nf > 1) and (i - 1) / (nf - 1) or 0
      F.emit(F.acc_frame_dur, l0 + (l1 - l0) * t,
             v0 + (v1 - v0) * t, s0 + (s1 - s0) * t)
    end
    return F
  end

  -- Record the frame about to be emitted, so a test can compare a detected
  -- extent against the ground truth the fixture laid down.
  F.marks = {}
  function F.mark(name)
    F.marks[name] = F.marks[name] or {}
    local t = F.marks[name]
    t[#t + 1] = F.n + 1
  end

  function F.finish()
    -- Same 10 ms lookback analyze.lua uses.
    local lb = math.max(1, math.floor(0.010 / F.acc_frame_dur + 0.5))
    for i = 1, F.n do
      local j = i - lb
      F.slope_db[i] = (j >= 1) and (F.level_db[i] - F.level_db[j]) or 0
    end
    F.item_len = F.n * F.acc_frame_dur
    F.acc_len  = F.item_len
    return F
  end

  return F
end

------------------------------------------------------------------- the fixture

-- Two sections 6 dB apart so the cascade has something real to correct.
-- Each section: three phrases, each preceded by a breath and containing one
-- sibilant and one plosive.
M.FLOOR = -62      -- room tone
function M.build()
  local F = M.builder()
  local function room(d) F.emit(d, M.FLOOR, 0.5, 0.10) end

  local function phrase(level)
    F.emit(0.30, level, 0.70, 0.05, "phrase")          -- voiced
    -- 150 ms. A sibilant is 117-248 ms on real material, and length is now
    -- what separates one from a hard consonant, so a 90 ms fixture "sibilant"
    -- was shorter than any real one -- and is, correctly, a consonant.
    F.emit(0.15, level - 3, 0.10, 0.75, "sibilance")   -- /s/
    F.emit(0.25, level, 0.70, 0.05, "phrase")          -- voiced
    F.emit(0.05, level - 30, 0.10, 0.20)               -- plosive closure
    F.emit(0.02, level - 1, 0.10, 0.40, "consonant")   -- burst
    F.emit(0.30, level, 0.70, 0.05, "phrase")          -- voiced
  end

  local function section(level)
    for p = 1, 3 do
      if p > 1 then room(0.50) end                     -- phrase gap
      F.emit(0.30, level - 20, 0.20, 0.30, "breath")   -- breath
      room(0.18)
      phrase(level)
    end
  end

  room(0.40)
  section(-24)
  room(2.20)                                           -- section gap
  section(-30)
  room(0.40)
  return F.finish()
end


-- The awkward case, and the one the defaults have to survive.
--
--   * Sibilants with soft onsets and decaying tails. Only the middle of each
--     clears the level test, so the detected core is narrower than the sound
--     and a clip cut to it steps the gain part way through the /s/.
--   * Breaths recorded close, sitting only 8 dB under the phrase and carrying
--     more high end than a textbook one. Six ANDed windows rejected every one.
--   * A breath with a transient inside it, so that Sensitivity has something
--     to be sensitive about: it scores well short of 1 on steadiness and is
--     taken at the default and dropped at 0.
--
-- The close-mic'd breath used to carry sib_ratio 0.78. That was wrong, and
-- measurement is what says so: on a real take breaths run 0.10-0.25 and
-- fricatives 0.5-0.85, so 0.78 is not a breath with a lot of high end, it is
-- squarely inside the sibilant lobe. The fixture was asserting a property real
-- breaths do not have, and the graded HF window it justified let every /s/ in
-- the file score as a breath. 0.42 is the honest version of "HF-heavy for a
-- breath": near the top of the band, still on the right side of it.
--
-- Marks record where each sibilant really starts and ends.
function M.build_hard()
  local F = M.builder()
  local function room(d) F.emit(d, M.FLOOR, 0.5, 0.10) end
  local LVL = -24

  -- A pure /s/: high peak ratio, and both edges well under half of it. The
  -- onset fades up out of the pause (level low, spectrum still fricative --
  -- only the ratio arm can follow it) and the tail runs into the vowel (level
  -- high, ratio collapsing -- only the envelope arm can).
  local function sibilant()
    F.mark("sib0")
    F.ramp(0.050, -54, -28, 0.15, 0.10, 0.42, 0.95)   -- up out of the pause
    F.emit(0.050, -28, 0.10, 0.95, "sibilance core")
    F.ramp(0.040, -28, -26, 0.10, 0.38, 0.95, 0.18)   -- down into the vowel
    F.mark("sib1")
  end

  for p = 1, 3 do
    room(0.60)
    F.mark("breath0")
    if p == 2 then
      -- A breath with a transient in it. Steadiness scores 0.375, so the
      -- average lands near 0.69: taken at the default sensitivity, dropped at
      -- 0. Kept below LVL - 6 throughout, or the bump would break the run in
      -- two rather than lower its score.
      F.emit(0.15, LVL - 22, 0.35, 0.30, "breath")
      F.emit(0.03, LVL -  8, 0.35, 0.30, "breath transient")
      F.emit(0.15, LVL - 22, 0.35, 0.30, "breath")
    else
      -- close-mic'd: 8 dB down, and HF-heavy for a breath
      F.emit(0.35, LVL - 8, 0.35, 0.42, "breath")
    end
    F.mark("breath1")
    room(0.60)
    F.emit(0.30, LVL, 0.70, 0.05, "phrase")
    sibilant()
    F.emit(0.30, LVL, 0.70, 0.05, "phrase")   -- the vowel the tail runs into
  end
  room(0.40)
  return F.finish()
end

-- The case the gate cannot see, and the reason breath detection is a feature
-- scan rather than a classification of gate segments.
--
-- Two breaths, both below a gate that has to sit where it does to keep room
-- tone out of the phrases. One runs straight into the phrase after it with no
-- pause worth the name, so the gate never gives it a segment of its own. The
-- other sits alone in the middle of a long pause, entirely under the gate, so
-- as far as the gate is concerned it is silence. The old detector could not
-- reach either one however its sliders were set.
function M.build_gateless()
  local F = M.builder()
  local function room(d) F.emit(d, M.FLOOR, 0.5, 0.10) end
  local LVL = -24

  room(0.40)
  F.emit(0.60, LVL, 0.70, 0.05, "phrase")
  F.mark("breath0")                       -- contiguous with the phrase
  F.emit(0.30, -50, 0.25, 0.20, "breath")
  F.mark("breath1")
  F.emit(0.60, LVL, 0.70, 0.05, "phrase")

  room(1.60)
  F.mark("breath0")                       -- alone in the pause, under the gate
  F.emit(0.30, -50, 0.25, 0.20, "breath")
  F.mark("breath1")
  room(1.60)

  F.emit(0.60, LVL, 0.70, 0.05, "phrase")
  room(0.40)
  return F.finish()
end

-- A breath the gate *does* isolate, with pauses either side long enough that
-- it becomes a phrase of its own.
--
-- This is the shape that turned a breath into the loudest thing in the take.
-- The gate gives it a segment, the segment becomes a phrase, the phrase
-- measures its own reference -- a breath, 28 dB below the singing -- and is
-- then normalised toward its section, which is a boost of about 20 dB. The
-- attenuate-only cap that used to hide this is long gone, and the voiced-frame
-- filter did not catch it either: the node fell back to its gated mean, and
-- the old `reliable` test passed it on the gated count.
function M.build_breath_phrase()
  local F = M.builder()
  local function room(d) F.emit(d, M.FLOOR, 0.5, 0.10) end
  local LVL = -24

  room(0.40)
  F.emit(1.20, LVL, 0.70, 0.05, "phrase")
  room(0.50)                                   -- longer than phrase_gap
  F.mark("breath0")
  F.emit(0.30, LVL - 28, 0.25, 0.20, "breath") -- above the gate, below the room
  F.mark("breath1")
  room(0.50)
  F.emit(1.20, LVL, 0.70, 0.05, "phrase")
  room(0.40)
  return F.finish()
end

return M
