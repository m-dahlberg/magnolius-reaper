-- @noindex
-- Note Leveling -- stage 2: pitch frames into musical notes.
--
-- A port of the Vocal Editor's cluster_notes (engines/audio_engine.py:319-443).
-- Pure Lua: it takes the frame table stage 1 produced and returns plain tables,
-- so the whole stage is testable without REAPER or audio.
--
-- The load-bearing idea is that a note boundary is a change of *semitone
-- label*, not a numeric pitch threshold. Every frame is snapped to its nearest
-- equal-tempered centre first, and a cluster ends when that label changes or
-- the frame goes unvoiced. Everything else here exists to stop that rule from
-- shredding real singing:
--
--   * vibrato swings across a semitone boundary and back, so a short excursion
--     that returns to the original label is absorbed rather than ending it;
--   * a sung note interrupted by a consonant comes back as the same label, so
--     adjacent same-label clusters separated by a short, non-silent gap merge;
--   * a portamento walks through every semitone in between, so the fragments
--     it leaves are shorter than min_note_ms and get dropped -- which is what
--     makes a glide come out as two stable notes with a hole between them,
--     rather than as a staircase.

local Octave = require "nl.octave"

local M = {}

-- The Vocal Editor's NOTE_FREQ_MAP spans C2..G6. Generated from A440 here
-- rather than tabulated: nearest MIDI number and nearest table entry are the
-- same thing, and the arithmetic cannot drift out of tune with itself.
M.MIDI_LO = 36   -- C2, 65.41 Hz
M.MIDI_HI = 91   -- G6, 1567.98 Hz

local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

function M.midi_hz(m) return 440 * 2 ^ ((m - 69) / 12) end

function M.note_name(m)
  return NAMES[m % 12 + 1] .. tostring(math.floor(m / 12) - 1)
end

function M.cents(f, ref) return 1200 * math.log(f / ref, 2) end

-- Nearest semitone within tolerance, or nil. nil also covers unvoiced frames
-- and anything outside the C2..G6 range.
function M.label(f, tolerance_cents)
  if not f or f <= 0 then return nil end
  local m = math.floor(69 + 12 * math.log(f / 440, 2) + 0.5)
  if m < M.MIDI_LO or m > M.MIDI_HI then return nil end
  if math.abs(M.cents(f, M.midi_hz(m))) > tolerance_cents then return nil end
  return m
end

-- A frame is voiced when YIN found a periodic candidate AND there is enough
-- signal to believe it. The level gate is what keeps room tone and reverb
-- tails, which are perfectly periodic in places, from becoming notes.
--
-- The pitch it labels is the OCTAVE-REPAIRED track, not the raw one. YIN
-- decides each frame on its own and has no evidence about its own octave (see
-- octave.lua), so a held note can come back as the same note name in two
-- octaves -- and since a boundary here is a change of semitone label, that
-- split a single sustained note into pieces.
function M.assign(F, cfg)
  local f0 = Octave.repair(F, cfg)
  local lab = {}
  for i = 1, F.n do
    if Octave.voiced(F, i, cfg) then
      lab[i] = M.label(f0[i], cfg.tolerance_cents)
    end
  end
  return lab
end

-- Mean square over a frame range, and its dB. Levels are averaged linearly and
-- converted once -- averaging dB would weight quiet frames far too heavily.
local function mean_ms(F, i0, i1)
  if i1 < i0 then return nil end
  local sum, n = 0, 0
  for i = i0, i1 do sum = sum + (F.ms[i] or 0); n = n + 1 end
  if n == 0 then return nil end
  return sum / n
end

local function db(ms)
  if not ms or ms <= 0 then return -120 end
  return 10 * math.log(ms, 10)
end

-- The gap between two same-note clusters only bridges if something is actually
-- sounding in it -- otherwise two separate sung notes on the same pitch would
-- be welded into one. Frames [i0, i1] are the ones strictly inside the gap.
function M.gap_is_silent(F, i0, i1, silence_db)
  local ms = mean_ms(F, i0, i1)
  if ms == nil then return false end     -- no frames between: not silence
  if ms <= 0 then return true end
  return db(ms) < silence_db
end

