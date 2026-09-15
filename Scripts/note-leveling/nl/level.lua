-- @noindex
-- Note Leveling -- stage 3: gains, and the shape of the envelope that carries
-- them.
--
-- Pure Lua. Takes the notes stage 2 found and returns a list of envelope
-- points in dB against source time; nothing here knows what a REAPER envelope
-- is.
--
-- Where this deliberately differs from the Vocal Editor: that app CLAMPS a
-- note to the floor or ceiling, and always fills the entire gap between notes
-- with a ramp. Here the move is PROPORTIONAL -- `amount` percent of the way
-- back to the edge that was crossed -- and the ramp length is a parameter, so
-- long gaps rest at unity gain in the middle instead of sliding between two
-- notes across half a second of silence.
--
-- Two envelope shapes, chosen by `glide_notes`:
--
--   * the default, described above: every gap with room for both ramps falls
--     to unity and rests there, so what lies between two notes keeps its own
--     level;
--   * glide: the gain never returns to unity at all. It runs straight from one
--     note's gain to the next's across the whole gap, and the outer two notes
--     hold their gain to the clip edges.
--
-- The default is the honest one when only some notes are corrected -- it moves
-- notes and nothing else. It fails when NEIGHBOURING notes are both cut: the
-- consonant, breath or room tone between them is the one thing left at unity,
-- so a pre-FX cut meant to even out the melody ends up promoting the noise
-- between it. Glide is the answer to that -- it carries the correction across
-- the gap -- at the price of applying a gain to material that was never
-- measured.

local M = {}

-- A boundary with no gap at all still has to be crossed in finite time: a
-- vertical step in a gain envelope is a click. When the window a transition
-- has to live in is shorter than this, it borrows symmetrically from the notes
-- on either side and becomes a short crossfade.
local MIN_TRANS = 0.005

-- Never borrow more than this fraction of a note, so the middle of even a very
-- short note is still held at its own gain.
local BORROW_FRAC = 1 / 3

-- The whole leveling rule. A note inside the window is left alone; one outside
-- moves `amount` percent of the way back to the edge it crossed, and the move
-- is then clamped.
--   -6 dB against a -7 dB ceiling at 100% -> -1.0 dB
--                                at  50% -> -0.5 dB
--
-- The clamp is applied AFTER the amount, not before, so the two controls read
-- the way they look: `amount` is how much of the correction you want, and the
-- limits are the most any single note may move whatever that works out to.
-- They are separate per direction because the directions are not symmetric --
-- a boost lifts the note's own noise floor with it, a cut does not.
function M.gain_db(rms_db, cfg)
  local target
  if rms_db > cfg.ceiling_db then
    target = cfg.ceiling_db
  elseif rms_db < cfg.floor_db then
    target = cfg.floor_db
  else
    return 0
  end
  local g = (target - rms_db) * cfg.amount / 100
  if g > cfg.max_boost_db then return cfg.max_boost_db, true end
  if g < -cfg.max_cut_db then return -cfg.max_cut_db, true end
  return g, false
end

-- Whether a note's move was cut short by the limits. Recorded when the gain is
-- computed rather than inferred afterwards by comparing against the limit: a
-- note whose honest gain happens to land exactly on the limit is not clamped,
-- and the panel marks clamped notes in red.
function M.is_clamped(note) return note.clamped == true end

-- Stamps gain_db onto each note, in place, and returns the same list.
function M.gains(notes, cfg)
  for _, n in ipairs(notes) do
    n.gain_db, n.clamped = M.gain_db(n.rms_db, cfg)
  end
  return notes
end

-- Envelope ---------------------------------------------------------------

local function widen(a, b, room_before, room_after)
  local short = MIN_TRANS - (b - a)
  if short <= 0 then return a, b end
  local fwd  = math.min(short * 0.5, math.max(room_after, 0))
  local back = math.min(short - fwd, math.max(room_before, 0))
  fwd = math.min(short - back, math.max(room_after, 0))
  return a - back, b + fwd
end

