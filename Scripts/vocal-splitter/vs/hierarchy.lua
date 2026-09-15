-- @noindex
-- Vocal Splitter -- stage 3: top-down segmentation.
--
--   take -> sections -> phrases -> elements
--
-- Sections, phrases and breaths are found by pauses. Sibilance and hard
-- consonants are not: the /s/ in "sister" is contiguous with the vowels either
-- side and has no gap at all, and a plosive closure is far shorter than
-- min_silence_ms so the gate fills it. Both are found by a feature scan inside
-- the phrase body instead.
--
-- Pure Lua. Testable without REAPER.

local Levels = require "vs.levels"

local M = {}

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- Every duration in this module is in PROJECT time, and that is a decision,
-- not an accident of which field was to hand.
--
-- The frames describe the audio the accessor returned, which already has the
-- take's playrate applied -- so a 200 ms breath in a source read at playrate
-- 1.25 occupies 160 ms of frames, and 160 ms is what the item plays and what
-- the ear hears. Every threshold in this file is a claim about a sound: how
-- long a pause has to be to separate two phrases, how long an /s/ runs, how
-- far a guard rail reaches into a gap. All of them are about the sound as
-- performed, so all of them are project time, and acc_frame_dur is the
-- conversion. src_frame_dur is the source-time equivalent and nothing here
-- wants it.
local function ms_to_frames(ms, F)
  return math.max(1, math.floor(ms / 1000 / F.acc_frame_dur + 0.5))
end

-- Frame index -> project seconds relative to item start. Frames are hop
-- samples apart in accessor time, and accessor time IS item time, so this is
-- directly usable as an edit position -- add the item position and split.
local function ftime(F, i)
  return (i - 1) * F.acc_frame_dur
end

--------------------------------------------------------------------------- gate