-- The mean frequency a note reports is taken from the repaired track too, or a
-- note whose octave was corrected would be labelled in one octave and measured
-- in the other.
local function new_cluster(F, f0, note, i)
  return { note = note, primary = note, i0 = i, i1 = i,
           fsum = f0[i], fn = 1 }
end

local function extend(c, f0, i)
  c.i1 = i
  c.fsum = c.fsum + f0[i]
  c.fn = c.fn + 1
end

function M.run(F, cfg)
  local lab = M.assign(F, cfg)
  local f0 = Octave.repair(F, cfg)
  local hop_ms = cfg.hop_ms

  -- Pass 1: clusters, with vibrato absorbed ----------------------------------
  -- On a label change, look ahead over the wobble window. If the cluster's
  -- ORIGINAL label reappears before any third label does, the deviating frames
  -- belong to the note we are already in. `primary` is fixed at cluster start
  -- and never follows an absorbed excursion, or a slow drift would ratchet the
  -- cluster across the keyboard one absorbed frame at a time.
  local lookahead = 0
  if cfg.wobble_ms > 0 then
    lookahead = math.max(2, math.floor(cfg.wobble_ms / hop_ms))
  end

  local clusters, cur = {}, nil
  for i = 1, F.n do
    local note = lab[i]
    if note == nil then
      if cur then clusters[#clusters + 1] = cur; cur = nil end
    elseif cur == nil then
      cur = new_cluster(F, f0, note, i)
    elseif cur.note == note then
      extend(cur, f0, i)
    else
      local returns, look = false, 0
      for j = i, math.min(i + lookahead - 1, F.n) do
        if lab[j] == cur.primary then
          returns, look = true, j - i
          break
        elseif lab[j] ~= nil and lab[j] ~= note then
          -- a third label: this is a real move, not a wobble
          break
        end
      end
      if returns and look > 0 and look * hop_ms < cfg.wobble_ms then
        extend(cur, f0, i)
      else
        clusters[#clusters + 1] = cur
        cur = new_cluster(F, f0, note, i)
      end
    end
  end
  if cur then clusters[#clusters + 1] = cur end

  -- Pass 2: bridge adjacent same-note clusters -------------------------------
  -- Only immediately adjacent ones. A differently-labelled cluster in between
  -- blocks the merge even if pass 3 later discards it, which is deliberate:
  -- something else was sung there.
  local merged, i = {}, 1
  while i <= #clusters do
    local c = clusters[i]
    while i + 1 <= #clusters do
      local nxt = clusters[i + 1]
      if c.note ~= nxt.note then break end
      if (nxt.i0 - c.i1) * hop_ms > cfg.max_gap_ms then break end
      if M.gap_is_silent(F, c.i1 + 1, nxt.i0 - 1, cfg.silence_db) then break end
      c.i1, c.fsum, c.fn = nxt.i1, c.fsum + nxt.fsum, c.fn + nxt.fn
      i = i + 1
    end
    merged[#merged + 1] = c
    i = i + 1
  end

  -- Pass 3: drop the short ones and measure what is left ----------------------
  -- A discarded cluster leaves a hole rather than merging into a neighbour.
  local out = {}
  for _, c in ipairs(merged) do
    -- The span covers every frame in the cluster, so t1 is the END of the last
    -- frame. (The Vocal Editor uses the last frame's start instead, making
    -- every note one hop shorter; the span is the right thing for an envelope
    -- and for RMS, and one hop is 5 ms.)
    local t0 = (c.i0 - 1) * F.hop_s
    local t1 = c.i1 * F.hop_s
    local dur_ms = (t1 - t0) * 1000
    if dur_ms >= cfg.min_note_ms then
      local mean_freq = c.fsum / c.fn
      out[#out + 1] = {
        id = #out + 1,
        i0 = c.i0, i1 = c.i1, t0 = t0, t1 = t1,
        midi = c.note,
        name = M.note_name(c.note),
        mean_freq = mean_freq,
        cents = M.cents(mean_freq, M.midi_hz(c.note)),
        rms_db = db(mean_ms(F, c.i0, c.i1)),
        dur_ms = dur_ms,
      }
    end
  end
  return out
end

return M
