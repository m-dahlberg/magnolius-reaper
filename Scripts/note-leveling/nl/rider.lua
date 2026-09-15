-- @noindex
-- Note Leveling -- rider stage B: the macro ride.
--
-- Pure Lua. Takes the target's frames, the notes stage 2 found, and the mixed
-- reference level track, and returns one gain per segment plus the envelope
-- points that carry them. Nothing here knows what a REAPER envelope is.
--
-- Where part 1 asks "was that note louder than the other notes", this asks
-- "is that note sitting right against the arrangement" -- and the two answers
-- stack, because part 1 writes Pre-FX and this writes the fader.
--
--
-- Why the ride is stepped on notes -----------------------------------------
--
-- The standard failure of a vocal rider is that the settings that sound
-- natural are too slow to be right. Give a follower a time constant short
-- enough to catch the start of a word and it chatters inside the word; give it
-- one long enough to sound smooth and every phrase fades in, because the
-- correction arrives after the syllable it was for. Both symptoms are the same
-- bug: a follower can only respond to what has already happened.
--
-- Offline, that constraint is optional. The note segmentation already says
-- where every word begins, so the level for a word can be decided from the
-- whole word and then be *in place before the word starts*. That is what
-- `lookahead` does here, and it is the difference between a rider that fades
-- into phrases and one that nails them. Between segments the curve simply
-- holds -- there is nothing to follow in a gap, and following it is precisely
-- what makes a rider pump on breaths and room tone.
--
--
-- The gain law ---------------------------------------------------------------
--
-- Per segment, in dB, with R the reference level and T the target level, both
-- measured through the vocal band with a high percentile:
--
--   static  =  R_med + offset - T_med           the overall balance
--   follow  =  ref_follow * (R - R_med)         louder backing -> louder vocal
--   level   = -tgt_level  * (T - T_med)         softer word    -> more boost
--
--   gain    =  static + follow + level          (then smoothed, capped, trimmed)
--
-- At ref_follow = tgt_level = 100% this is exactly `R + offset - T`: a
-- constant-differential ride that pins the vocal a fixed distance above the
-- arrangement and cancels all of its own dynamics. At 0/0 it is a static gain
-- change. The two knobs are separate because the two behaviours are: following
-- the arrangement is nearly always wanted, cancelling the singer's dynamics is
-- a matter of how modern the record is.
--
-- The `level` term is the one the brief actually turns on -- it is what makes
-- a soft phrase rise further than a loud one under the *same* backing, which
-- no differential-only rider can do.
--
-- The medians are taken over the segments, not over the timeline: the balance
-- of a record is set by where the voice sits when it is singing, and an
-- instrumental break should not get a vote.

local Reference = require "nl.reference"

local M = {}

-- Measurement ---------------------------------------------------------------

-- A high percentile rather than a mean, on both sides. A sung note that opens
-- on a breath, or a bar of backing with a rest in it, has a mean well below
-- what it actually masks with; the 90th percentile reads the part of the
-- window that is doing the work. It is not the maximum, which would be a
-- single frame of a transient.
M.PERCENTILE = 90

-- Shortest stretch of arrangement worth judging a syllable against. A 70 ms
-- consonant still competes with a whole beat, so its reference window is
-- widened to this even though its own window would be shorter.
M.REF_FLOOR_MS = 200

-- A window has to be this covered by reference audio to count. Below it the
-- segment is marked no_ref and only the target term acts -- see the header of
-- reference.lua for why "uncovered" and "silent" must not be the same thing.
M.MIN_COVER = 0.5

-- Fallback segmentation ------------------------------------------------------
-- A rise of this much above the recent floor starts a new segment where there
-- is no note to start one. Deliberately coarse: this is standing in for a
-- syllable boundary, not detecting a transient.
M.ONSET_DB       = 6
M.ONSET_BACK_MS  = 120
M.FALLBACK_MIN_MS = 120