-- Deviation from the reference implementation, deliberately: the 80icio
-- dual-envelope gate uses a fast/slow ratio test, but that is a transient
-- detector, not a silence detector. Requiring a rising edge to stay open would
-- close the gate during a sustained sung note. The ratio test is genuinely
-- useful, so it is used where it belongs -- the consonant onset detector below.
--
-- For silence, what matters is hysteresis and minimum durations, which also
-- matches the user's "gate at -35 dB" mental model.
function M.gate(F, gate_db, cfg)
  local open_amp  = 10 ^ ((gate_db + cfg.gate_hyst_db) / 20)
  local close_amp = 10 ^ (gate_db / 20)
  local rel = math.exp(-1 / ((1 / F.acc_frame_dur) * cfg.env_fast_rel))

  -- Peak-hold with decay: stops a brief dip mid-syllable from reading as the
  -- start of a gap before the min-duration rules even get a chance.
  local on, env = {}, 0
  local open = false
  for i = 1, F.n do
    local amp = math.sqrt(F.ms[i])
    env = amp > env and amp or (env * rel)
    if open then
      if env < close_amp then open = false end
    else
      if env > open_amp then open = true end
    end
    on[i] = open
  end

  local min_sil = ms_to_frames(cfg.min_silence_ms, F)
  local min_seg = ms_to_frames(cfg.min_segment_ms, F)

  local function runs()
    local r, i = {}, 1
    while i <= F.n do
      local v, j = on[i], i
      while j < F.n and on[j + 1] == v do j = j + 1 end
      r[#r + 1] = { v = v, i0 = i, i1 = j }
      i = j + 1
    end
    return r
  end

  -- Fill short gaps, then drop short segments, then fill again -- removing a
  -- segment can leave two gaps that should be one.
  for pass = 1, 2 do
    for _, r in ipairs(runs()) do
      if not r.v and (r.i1 - r.i0 + 1) < min_sil then
        for k = r.i0, r.i1 do on[k] = true end
      end
    end
    if pass == 1 then
      for _, r in ipairs(runs()) do
        if r.v and (r.i1 - r.i0 + 1) < min_seg then
          for k = r.i0, r.i1 do on[k] = false end
        end
      end
    end
  end

  local segments, gaps = {}, {}
  for _, r in ipairs(runs()) do
    if r.v then
      segments[#segments + 1] = { i0 = r.i0, i1 = r.i1,
                                  t0 = ftime(F, r.i0), t1 = ftime(F, r.i1 + 1) }
    end
  end
  -- Only interior silences are gaps; leading and trailing silence is not a
  -- boundary between anything.
  for k = 1, #segments - 1 do
    local i0, i1 = segments[k].i1 + 1, segments[k + 1].i0 - 1
    gaps[#gaps + 1] = {
      i0 = i0, i1 = i1,
      t0 = ftime(F, i0), t1 = ftime(F, i1 + 1),
      dur = ftime(F, i1 + 1) - ftime(F, i0),
      before = k, after = k + 1,
    }
  end

  return segments, gaps
end

------------------------------------------------------------------- cut placement

-- One cut per silence, and neither the cut nor its crossfade may touch usable
-- audio. The safe zone is the gap minus guard rails; the crossfade is then
-- clamped to twice the distance to the nearer edge of that zone. Because the
-- fade is centred on the cut, that clamp is what makes the invariant hold by
-- construction rather than by tuning.
--
-- No zero-crossing refinement: a linear crossfade of at least crossfade_min_ms
-- makes a discontinuity impossible, so it would buy nothing.
function M.place_cut(F, gap, cfg, owned)
  local tg = ms_to_frames(cfg.tail_guard_ms, F)
  local og = ms_to_frames(cfg.onset_guard_ms, F)
  local span = gap.i1 - gap.i0 + 1

  -- Too tight for full guards: shrink both in proportion rather than favouring
  -- one edge. The onset guard is the one that matters more -- a plosive's
  -- closure belongs to the word after it -- but a lopsided shrink would make
  -- behaviour discontinuous as gap length varies.
  if tg + og >= span then
    local scale = (span - 1) / (tg + og)
    if scale <= 0 then return nil end
    tg = math.floor(tg * scale)
    og = math.floor(og * scale)
  end

  local z0, z1 = gap.i0 + tg, gap.i1 - og
  if z1 < z0 then return nil end

  -- The quietest frame in the zone that no element occupies. A boundary that
  -- lands inside a breath or an /s/ splits the sound instead of the pause, and
  -- there is no crossfade short enough to make that inaudible.
  local best, bestv = nil, math.huge
  local mid = (z0 + z1) / 2
  for i = z0, z1 do
    if not (owned and owned[i]) then
      local v = F.ms[i]
      -- Tie-break toward the centre so a flat noise floor cuts in the middle
      -- of the pause instead of hugging whichever edge came first.
      if v < bestv or (v == bestv and best
                       and math.abs(i - mid) < math.abs(best - mid)) then
        best, bestv = i, v
      end
    end
  end
  -- Nothing left: the caller falls back to an element edge, which is already a
  -- cut and already at a valley floor.
  if not best then return nil end

  local t   = ftime(F, best)
  local tz0 = ftime(F, z0)
  local tz1 = ftime(F, z1 + 1)
  local cf = math.min(cfg.crossfade_ms / 1000, 2 * (t - tz0), 2 * (tz1 - t))
  cf = math.max(cf, cfg.crossfade_min_ms / 1000)

  return { frame = best, t = t, cf = cf, gap = gap }
end

---------------------------------------------------------------- element scanning

-- High-band mean square for one frame. analyze.lua stores the high band as a
-- *fraction* of frame energy; multiplying back by the frame's mean square
-- recovers the band's own envelope, which is the only thing a fricative's
-- extent can honestly be measured against. The ratio cannot do it, in either
-- direction: at the quiet edges of an /s/ the ratio is still high while the
-- sound has all but gone, and against a following vowel the ratio collapses
-- while the fricative is still sounding.
local function hf_ms(F, i) return F.sib_ratio[i] * F.ms[i] end

-- Fricatives: sibilance and the hard consonants that are releases rather than
-- bursts. One scan finds both, and duration tells them apart.
--
-- That they are one scan is what the test take says. Of the nine hard
-- consonants in it, four (7.31, 14.98, 17.81, 21.46 s) are unvoiced fricative
-- releases with no burst at all -- the one at 21.46 s rises 10 dB over 40 ms,
-- so the onset detector below, which wants 12 dB over 10 ms, cannot see it and
-- no threshold on it ever will. They are found the way an /s/ is found, and
-- then separated from one by length: on that take every hard consonant runs
-- 8-91 ms and every sibilant runs 117-248 ms, which is a real gap and not a
-- tuned one. sib_min_ms is that boundary.
--
-- Detection and extent are two different questions and are answered
-- separately. A frame is unambiguously fricative when the high band dominates
-- it *and* it is well clear of the gate -- that finds the **core** of the
-- sound reliably, but only its core. Cutting there puts the gain step inside
-- the /s/, which is heard as a stutter.
--
-- The extent therefore grows outward from the core in both directions. What it
-- must not do is what this used to: expand while sib_ratio stayed above *half
-- its own peak*. That test is inverted -- the purer the fricative, the higher
-- its peak ratio and so the stricter the bar its own edges have to clear. A
-- textbook /s/ peaking at 0.95 demanded 0.475 at the edges and lost both of
-- them; a duller one peaking at 0.6 only demanded 0.3 and kept more. Worse for
-- being cleaner is exactly backwards, and it truncated the start, the end, or
-- both depending on how the sound happened to be shaped.
--
-- A frame continues the fricative if *either* holds:
--
--   * it is still high-band dominated in absolute terms (a fixed fraction of
--     the detection threshold, not of this sound's peak) -- this is what
--     follows an /s/ down into a pause, where the level falls away but the
--     spectrum stays fricative; or
--   * its high-band energy is still within sib_extend_db of the core's peak --
--     this is what follows it into a neighbouring vowel, where the ratio
--     collapses while real fricative energy is still present.
--
-- Three things stop the growth. Voicing, because a vowel is where the
-- fricative ends by definition and the envelope arm above would otherwise run
-- straight into it. The gate, because below it there is nothing left to
-- include. And sib_max_ms, as a clamp rather than a rejection: an /s/ that
-- grows past the limit is still an /s/, so it is trimmed, not thrown away.
local function scan_fricatives(F, i0, i1, th, cfg)
  local floor_db = th.room_floor
  local lvl = th.gate_db + cfg.sib_level_db
  local minlen = ms_to_frames(cfg.element_min_ms, F)
  local sib_len = ms_to_frames(cfg.sib_min_ms, F)
  local maxlen = ms_to_frames(cfg.sib_max_ms, F)
  local edge_ratio = th.sib_thresh * cfg.sib_edge_frac
  local floor_ratio = 10 ^ (-cfg.sib_extend_db / 10)   -- dB on power

  local hits = {}
  local i = i0
  while i <= i1 do
    if F.sib_ratio[i] > th.sib_thresh and F.level_db[i] > lvl then
      local j = i
      while j < i1 and F.sib_ratio[j + 1] > th.sib_thresh
            and F.level_db[j + 1] > lvl do j = j + 1 end
      local c0, c1 = i, j

      if (c1 - c0 + 1) <= maxlen then
        local hpk = 0
        for k = c0, c1 do hpk = math.max(hpk, hf_ms(F, k)) end
        local floor_ = hpk * floor_ratio

        -- The tail stops at the room, not at the gate. An /s/ decaying out of
        -- a word runs well below a gate that has to sit high enough to keep
        -- room tone out of the phrases, and it is still unmistakably the /s/:
        -- at 1.61-1.66 s in the test take the level is -70 dB while sib_ratio
        -- is still 0.5-0.86. Stopping at the gate cut the clip at 1.603 and
        -- left the rest of the fricative to be re-detected as a separate
        -- 19 ms element of its own.
        local function continues(k)
          if F.voice_ratio[k] > cfg.voice_thresh then return false end
          if floor_db and F.level_db[k] <= floor_db[k] + cfg.sib_floor_db then
            return false
          end
          return F.sib_ratio[k] > edge_ratio or hf_ms(F, k) > floor_
        end

        local a = c0
        while a > i0 and (c1 - a + 1) < maxlen and continues(a - 1) do
          a = a - 1
        end
        local b = c1
        while b < i1 and (b - a + 1) < maxlen and continues(b + 1) do
          b = b + 1
        end

        if (b - a + 1) >= minlen then
          hits[#hits + 1] = { i0 = a, i1 = b, core0 = c0, core1 = c1,
                              class = (b - a + 1) >= sib_len
                                      and "sibilance" or "consonant" }
        end
        j = math.max(j, b)
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return hits
end

function M.new_cons_diag()
  return { onsets = 0, taken = 0, why = {}, list = {} }
end

-- Isolated hard consonant: a burst that rises sharply out of its own closure.
--
-- This finds the plosives -- the ones with a burst. The fricative releases are
-- found by scan_fricatives above and arrive already labelled consonants; the
-- two sets overlap on the affricates, and the merge below keeps one.
--
-- Found by feature scan, not by the gate. A plosive closure runs 40-80 ms,
-- comfortably under min_silence_ms, so the gate fills it on purpose -- that is
-- what stops every closure becoming a phrase boundary. Requiring a
-- gate-produced gap here would therefore find nothing at all.
function M.scan_consonants(F, i0, i1, th, cfg, diag, fricatives)
  local nclose = ms_to_frames(cfg.cons_closure_ms, F)
  local minlen = ms_to_frames(cfg.cons_min_ms, F)
  local maxlen = ms_to_frames(cfg.cons_max_ms, F)
  local join   = ms_to_frames(cfg.cons_join_ms, F)

  local hits = {}
  local i = i0 + 1
  while i <= i1 do
    if F.slope_db[i] >= cfg.cons_onset_db then
      -- One onset, tested once. A burst holds the slope up for several frames,
      -- and testing every one of them re-judged the same consonant from
      -- steadily worse ground: the closure window of the second test is the
      -- first test's burst, so the closure it measures is the rise itself and
      -- reads a few dB deep instead of twenty. Take the whole run of
      -- above-threshold slope as the event and anchor at where it began.
      local onset = i
      while onset < i1 and F.slope_db[onset + 1] >= cfg.cons_onset_db do
        onset = onset + 1
      end

      -- Where the burst ends. Voicing, and only voicing: a plosive is followed
      -- immediately by its vowel at much the same level, so a level-based
      -- extent runs straight into the vowel.
      --
      -- Voiced frames shorter than cons_join_ms are bridged. A burst is noise
      -- and the voicing estimate flickers through it -- the 43 ms consonant at
      -- 14.25 s in the test take reads 0.07, 0.06, 0.09, 0.50, 0.54, 0.50,
      -- 0.50, 0.47, 0.20, ... so a strict frame-by-frame walk stops after
      -- 11 ms on a burst whose *mean* voicing is 0.28.
      local hard = math.min(i1, i + 2 * maxlen)
      local j, k = i, i
      while k < hard do
        if F.voice_ratio[k + 1] <= cfg.cons_voice_max then
          k = k + 1
          j = k
        else
          local v = k + 1
          while v < hard and F.voice_ratio[v + 1] > cfg.cons_voice_max do
            v = v + 1
          end
          if (v - k) > join or v >= hard then break end
          k = v
        end
      end

      local pk = -math.huge
      for k2 = i, j do pk = math.max(pk, F.level_db[k2]) end

      -- A closure is a moment of quiet before the burst, so the test is how
      -- quiet it *got*, not whether every frame in the window was quiet. Using
      -- the maximum asked the second question and failed the moment the window
      -- caught the tail of the previous word -- or, on a phrase-initial
      -- plosive, the burst's own first frame, which sits one frame before the
      -- frame the slope test fires on. That read a 42 dB closure as 5.6 and
      -- dropped the consonant.
      local cmin = math.huge
      for k2 = math.max(1, i - nclose), i - 1 do
        cmin = math.min(cmin, F.level_db[k2])
      end

      local vr, sib = 0, 0
      for k2 = i, j do vr = vr + F.voice_ratio[k2]; sib = sib + F.sib_ratio[k2] end
      vr, sib = vr / (j - i + 1), sib / (j - i + 1)

      -- A burst that begins *inside* a fricative is not a separate consonant.
      -- Decaying fricative noise swings 14 dB frame to frame -- the tail of
      -- the /s/ at 1.46 s reads -73.8, -59.4, -73.3, -62.7 -- so it clears any
      -- onset threshold repeatedly, out of a "closure" that is just the next
      -- dip down. The audio there is already accounted for as one sound, and
      -- a fluctuation inside it is not a second one. A burst that starts *at
      -- or before* a fricative still counts: that is an affricate, and the
      -- burst is the better description of where it begins.
      local inside = false
      for _, f in ipairs(fricatives or {}) do
        if i > f.i0 and i <= f.i1 then inside = true break end
      end

      local len = j - i + 1
      local why
      if inside then why = "inside a fricative"
      elseif len < minlen then why = "too short"
      elseif len > maxlen then why = "too long"
      elseif cmin > pk - cfg.cons_closure_drop_db then why = "no closure"
      elseif vr > cfg.cons_voice_max then why = "voiced"
      end

      if diag then
        diag.onsets = diag.onsets + 1
        if why then
          diag.why[why] = (diag.why[why] or 0) + 1
        else
          diag.taken = diag.taken + 1
        end
        diag.list[#diag.list + 1] = {
          i0 = i, i1 = j, dur_ms = len * F.acc_frame_dur * 1000,
          slope = F.slope_db[i], pk = pk, closure = pk - cmin,
          voice = vr, sib = sib, verdict = why or "taken",
        }
      end

      if not why then
        hits[#hits + 1] = { i0 = i, i1 = j, class = "consonant" }
      end
      i = math.max(onset, j) + 1
    else
      i = i + 1
    end
  end
  return hits
end

-- Bursts win ties. A /t/ released into an /s/ satisfies both scans, and the
-- burst is the shorter and more specific description of where the sound
-- starts.
local function scan_elements(F, i0, i1, th, cfg, diag)
  -- Fricatives are scanned first so the burst scan can see them, but bursts
  -- still take precedence in the merge.
  local fric = scan_fricatives(F, i0, i1, th, cfg)

  local hits = {}
  if cfg.enable_cons then
    for _, h in ipairs(M.scan_consonants(F, i0, i1, th, cfg, diag, fric)) do
      hits[#hits + 1] = h
    end
  end
  local minlen = ms_to_frames(cfg.element_min_ms, F)
  for _, h in ipairs(fric) do
    -- One scan, two classes: whether this hit is wanted depends on which class
    -- its length made it.
    local want = (h.class == "sibilance") and cfg.enable_sib or cfg.enable_cons
    if want then
      -- Trim on a clash rather than discard. Now that the extent grows out to
      -- the fricative's shoulders it can reach a neighbouring burst, and
      -- throwing the whole /s/ away because its tail brushed a /t/ would lose
      -- exactly the detections the growth exists to improve. Only a clash that
      -- eats the core itself is fatal.
      local a, b, dead = h.i0, h.i1, false
      for _, e in ipairs(hits) do
        if a <= e.i1 and b >= e.i0 then
          if e.i1 < h.core0 then a = math.max(a, e.i1 + 1)
          elseif e.i0 > h.core1 then b = math.min(b, e.i0 - 1)
          else dead = true end
        end
      end
      if not dead and (b - a + 1) >= minlen then
        h.i0, h.i1 = a, b
        hits[#hits + 1] = h
      end
    end
  end
  table.sort(hits, function(a, b) return a.i0 < b.i0 end)
  return hits
end

-- Breath detection.
--
-- Breaths are found by a feature scan across the whole take, the same way
-- sibilance and hard consonants are, and deliberately *not* by classifying
-- gate segments. That is a correction, and the reason is structural rather
-- than a matter of tuning.
--
-- The old design asked "is this gate segment a breath?". For that to work the
-- gate has to resolve a breath as a segment of its own, and it cannot. A
-- breath sits 5-12 dB above room tone, while the gate has to sit 12-15 dB
-- above room tone to keep the room out of the phrases -- so the breath is on
-- the wrong side of it. On the test take with four breaths in it, the gate cut
-- one of them down to 93 ms of its 275 (so it failed breath_min_ms), let two
-- be swallowed by the tail of the phrase they followed (so they were never
-- segments at all), and left the quietest entirely below the gate inside a
-- 900 ms pause (so it did not exist). Nothing downstream could recover any of
-- that, which is why the funnel read "0 candidates" whatever the sliders did.
--
-- Requiring a gate-produced segment here fails in exactly the way requiring a
-- gate-produced gap would fail for plosives, which the consonant scanner above
-- already says in as many words. Breaths get the same treatment: frame
-- features, across the whole take, above and below the gate alike.
--
-- What separates a breath from the room it was recorded in is *prominence*,
-- not level: it stands a few dB above the quietest thing near it. An absolute
-- threshold cannot express that, because a percentile of the whole take lands
-- inside the silence lobe precisely when the take has plenty of silence. So
-- the floor is estimated locally and the test is relative to it.

-- Local room tone: a sliding minimum of the smoothed level. Smoothed first,
-- because a raw per-frame minimum over three seconds finds whatever single
-- frame happened to land between two cycles and reads several dB low.
local FLOOR_BLOCK_S    = 0.25
local FLOOR_SPAN_BLOCKS = 6      -- +- 1.5 s
local FLOOR_SMOOTH_MS  = 30

function M.room_floor(F)
  local sm = ms_to_frames(FLOOR_SMOOTH_MS, F)
  local W  = math.max(1, math.floor(FLOOR_BLOCK_S / F.acc_frame_dur + 0.5))
  local nb = math.ceil(F.n / W)

  local bmin = {}
  for b = 1, nb do
    local lo = math.huge
    for i = (b - 1) * W + 1, math.min(F.n, b * W) do
      local a, z = math.max(1, i - sm), math.min(F.n, i + sm)
      local acc = 0
      for k = a, z do acc = acc + F.ms[k] end
      local v = Levels.db(acc / (z - a + 1))
      if v < lo then lo = v end
    end
    bmin[b] = lo
  end

  local win = {}
  for b = 1, nb do
    local lo = math.huge
    for k = math.max(1, b - FLOOR_SPAN_BLOCKS), math.min(nb, b + FLOOR_SPAN_BLOCKS) do
      if bmin[k] < lo then lo = bmin[k] end
    end
    win[b] = lo
  end

  local out = {}
  for i = 1, F.n do out[i] = win[math.floor((i - 1) / W) + 1] end
  return out
end

-- The singing near a frame, as voiced-frame RMS over a couple of seconds
-- either side. This is what a breath is judged quiet *against*.
--
-- It is measured locally rather than taken from the phrase the breath sits in,
-- and that is not a refinement -- it is the difference between finding a
-- breath and not. When the gate does happen to resolve a breath, the breath
-- becomes a segment, the segment becomes a phrase, and the phrase's reference
-- level is then the level of the breath itself; asking whether it sits 6 dB
-- below that is asking whether it is 6 dB below itself, and the answer is
-- always no. On the test take that silently cost the one breath the gate had
-- managed to isolate. Measuring the neighbourhood instead makes the test say
-- what it means, and makes breath detection independent of the section and
-- phrase switches into the bargain -- which is what the panel already promises
-- when it says a single process can be judged on its own.
local VOICED_BLOCK_S     = 0.25
local VOICED_SPAN_BLOCKS = 8      -- +- 2 s
local VOICED_MIN_FRAMES  = 20

function M.local_voice_level(F, cfg, gate_db)
  local W  = math.max(1, math.floor(VOICED_BLOCK_S / F.acc_frame_dur + 0.5))
  local nb = math.ceil(F.n / W)

  local bs, bn, tot_s, tot_n = {}, {}, 0, 0
  for b = 1, nb do
    local acc, n = 0, 0
    for i = (b - 1) * W + 1, math.min(F.n, b * W) do
      if F.level_db[i] > gate_db and F.voice_ratio[i] > cfg.voice_thresh then
        acc = acc + F.ms[i]; n = n + 1
      end
    end
    bs[b], bn[b] = acc, n
    tot_s, tot_n = tot_s + acc, tot_n + n
  end
  local whole = tot_n > 0 and Levels.db(tot_s / tot_n) or Levels.FLOOR_DB

  local win = {}
  for b = 1, nb do
    -- Widen until there is enough voiced material to trust the estimate: in a
    -- long pause the two seconds either side may hold no singing at all, and
    -- an empty window would otherwise read as silence and make every breath
    -- in the pause look loud.
    local span, acc, n = VOICED_SPAN_BLOCKS, 0, 0
    while true do
      acc, n = 0, 0
      for k = math.max(1, b - span), math.min(nb, b + span) do
        acc = acc + bs[k]; n = n + bn[k]
      end
      if n >= VOICED_MIN_FRAMES or span >= nb then break end
      span = span * 2
    end
    win[b] = (n >= VOICED_MIN_FRAMES) and Levels.db(acc / n) or whole
  end

  local out = {}
  for i = 1, F.n do out[i] = win[math.floor((i - 1) / W) + 1] end
  return out
end

-- 1 inside [lo, hi], falling linearly to 0 over `soft` beyond either edge.
local function band_score(v, lo, hi, soft)
  if v >= lo and v <= hi then return 1 end
  local d = (v < lo) and (lo - v) or (v - hi)
  return math.max(0, 1 - d / soft)
end

-- How far outside its window a feature may sit before it scores zero. Wide
-- enough that a marginal breath still registers as marginal rather than as
-- absent, which is what makes the Sensitivity control continuous.
local BREATH_SOFT = { level = 8, slope = 8 }

function M.breath_features(F, seg, cfg, phrase_db)
  local n = seg.i1 - seg.i0 + 1
  local sib, vr = 0, 0
  for i = seg.i0, seg.i1 do
    sib = sib + F.sib_ratio[i]
    vr  = vr + F.voice_ratio[i]
  end

  -- The slope test asks "is there a burst inside this?", so it must skip the
  -- run's own onset: the rise out of room tone into the breath always looks
  -- like a burst, which would reject every breath there is.
  local slope = 0
  local skip = ms_to_frames(cfg.breath_attack_skip_ms, F)
  for i = math.min(seg.i0 + skip, seg.i1), seg.i1 do
    slope = math.max(slope, F.slope_db[i])
  end

  local d = {
    dur_ms = n * F.acc_frame_dur * 1000,
    hf = sib / n,
    voice = vr / n,
    slope = slope,
    level_rel = Levels.measure_element(F, seg.i0, seg.i1) - phrase_db,
  }
  d.s_level = band_score(d.level_rel, cfg.breath_rel_lo_db,
                         cfg.breath_rel_hi_db, BREATH_SOFT.level)
  d.s_slope = band_score(d.slope, -math.huge, cfg.breath_slope_max_db,
                         BREATH_SOFT.slope)
  d.score = (d.s_level + d.s_slope) / 2
  return d
end

function M.new_breath_diag()
  return { runs = 0, bad_dur = 0, candidates = 0, accepted = 0,
           rejected = 0, best_rejected = 0, weak = {}, list = {} }
end

-- Returns the detected breaths, in frame order, and fills the funnel.
--
-- The absolute per-frame tests find the runs, because a frame failing one is
-- not part of a breath under any tuning: it is unvoiced, its high band sits
-- inside the breath band, and it stands breath_floor_db clear of the local
-- room tone while staying below the phrase. The graded features -- level below
-- the phrase and steadiness -- then score the whole run 0..1 and their average
-- must clear Sensitivity.
--
-- The high band is bounded on *both* sides, and hard, which is the one place
-- this departs from "score it, do not AND it". A breath is unvoiced but not
-- fricative, and those are two edges of one category, not two opinions about
-- it: room tone carries almost no high band, a breath runs 0.15-0.25, an /s/
-- runs 0.5-0.85. Left as a graded feature it could not do that job -- a
-- textbook /s/ scored 0 for HF content and still came through at 0.67, because
-- averaging a zero with two ones cannot express "this is categorically
-- something else". Six of the eight breaths found on the test take that way
-- were sibilants.
function M.scan_breaths(F, th, cfg, diag)
  local floor_db = th.room_floor or M.room_floor(F)
  local ref      = M.local_voice_level(F, cfg, th.gate_db)
  local join     = ms_to_frames(cfg.breath_join_ms, F)
  local minlen   = ms_to_frames(cfg.breath_min_ms, F)
  local maxlen   = ms_to_frames(cfg.breath_max_ms, F)

  local on = {}
  for i = 1, F.n do
    on[i] = F.voice_ratio[i] <= cfg.breath_voice_max
        and F.sib_ratio[i]   >= cfg.breath_sib_lo
        and F.sib_ratio[i]   <= cfg.breath_sib_hi
        and F.level_db[i]    >= floor_db[i] + cfg.breath_floor_db
        and F.level_db[i]    <= ref[i] + cfg.breath_rel_hi_db
  end

  -- Detection and extent are different questions here too, and for the same
  -- reason they are for a fricative: the test that says "this is definitely a
  -- breath" is not the test that says "the breath is still going". A breath
  -- fades up out of the room and back down into it, and at both ends the
  -- high-band fraction falls below breath_sib_lo while the sound is plainly
  -- still there -- the breath at 21.94 s in the test take runs from 21.66 to
  -- 22.25 and only 21.94-22.24 of it passes the core test, so the clip covered
  -- half the sound and stepped the gain inside it. The edges also drift
  -- voiced-looking as they approach the room tone, which is why the voicing
  -- cap is loosened rather than dropped: what must not be crossed is the
  -- singing coming back.
  -- The edge test reads *smoothed* features, and that is the whole trick. On
  -- noise these are noisy estimates: down the tail of the 21.94 s breath
  -- sib_ratio reads 0.112, 0.068, 0.046, 0.056, 0.082, 0.034, 0.204, 0.050,
  -- 0.038, 0.104 frame by frame. Any per-frame threshold is crossed back and
  -- forth every few frames, so a walk that stops at the first failing frame
  -- stops within 10 ms of the core and the extent is no wider than what it
  -- grew from. Over 16 ms the same stretch is a steady 0.06-0.09 and the
  -- growth runs the length of the breath.
  --
  -- Smoothing rather than bridging, because the two ends have to fail
  -- differently: HF fading into the room is a soft edge to be followed, but
  -- the singing coming back is a wall. A miss-counting bridge cannot tell
  -- those apart and walks straight back into the phrase tail.
  local sm = ms_to_frames(cfg.breath_edge_smooth_ms, F)
  local s_sib, s_voice, s_ms = {}, {}, {}
  for i = 1, F.n do
    local a, b = math.max(1, i - sm), math.min(F.n, i + sm)
    local x, y, z = 0, 0, 0
    for k = a, b do
      x = x + F.sib_ratio[k]; y = y + F.voice_ratio[k]; z = z + F.ms[k]
    end
    local n = b - a + 1
    s_sib[i], s_voice[i], s_ms[i] = x / n, y / n, Levels.db(z / n)
  end

  local edge_sib   = cfg.breath_sib_lo * cfg.breath_edge_frac
  local edge_voice = math.min(1, cfg.breath_voice_max + 0.25)

  -- Snap an end to the bottom of the valley beside it.
  --
  -- A breath is a smooth ramp up out of one pause and back down into the next,
  -- so its boundaries are the quietest points either side -- not wherever the
  -- feature test gave out on the way down. Every clip on the test take stopped
  -- 4-12 dB up the slope: 40-80 ms short at the head, 24-136 ms at the tail.
  -- A gain step placed on a slope is precisely where it can be heard, and a
  -- valley bottom is both the true edge of the sound and the quietest place to
  -- cut, which is where place_cut would have put a cut anyway.
  --
  -- Walk outward tracking the running minimum, and return where that minimum
  -- was. Two things end the walk outright: the level climbing back to the
  -- phrase, and the spectrum turning fricative. Otherwise it stops once the
  -- level has climbed breath_valley_rise_db out of the minimum and *stayed*
  -- there.
  --
  -- Voicing is deliberately not one of the stops here, though it bounds the
  -- extent growth above. This walk is going downhill by construction, and the
  -- bottom of a valley after a sung note is the tail of that note: low-frequency
  -- decay, so voice_ratio reads 0.7-1.2 at -70 dB. Stopping on it stopped the
  -- walk 45 ms short of every valley floor -- it fires on the *decay* of the
  -- singing, not on the singing, and the level test is what actually says the
  -- singing is back.
  --
  -- Sustained, not instantaneous. Even at 16 ms the smoothed level spikes more
  -- than 3 dB frame to frame down at -65, so a walk that stopped at the first
  -- rise stopped 45 ms short of a valley floor it was heading straight for. A
  -- rise held for longer than the smoothing window is a real climb; anything
  -- briefer is the noise the smoothing did not manage to remove.
  local reach = ms_to_frames(cfg.breath_valley_ms, F)
  local exit_run = ms_to_frames(cfg.breath_edge_smooth_ms * 2, F)
  local function valley(from, step)
    local best, bestv = from, s_ms[from]
    local k, n, up = from + step, 0, 0
    while k >= 1 and k <= F.n and n < reach do
      if s_sib[k] > cfg.breath_sib_hi then break end
      if s_ms[k] > ref[k] + cfg.breath_rel_hi_db then break end
      if s_ms[k] < bestv then
        best, bestv, up = k, s_ms[k], 0
      else
        up = (s_ms[k] > bestv + cfg.breath_valley_rise_db) and (up + 1) or 0
        if up >= exit_run then break end
      end
      k = k + step
      n = n + 1
    end
    return best
  end
  local function continues(k, hi)
    return s_voice[k] <= edge_voice
       and s_sib[k]   >= edge_sib
       and s_sib[k]   <= hi
       and s_ms[k]    >= floor_db[k] + cfg.breath_edge_db
       and s_ms[k]    <= ref[k] + cfg.breath_rel_hi_db
  end

  -- Bridge short dropouts. A breath is noise, and noise crosses any per-frame
  -- test back and forth; without this one breath arrives as five fragments,
  -- each of them too short to be one.
  local i = 1
  while i <= F.n do
    if not on[i] then
      local j = i
      while j < F.n and not on[j + 1] do j = j + 1 end
      if i > 1 and j < F.n and (j - i + 1) <= join then
        for k = i, j do on[k] = true end
      end
      i = j + 1
    else
      i = i + 1
    end
  end

  local out = {}
  i = 1
  while i <= F.n do
    if on[i] then
      local j = i
      while j < F.n and on[j + 1] do j = j + 1 end
      local ci, cj = i, j
      diag.runs = diag.runs + 1
      local len = j - i + 1
      diag.list[#diag.list + 1] = { i0 = i, i1 = j, core0 = ci, core1 = cj,
        dur_ms = len * F.acc_frame_dur * 1000, verdict = "?" }
      local rec = diag.list[#diag.list]
      if len < minlen or len > maxlen then
        diag.bad_dur = diag.bad_dur + 1
        rec.verdict = "length"
      else
        local seg = { i0 = i, i1 = j, core0 = ci, core1 = cj }
        local d = M.breath_features(F, seg, cfg, ref[i])
        seg.breath = d
        diag.candidates = diag.candidates + 1
        rec.d = d
        if d.score >= 1 - cfg.breath_sensitivity / 100 then
          diag.accepted = diag.accepted + 1
          rec.verdict = "taken"
          -- Only now grow the clip out of the core. Whether this *is* a breath
          -- is settled on the core, because that is the evidence; the extent
          -- only decides where to cut. Deciding on the extent instead let an
          -- 8 ms core -- three shoulder frames of the fricative consonant at
          -- 21.46 s, whose body is far too high-band to be a breath -- grow
          -- across the whole consonant and pass breath_min_ms at 99 ms.
          local hi = cfg.breath_sib_hi
          local a, b = i, j
          while a > 1 and (b - a + 1) < maxlen and continues(a - 1, hi) do
            a = a - 1
          end
          while b < F.n and (b - a + 1) < maxlen and continues(b + 1, hi) do
            b = b + 1
          end

          -- Then out to the valley floors. Deliberately not capped by
          -- breath_max_ms: that bounds what counts as a breath and how far the
          -- feature test may run, and truncating here would put the clip edge
          -- back on the slope, which is the thing being fixed. The reach is
          -- bounded by breath_valley_ms on each side instead.
          a, b = valley(a, -1), valley(b, 1)
          seg.i0, seg.i1 = a, b
          rec.i0, rec.i1 = a, b
          out[#out + 1] = seg
        else
          rec.verdict = "score"
          diag.rejected = diag.rejected + 1
          diag.best_rejected = math.max(diag.best_rejected, d.score)
          local name = (d.s_slope < d.s_level) and "steadiness" or "level"
          diag.weak[name] = (diag.weak[name] or 0) + 1
        end
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return out
end

------------------------------------------------------------------------- build

-- Returns the tree plus a flat span list. Spans are the items apply.lua will
-- create; they tile the item end to end, so every sample belongs to exactly
-- one span and gets exactly one gain.
function M.build(F, th, cfg)
  local segments, gaps = M.gate(F, th.gate_db, cfg)
  if #segments == 0 then return nil, "No signal above the gate" end

  -- Local room tone, shared: both the fricative extent and breath detection
  -- ask how far above the room a frame stands, and it costs a pass over the
  -- take to answer.
  th.room_floor = M.room_floor(F)

  th.gaps = gaps

  -- A disabled level becomes a single node spanning its parent. That is what
  -- makes the reference chain degrade on its own: with sections off there is
  -- one section covering the take, so L_section is the whole-file loudness.
  local sec_gap = cfg.enable_section and (th.section_gap_ms / 1000) or math.huge
  local phr_gap = cfg.enable_phrase  and (th.phrase_gap_ms  / 1000) or math.huge

  local cuts = {}

  -- Group segments into sections, then phrases, by gap duration.
  local sections = {}
  local cur_sec = { seg0 = 1 }
  for k, g in ipairs(gaps) do
    if g.dur >= sec_gap then
      cur_sec.seg1 = k
      sections[#sections + 1] = cur_sec
      cur_sec = { seg0 = k + 1 }
    end
  end
  cur_sec.seg1 = #segments
  sections[#sections + 1] = cur_sec

  local tree = { sections = {}, cuts = cuts, gaps = gaps,
                 segments = segments, gate_db = th.gate_db }

  for _, s in ipairs(sections) do
    local sec = {
      i0 = segments[s.seg0].i0, i1 = segments[s.seg1].i1,
      t0 = segments[s.seg0].t0, t1 = segments[s.seg1].t1,
      phrases = {},
    }
    local p0 = s.seg0
    for k = s.seg0, s.seg1 do
      local g = gaps[k]
      local is_last = (k == s.seg1)
      if is_last or (g and g.dur >= phr_gap) then
        local phr = {
          i0 = segments[p0].i0, i1 = segments[k].i1,
          t0 = segments[p0].t0, t1 = segments[k].t1,
          seg0 = p0, seg1 = k, elements = {},
        }
        sec.phrases[#sec.phrases + 1] = phr
        p0 = k + 1
      end
    end
    tree.sections[#tree.sections + 1] = sec
  end

  tree.breath_diag = M.new_breath_diag()
  tree.cons_diag   = M.new_cons_diag()

  -- Breaths first, over the whole take. They are scanned rather than derived
  -- from the gate, so a breath can lie anywhere -- inside a phrase body, on
  -- the tail of one, or on its own in the middle of a pause below the gate.
  local breaths = cfg.enable_breath
                  and M.scan_breaths(F, th, cfg, tree.breath_diag) or {}
  tree.breaths = breaths

  -- Each breath belongs to the phrase it overlaps most, or failing any
  -- overlap, the nearest one -- that is the phrase whose gain it is offset
  -- from and whose reference it was judged against.
  local function owning_phrase(b)
    local best, bestk = nil, -math.huge
    for _, sec in ipairs(tree.sections) do
      for _, phr in ipairs(sec.phrases) do
        local ov = math.min(b.i1, phr.i1) - math.max(b.i0, phr.i0) + 1
        local k = (ov > 0) and ov
                  or -math.min(math.abs(b.i0 - phr.i1), math.abs(phr.i0 - b.i1))
        if k > bestk then bestk, best = k, phr end
      end
    end
    return best
  end

  -- A breath's own edges are cut points. They are not in a gap -- a breath
  -- fades into the room rather than stopping -- so they take the short
  -- element crossfade, exactly as a sibilant's edges do.
  local sib_cf = cfg.sib_crossfade_ms / 1000
  for _, b in ipairs(breaths) do
    b.phr = owning_phrase(b)
    if b.phr then
      b.phr.elements[#b.phr.elements + 1] = {
        class = "breath", sig_i0 = b.i0, sig_i1 = b.i1,
        level_db = Levels.measure_element(F, b.i0, b.i1),
        breath = b.breath,
      }
      cuts[#cuts + 1] = { t = ftime(F, b.i0), cf = sib_cf, element = true }
      if b.i1 < F.n then
        cuts[#cuts + 1] = { t = ftime(F, b.i1 + 1), cf = sib_cf, element = true }
      end
    end
  end

  -- Classify what is left of each signal run inside its phrase, and split
  -- phrase bodies at sibilance. Sibilance edges are not in a gap either, so
  -- they get the same short crossfade -- the overlap is coherent material and
  -- a linear fade reconstructs it exactly.
  for _, sec in ipairs(tree.sections) do
    for _, phr in ipairs(sec.phrases) do
      -- Emit the elements found in [a, b], plus the phrase residual between
      -- them. Called once per stretch of a segment that no breath claimed.
      local function emit(a, b)
        if a > b then return end
        local hits = scan_elements(F, a, b, th, cfg, tree.cons_diag)
        local at = a
        for _, h in ipairs(hits) do
          if h.i0 > at then
            phr.elements[#phr.elements + 1] = {
              class = "phrase", sig_i0 = at, sig_i1 = h.i0 - 1,
              level_db = Levels.measure_element(F, at, h.i0 - 1),
            }
            cuts[#cuts + 1] = { t = ftime(F, h.i0), cf = sib_cf, element = true }
          end
          phr.elements[#phr.elements + 1] = {
            class = h.class, sig_i0 = h.i0, sig_i1 = h.i1,
            core0 = h.core0, core1 = h.core1,
            level_db = Levels.measure_element(F, h.i0, h.i1),
          }
          if h.i1 < b then
            cuts[#cuts + 1] = { t = ftime(F, h.i1 + 1), cf = sib_cf, element = true }
          end
          at = h.i1 + 1
        end
        if at <= b then
          phr.elements[#phr.elements + 1] = {
            class = "phrase", sig_i0 = at, sig_i1 = b,
            level_db = Levels.measure_element(F, at, b),
          }
        end
      end

      for k = phr.seg0, phr.seg1 do
        local seg = segments[k]
        -- Breath frames are already spoken for; scan around them, never
        -- through them, or the same audio would be classified twice.
        local at = seg.i0
        for _, b in ipairs(breaths) do
          if b.i1 >= seg.i0 and b.i0 <= seg.i1 then
            emit(at, math.min(b.i0, seg.i1 + 1) - 1)
            at = math.max(at, b.i1 + 1)
          end
        end
        emit(at, seg.i1)
      end
    end
  end

  -- Structural cuts last, now that every element extent is known.
  --
  -- They used to be placed first, from the gap list alone, and then any that
  -- landed inside a breath were dropped -- which silently deleted the boundary
  -- rather than moving it. On the test take that lost three of seven,
  -- including the section boundary in the 899 ms pause at 21.5 s: breaths now
  -- reach the valley floors, and a valley floor is exactly the quietest point
  -- in the pause, which is exactly where the cut was being put.
  --
  -- So the quietest frame is chosen from what is left of the safe zone once
  -- the elements are taken out of it. When an element covers the whole zone
  -- the boundary is not lost either: the element's own edges are already cuts
  -- and they already sit at valley floors, so the nearer one becomes the
  -- boundary and no second cut is added.
  -- Reference levels last, measured on what is left once every element has
  -- been taken out. This is the order Magnus asked for -- elements first, then
  -- the sections and phrases over them -- and the reason it matters is not the
  -- arithmetic: applying the offsets first and re-measuring moves a section by
  -- 0.014 dB and a phrase by 0.034, which is nothing. It matters because a
  -- node can be made *entirely* of elements, and then measuring it before they
  -- exist is measuring a breath and calling it a phrase.
  local owned, elspans = {}, {}
  for _, sec in ipairs(tree.sections) do
    for _, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do
        if el.class ~= "phrase" then
          for i = el.sig_i0, el.sig_i1 do owned[i] = true end
          elspans[#elspans + 1] = { t0 = ftime(F, el.sig_i0),
                                    t1 = ftime(F, el.sig_i1 + 1) }
        end
      end
    end
  end

  for _, sec in ipairs(tree.sections) do
    sec.level = Levels.measure(F, sec.i0, sec.i1, cfg, th.gate_db, owned)
    for _, phr in ipairs(sec.phrases) do
      phr.level = Levels.measure(F, phr.i0, phr.i1, cfg, th.gate_db, owned)
    end
  end

  local by_time = {}
  for _, c in ipairs(cuts) do by_time[c.t] = c end

  for _, g in ipairs(gaps) do
    local c = M.place_cut(F, g, cfg, owned)
    if c then
      -- If an element edge is already within a crossfade of the chosen point,
      -- that edge is the boundary. Adding a second cut a few milliseconds away
      -- leaves a span shorter than the fades that meet in it, and the longer
      -- fade then reaches straight past the shorter item -- which is how a
      -- 5.3 ms span with a 20 ms crossfade on it swallowed its neighbour.
      local adopted
      for _, e in ipairs(cuts) do
        if e.element and math.abs(e.t - c.t) < (e.cf + c.cf) / 2 then
          adopted = e
          break
        end
      end
      if adopted then
        g.cut = adopted
      else
        cuts[#cuts + 1] = c
        g.cut = c
      end
    else
      -- The pause is inside an element. Its boundary is that element's nearer
      -- edge, which is already a cut and already at a valley floor -- so the
      -- gap adopts it rather than a second cut being added a few frames away.
      local mid = (g.t0 + g.t1) / 2
      for _, e in ipairs(elspans) do
        if mid >= e.t0 and mid <= e.t1 then
          local edge = (mid - e.t0 <= e.t1 - mid) and e.t0 or e.t1
          g.cut = by_time[edge]
          break
        end
      end
    end
  end

  table.sort(cuts, function(a, b) return a.t < b.t end)
  tree.cuts = cuts
  tree.gate_db = th.gate_db
  return tree
end

-- Turn the tree into the flat list of items to create. Called after
-- Levels.cascade has assigned gains.
function M.spans(F, tree, cfg)
  -- Drop cuts that are too close together to carry their own crossfades.
  --
  -- "Too close" is decided by the crossfades that actually meet at the span
  -- between them, not by a constant. Each fade eats half its length off either
  -- side of its cut, so a span has to be at least (cf_in + cf_out) / 2 long or
  -- the fades overlap each other -- and REAPER expresses a crossfade by moving
  -- the right-hand item earlier, so a fade longer than the item to its left
  -- moves that item's neighbour *past* it and the timeline stops being
  -- ordered. A 5.3 ms span with a 5 ms fade on one side and a 20 ms fade on
  -- the other did exactly that.
  --
  -- When two cuts collide, an element edge wins over a structural one. The
  -- edge of a breath or an /s/ has to be exact, or the clip's gain runs into
  -- the audio either side of it; a cut in a pause only has to be somewhere
  -- quiet, and the element edge already is.
  local floor_sep = cfg.crossfade_min_ms / 1000 * 2
  local kept = {}
  for _, c in ipairs(tree.cuts) do
    local p = kept[#kept]
    if not p then
      kept[#kept + 1] = c
    else
      local need = math.max(floor_sep, (p.cf + c.cf) / 2)
      if (c.t - p.t) >= need then
        kept[#kept + 1] = c
      elseif c.element and not p.element then
        kept[#kept] = c
      end
    end
  end

  -- Which element owns each frame.
  local owner = {}
  for _, sec in ipairs(tree.sections) do
    for _, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do
        local o = { el = el, phr = phr, sec = sec }
        for i = el.sig_i0, el.sig_i1 do owner[i] = o end
      end
    end
  end

  local spans = {}
  local bounds = { 0 }
  for _, c in ipairs(kept) do bounds[#bounds + 1] = c.t end
  bounds[#bounds + 1] = F.item_len

  local gate = tree.gate_db or -math.huge

  for k = 1, #bounds - 1 do
    local t0, t1 = bounds[k], bounds[k + 1]
    if t1 - t0 > 1e-9 then
      -- A span is attributed by the audio it actually contains, not by what
      -- lies at its midpoint. Cuts sit inside pauses, so a span reaches well
      -- past its element on both sides and a midpoint lands wherever the
      -- surrounding silence happens to put it -- for a breath at the head of a
      -- take that was a coin toss between ducking it and missing it entirely.
      -- Counting gated-in frames asks the question that actually matters: what
      -- is this clip *of*?
      --
      -- This is the inverse of ftime and has to stay it: a bound came from
      -- ftime, so dividing by anything other than the same acc_frame_dur reads
      -- the tally off the wrong frames.
      local i0 = math.max(1, math.floor(t0 / F.acc_frame_dur) + 1)
      local i1 = math.min(F.n, math.ceil(t1 / F.acc_frame_dur) - 1)
      local tally, best, bestn = {}, nil, 0
      for i = i0, i1 do
        local o = owner[i]
        -- A detected element counts wherever it is. Breaths are scanned rather
        -- than gated, so the quietest of them sit below the gate entirely;
        -- requiring the gate here would hand every one of those clips back to
        -- its phrase and leave the breath untouched after all the work of
        -- finding it.
        if o and (F.level_db[i] > gate or o.el.class ~= "phrase") then
          local n = (tally[o] or 0) + 1
          tally[o] = n
          if n > bestn then bestn, best = n, o end
        end
      end

      -- Silence only: no element is *in* this clip, so it is a pause. It still
      -- belongs to a phrase, so find the nearest one -- but take that phrase's
      -- gain, never the element's. A pause carrying a breath's -6 dB puts a
      -- step in the room tone either side of every breath, which is both
      -- audible and the opposite of "only the detected segments are moved".
      local class, gain = "phrase", nil
      if best and best.el.class ~= "phrase" then
        class, gain = best.el.class, best.el.total_gain
      elseif best then
        gain = best.phr.total_gain
      else
        local mid, bd = (t0 + t1) / 2, math.huge
        for _, sec in ipairs(tree.sections) do
          for _, phr in ipairs(sec.phrases) do
            for _, el in ipairs(phr.elements) do
              local a, b = ftime(F, el.sig_i0), ftime(F, el.sig_i1 + 1)
              local d = mid < a and (a - mid) or (mid > b and (mid - b) or 0)
              if d < bd then bd, gain = d, phr.total_gain end
            end
          end
        end
      end

      if gain then
        spans[#spans + 1] = {
          t0 = t0, t1 = t1,
          cf_in  = (k > 1) and kept[k - 1].cf or 0,
          cf_out = (k < #bounds - 1) and kept[k].cf or 0,
          class = class, gain_db = gain,
        }
      end
    end
  end

  return spans
end

M.ftime = ftime
return M