-- Returns { {t = <source seconds>, db = <number>}, ... }, strictly increasing
-- in t. An empty note list produces no points -- there is nothing to say.
function M.envelope(notes, cfg, span)
  if #notes == 0 then return {} end

  local ri  = cfg.ramp_in_ms  / 1000
  local ro  = cfg.ramp_out_ms / 1000
  local res = math.max(cfg.ramp_res_ms, 1) / 1000

  local pts = {}
  local function add(t, dbv)
    local last = pts[#pts]
    if last then
      if t <= last.t + 1e-9 then
        if math.abs(dbv - last.db) <= 1e-12 then return end
        t = last.t + 1e-6              -- keep the list strictly increasing
      end
    end
    pts[#pts + 1] = { t = t, db = dbv }
  end

  -- A ramp is subdivided rather than left as two points. REAPER interpolates
  -- linearly in the envelope's own stored domain, which is not dB, so a
  -- two-point ramp would be the wrong curve; emitting the exact dB value every
  -- `res` makes it right whatever the scaling mode is.
  local function ramp(a, b, va, vb)
    -- A flat span is exactly a flat span at any density, whatever domain the
    -- envelope stores. Worth the special case because glide mode's gaps are
    -- unbounded in length -- an instrumental section between two uncorrected
    -- notes would otherwise cost a point every `res` for its whole duration.
    if math.abs(vb - va) <= 1e-12 then add(a, va) add(b, vb) return end
    local steps = math.max(1, math.ceil((b - a) / res))
    for j = 0, steps do
      add(a + (b - a) * j / steps, va + (vb - va) * j / steps)
    end
  end

  local function borrow(n) return (n.t1 - n.t0) * BORROW_FRAC end

  -- Glide: no unity anywhere. The first note's gain reaches back to the start
  -- of the clip, every gap is one linear transition from the gain on its left
  -- to the gain on its right, and the last note's gain holds to the end.
  --
  -- Ramp in and ramp out have nothing to say here -- a transition's length is
  -- the gap it has to cross -- but `widen` still is, for the same reason as
  -- below: two notes butted together leave no room at all, and a vertical step
  -- in a gain envelope is a click.
  if cfg.glide_notes then
    local first = notes[1]
    add(0, first.gain_db)
    add(first.t0, first.gain_db)

    for k = 1, #notes do
      local n, nx = notes[k], notes[k + 1]
      if nx then
        local ta, tb = widen(n.t1, nx.t0, borrow(n), borrow(nx))
        add(ta, n.gain_db)
        ramp(ta, tb, n.gain_db, nx.gain_db)
      else
        add(n.t1, n.gain_db)
        if span > n.t1 then add(span, n.gain_db) end
      end
    end

    return pts
  end

  -- Lead-in: from unity gain up to the first note's gain.
  local first = notes[1]
  local a, b = math.max(0, first.t0 - ri), first.t0
  a, b = widen(a, b, a, borrow(first))
  if a > 0 then add(0, 0) end
  ramp(a, b, 0, first.gain_db)

  for k = 1, #notes do
    local n, nx = notes[k], notes[k + 1]
    if nx then
      local gap = nx.t0 - n.t1
      if ri + ro > 0 and gap >= ri + ro then
        -- Room for both ramps: fall to unity, rest there, rise into the next
        -- note. This is what keeps a consonant or a breath between two notes
        -- at its own level instead of inheriting a neighbour's correction.
        add(n.t1, n.gain_db)
        ramp(n.t1, n.t1 + ro, n.gain_db, 0)
        add(nx.t0 - ri, 0)
        ramp(nx.t0 - ri, nx.t0, 0, nx.gain_db)
      else
        -- Not enough room. Go straight from one note's gain to the other's
        -- rather than dipping to unity and back, which at these timescales
        -- would be an audible flutter between every pair of notes.
        local ta, tb = widen(n.t1, nx.t0, borrow(n), borrow(nx))
        add(ta, n.gain_db)
        ramp(ta, tb, n.gain_db, nx.gain_db)
      end
    else
      local ta, tb = n.t1, math.min(span, n.t1 + ro)
      ta, tb = widen(ta, tb, borrow(n), span - tb)
      add(ta, n.gain_db)
      ramp(ta, tb, n.gain_db, 0)
      if tb < span - 1e-9 then add(span, 0) end
    end
  end

  return pts
end

-- Value of the envelope at time t, by linear interpolation in dB. Only used by
-- the panel's display and by the tests; the points themselves are the output.
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

M.MIN_TRANS = MIN_TRANS
return M