-- Curve ----------------------------------------------------------------------
-- A step in a gain envelope with no time in it is a click.
M.MIN_TRANS = 0.005
-- The most of a segment a transition may eat into, at either end. A segment
-- has to hold its own level for most of its length or the level was not for it.
M.BORROW_FRAC = 1 / 3

local FLOOR_DB = -120

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function median(t)
  if #t == 0 then return nil end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  return s[(#s + 1) // 2]
end

-- Frame index covering take time t, and the time frame i starts at. One place,
-- because an off-by-one here shifts every measurement by 5 ms in a way that
-- would only ever show as "it feels slightly late".
local function frame_at(F, t) return math.floor(t / F.hop_s) + 1 end
local function frame_time(F, i) return (i - 1) * F.hop_s end

-- Percentile of F.bp_db over frames [i0, i1]. Nil only if the window is empty.
local function window_db(F, i0, i1, pct)
  i0 = math.max(1, math.floor(i0))
  i1 = math.min(F.n, math.floor(i1))
  if i1 < i0 then return nil end
  local vals = {}
  for i = i0, i1 do vals[#vals + 1] = F.bp_db[i] or FLOOR_DB end
  table.sort(vals)
  local idx = clamp(math.ceil(#vals * pct / 100), 1, #vals)
  return vals[idx]
end

-- Segmentation ---------------------------------------------------------------

-- Split anything longer than seg_max into equal parts. Equal rather than
-- "first seg_max then the rest", so a 1.6 s note becomes two 0.8 s halves
-- rather than a second and a stub -- the stub would get its own level from a
-- window barely longer than itself and stand out.
local function subdivide(out, t0, t1, kind, note, seg_max)
  local len = t1 - t0
  if seg_max <= 0 or len <= seg_max then
    out[#out + 1] = { t0 = t0, t1 = t1, kind = kind, note = note }
    return
  end
  local parts = math.ceil(len / seg_max)
  for j = 0, parts - 1 do
    out[#out + 1] = {
      t0 = t0 + len * j / parts,
      t1 = t0 + len * (j + 1) / parts,
      kind = kind, note = note, part = j + 1, nparts = parts,
    }
  end
end

-- Where clustering found no note but there is still voice: rapped or spoken
-- lines, whispers, anything the pitch detector could not label. The level
-- track is all there is to go on, so segments are runs above the gate, cut at
-- level onsets. Without this a spoken bridge would inherit the gain of the
-- last sung note before it and hold it for eight bars.
local function fallback_segments(F, cfg, ta, tb, out)
  local gate = cfg.rider_gate_db
  local i0, i1 = frame_at(F, ta), math.min(frame_at(F, tb), F.n)
  local back = math.max(1, math.floor((M.ONSET_BACK_MS / 1000) / F.hop_s))
  local min_len = M.FALLBACK_MIN_MS / 1000

  local run0 = nil
  local function close(run1)
    if not run0 then return end
    local a, b = frame_time(F, run0), frame_time(F, run1 + 1)
    a, b = math.max(a, ta), math.min(b, tb)
    if b - a >= min_len then
      -- Cut the run at level onsets, so a spoken phrase steps per word rather
      -- than holding one level for the sentence.
      local cuts, last = { a }, a
      for i = run0 + 1, run1 do
        local lo = FLOOR_DB
        for j = math.max(run0, i - back), i - 1 do
          local v = F.bp_db[j] or FLOOR_DB
          if lo == FLOOR_DB or v < lo then lo = v end
        end
        local t = frame_time(F, i)
        if (F.bp_db[i] or FLOOR_DB) - lo >= M.ONSET_DB and t - last >= min_len
           and b - t >= min_len then
          cuts[#cuts + 1] = t
          last = t
        end
      end
      cuts[#cuts + 1] = b
      for c = 1, #cuts - 1 do
        subdivide(out, cuts[c], cuts[c + 1], "fallback", nil,
                  cfg.rider_seg_max_ms / 1000)
      end
    end
    run0 = nil
  end

  for i = i0, i1 do
    if (F.bp_db[i] or FLOOR_DB) > gate then
      run0 = run0 or i
    else
      close(i - 1)
    end
  end
  close(i1)
end

-- notes -> segments, with the holes filled in. Every segment carries the note
-- it came from (or nil) so the Pre-FX gain can be added back at measurement.
function M.segments(F, notes, cfg)
  local segs = {}
  local seg_max = cfg.rider_seg_max_ms / 1000
  local span = F.span or (F.n * F.hop_s)
  local prev_end = 0

  for _, n in ipairs(notes or {}) do
    if n.t0 - prev_end > M.FALLBACK_MIN_MS / 1000 then
      fallback_segments(F, cfg, prev_end, n.t0, segs)
    end
    subdivide(segs, n.t0, n.t1, "note", n, seg_max)
    prev_end = math.max(prev_end, n.t1)
  end
  if span - prev_end > M.FALLBACK_MIN_MS / 1000 then
    fallback_segments(F, cfg, prev_end, span, segs)
  end

  table.sort(segs, function(a, b) return a.t0 < b.t0 end)
  return segs
end

-- Measurement and gains -------------------------------------------------------

-- Stamps tgt_db, ref_db and gain_db onto each segment, in place.
--
-- R may be nil, which is the "no reference selected" case: every segment then
-- has no reference and the ride reduces to the target-leveling term alone,
-- which is a perfectly sensible thing to want on its own.
function M.measure(segs, F, R, cfg)
  local pct = M.PERCENTILE
  local tw  = cfg.rider_tgt_window_ms / 1000
  local rw  = cfg.rider_ref_window_ms / 1000
  local rfloor = M.REF_FLOOR_MS / 1000
  -- The Pre-FX note leveling is what the fader will actually see, so the
  -- target level the rider plans against is the measured level plus that gain.
  -- It is exact for the note leveling and blind to anything else in the chain
  -- -- a compressor between the two will have moved the signal again -- which
  -- is the one approximation in this stage and is documented as such.
  local use_pre = cfg.rider_after_notes

  for _, s in ipairs(segs) do
    local len = s.t1 - s.t0

    local ti0 = frame_at(F, s.t0)
    local ti1 = frame_at(F, s.t0 + math.min(len, tw)) - 1
    if ti1 < ti0 then ti1 = ti0 end
    s.raw_db = window_db(F, ti0, ti1, pct) or FLOOR_DB
    s.pre_db = (use_pre and s.note and s.note.gain_db) or 0
    s.tgt_db = s.raw_db + s.pre_db

    if R then
      local rlen = math.max(rfloor, math.min(len, rw))
      local ri0 = frame_at(F, s.t0)
      local ri1 = frame_at(F, s.t0 + rlen) - 1
      if ri1 < ri0 then ri1 = ri0 end
      s.ref_db, s.ref_cover = Reference.window_db(R, ri0, ri1, pct, M.MIN_COVER)
    end
    s.no_ref = (s.ref_db == nil)

    -- Below the gate the segment is not ridden at all: the curve holds through
    -- it. This is the answer to quiet passages being dragged up -- a breath or
    -- a room-tone tail asks for the biggest boost of anything on the take, and
    -- granting it is exactly the pumping a rider is accused of.
    s.gated = s.raw_db <= cfg.rider_gate_db
  end
  return segs
end

-- Reference and target medians, over the segments that are actually ridden.
function M.medians(segs)
  local T, Rv = {}, {}
  for _, s in ipairs(segs) do
    if not s.gated then
      T[#T + 1] = s.tgt_db
      if s.ref_db then Rv[#Rv + 1] = s.ref_db end
    end
  end
  return median(T), median(Rv)
end

-- The offset that would make the static term vanish -- i.e. that keeps the
-- balance the mix already has and lets the rider only redistribute it. The
-- panel offers this as a button, because "absolute" is the right model and an
-- unusable default: nothing says a vocal should sit at 0 dB against the sum of
-- everything else, and every record answers differently.
function M.match_offset(segs)
  local T_med, R_med = M.medians(segs)
  if not T_med or not R_med then return nil end
  return T_med - R_med
end

function M.gains(segs, cfg)
  local T_med, R_med = M.medians(segs)
  local follow = cfg.rider_ref_follow / 100
  local level  = cfg.rider_tgt_level / 100

  local static = 0
  if T_med and R_med then
    static = R_med + cfg.rider_offset_db - T_med
  elseif T_med then
    -- No reference at all. There is no balance to set, so the static term is
    -- the offset on its own and the ride is pure target leveling.
    static = cfg.rider_offset_db
  end

  for _, s in ipairs(segs) do
    if s.gated then
      -- Cleared, not merely left unset. Rider.run rebuilds the segments every
      -- time so nothing stale can survive today, but a caller that re-ran
      -- gains() over the same list after moving the gate would otherwise find
      -- a newly gated segment still carrying the gain it had before.
      s.raw_gain_db, s.smooth_gain_db, s.gain_db = nil, nil, nil
    else
      local f = (s.ref_db and R_med) and follow * (s.ref_db - R_med) or 0
      local l = T_med and -level * (s.tgt_db - T_med) or 0
      s.raw_gain_db = static + f + l
      s.follow_db, s.level_db_term = f, l
    end
  end

  M.smooth(segs, cfg)

  for _, s in ipairs(segs) do
    if s.smooth_gain_db then
      local g = clamp(s.smooth_gain_db,
                      -cfg.rider_max_cut_db, cfg.rider_max_boost_db)
      s.clamped = math.abs(g - s.smooth_gain_db) > 1e-9
      s.gain_db = g + cfg.rider_trim_db
    end
  end

  return segs, { T_med = T_med, R_med = R_med, static_db = static }
end

-- Zero-phase Gaussian over the per-segment gains, weighted by the time between
-- segment centres rather than by how many segments apart they are: a bar of
-- sixteenth notes and a bar of whole notes should smooth over the same
-- musical distance, and a segment count cannot express that.
--
-- Zero-phase because this is offline. A one-pole would lag by its own time
-- constant and reintroduce the exact fault the note stepping exists to remove.
function M.smooth(segs, cfg)
  local tau = cfg.rider_smooth_ms / 1000
  local idx = {}
  for _, s in ipairs(segs) do
    if s.raw_gain_db then idx[#idx + 1] = s end
  end
  if tau <= 0 then
    for _, s in ipairs(idx) do s.smooth_gain_db = s.raw_gain_db end
    return segs
  end

  local cut = 3 * tau
  for i, s in ipairs(idx) do
    local tc = (s.t0 + s.t1) / 2
    local acc, wsum = 0, 0
    for j = i, 1, -1 do
      local o = idx[j]
      local dt = tc - (o.t0 + o.t1) / 2
      if dt > cut then break end
      local w = math.exp(-0.5 * (dt / tau) ^ 2)
      acc, wsum = acc + w * o.raw_gain_db, wsum + w
    end
    for j = i + 1, #idx do
      local o = idx[j]
      local dt = (o.t0 + o.t1) / 2 - tc
      if dt > cut then break end
      local w = math.exp(-0.5 * (dt / tau) ^ 2)
      acc, wsum = acc + w * o.raw_gain_db, wsum + w
    end
    s.smooth_gain_db = wsum > 0 and acc / wsum or s.raw_gain_db
  end
  return segs
end

-- The curve -------------------------------------------------------------------

-- Returns { {t = take seconds, db = number}, ... }, strictly increasing in t.
--
-- The shape, in one paragraph: the curve holds each segment's gain across the
-- segment; the move to the next segment's gain is a raised cosine that is
-- FINISHED `lookahead` before that segment starts; and everywhere else it
-- holds. It never returns to unity between segments, which is the one place
-- this differs structurally from part 1's envelope -- for a corrective
-- envelope, unity between notes is the neutral thing to do; for a ride, it is
-- a dip back to the wrong level and would pump once per word.
function M.curve(segs, cfg, span)
  local pts = {}
  local ride = {}
  for _, s in ipairs(segs) do
    if s.gain_db then ride[#ride + 1] = s end
  end
  if #ride == 0 then return pts end

  local look  = cfg.rider_lookahead_ms / 1000
  local want  = math.max(cfg.rider_trans_ms / 1000, M.MIN_TRANS)
  local speed = math.max(cfg.rider_speed_db_s, 0.01)
  local res   = math.max(cfg.rider_point_ms, 1) / 1000

  local function add(t, dbv)
    local last = pts[#pts]
    if last then
      if t <= last.t + 1e-9 then
        if math.abs(dbv - last.db) <= 1e-12 then return end
        t = last.t + 1e-6
      end
    end
    pts[#pts + 1] = { t = t, db = dbv }
  end

  -- Raised cosine rather than a straight line: a linear ramp has a corner at
  -- both ends, and at these depths a corner is audible as the moment the ride
  -- started moving. This has zero slope at both.
  local function ramp(a, b, va, vb)
    local steps = math.max(2, math.ceil((b - a) / res))
    for j = 0, steps do
      local u = j / steps
      add(a + (b - a) * u, va + (vb - va) * 0.5 * (1 - math.cos(math.pi * u)))
    end
  end

  local function borrow(s) return (s.t1 - s.t0) * M.BORROW_FRAC end

  -- Before the first ridden segment the curve is simply already there. There
  -- is nothing to hear before the first word, and starting at unity would put
  -- a ramp across the count-in.
  add(0, ride[1].gain_db)

  local cursor = 0          -- how far the curve has been written to
  for i = 1, #ride do
    local s = ride[i]
    if i > 1 then
      local p = ride[i - 1]
      local delta = math.abs(s.gain_db - p.gain_db)
      -- Speed is a slew limit, so a big move simply takes longer rather than
      -- being truncated. It is what stops a 6 dB step between two adjacent
      -- syllables from being a jump.
      local trans = math.max(want, delta / speed)

      -- The window the transition has to live in: no earlier than the last
      -- third of the previous segment (and never before what is written), no
      -- later than the first third of this one.
      local lo = math.max(cursor, p.t1 - borrow(p))
      local hi = s.t0 + borrow(s)
      trans = clamp(trans, M.MIN_TRANS, math.max(hi - lo, M.MIN_TRANS))

      local te = math.min(s.t0 - look, hi)
      local ts = te - trans
      if ts < lo then ts, te = lo, lo + trans end

      if ts > cursor then add(ts, p.gain_db) end
      ramp(ts, te, p.gain_db, s.gain_db)
      cursor = te
    end
    if s.t1 > cursor then add(s.t1, s.gain_db) cursor = s.t1 end
  end

  -- And it stays where the last segment left it, for the same reason it
  -- started there.
  if span and span > cursor then add(span, ride[#ride].gain_db) end
  return pts
end

-- Everything, for callers that do not need the stages apart.
function M.run(F, notes, R, cfg)
  local segs = M.segments(F, notes, cfg)
  M.measure(segs, F, R, cfg)
  local _, stats = M.gains(segs, cfg)
  return segs, M.curve(segs, cfg, F.span), stats
end

-- Value of the curve at t, by linear interpolation in dB. The panel's readout
-- and the tests use it; the points are the output.
function M.value_at(pts, t)
  if #pts == 0 then return 0 end
  if t <= pts[1].t then return pts[1].db end
  if t >= pts[#pts].t then return pts[#pts].db end
  local lo, hi = 1, #pts
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if pts[mid].t <= t then lo = mid else hi = mid end
  end
  local dt = pts[hi].t - pts[lo].t
  if dt <= 0 then return pts[hi].db end
  return pts[lo].db + (pts[hi].db - pts[lo].db) * (t - pts[lo].t) / dt
end

M.FLOOR_DB = FLOOR_DB
M.window_db = window_db
M.frame_at = frame_at
return M
