-- @noindex
-- Note Leveling -- octave repair.
--
-- Pure Lua. Sits between the pitch track and the clustering and answers one
-- question per voiced frame: was that reading an octave out?
--
--
-- Why this cannot be fixed in the kernel ------------------------------------
--
-- The obvious idea is to have YIN report how periodic the frame looked at the
-- octave-related lags -- 2*tau for an octave down, tau/2 for an octave up --
-- and let the lower cost win. It does not work, and the reason is worth
-- writing down so nobody spends a day on it:
--
--   * cmnd(2*tau) is low for a CORRECT reading too. Anything periodic at T is
--     also periodic at 2T, so the difference function dips at every multiple
--     of the true period. That is the whole reason YIN takes the first dip
--     below the threshold rather than the deepest one.
--   * cmnd(tau/2) is high for every reading, by construction. The first-dip
--     rule already looked there and rejected it -- if it had been below the
--     threshold, that is the answer YIN would have returned.
--
-- So a single frame carries no evidence about its own octave. It never did.
-- The information lives in the frames on either side, which is why pYIN runs
-- an HMM over candidates rather than deciding frame by frame, and why this
-- file exists instead of twenty more lines of EEL.
--
--
-- What it does instead --------------------------------------------------------
--
-- A Viterbi over three states per voiced frame -- shift the reading down an
-- octave, leave it, shift it up -- with two costs:
--
--   transition   how far the pitch moves between adjacent voiced frames, in
--                semitones. Cancelling a spurious octave jump makes the track
--                continuous and costs nothing; introducing one costs 12.
--   emission     a small per-frame charge for being shifted at all, which is
--                what stops the whole take from sliding an octave and what
--                decides how long a shift has to last before it is believed.
--
-- The emission charge is set FROM `octave_hold_ms` rather than being a free
-- number. An excursion that goes up an octave and comes back pays 12 semitones
-- at each edge, so correcting it saves 24; holding the correction for n frames
-- costs n * emission. Setting emission = 24 * hop / hold puts the break-even
-- at exactly `hold` milliseconds, which makes the control say what it means:
-- **an octave change shorter than this is a detection error, longer than it is
-- the melody.** A singer who really does leap an octave and stay there keeps
-- the leap; the half-second flicker in the middle of a held note does not.
--
-- This is the one place the script leans on being for voices. An instrument
-- that arpeggiates across octaves would be mangled by it, and the control to
-- turn it off is there for that reason.

local M = {}

-- The plausible-range charge. A shifted candidate outside the pitch range the
-- detector was told to search is not impossible -- that is where a note the
-- detector could only see a harmonic of would live -- but it is a claim about
-- audio nobody looked at, so it has to earn its place.
M.OUT_OF_RANGE = 12

-- How steeply an out-of-register pitch is doubted, per semitone-squared
-- outside the dead zone. Calibrated against the per-frame emission charge: at
-- the default hold that charge is 0.12, so a pitch three semitones outside the
-- range costs 0.18 and is already doubted, while one semitone outside costs
-- 0.02 and is not. See the register comment in solve().
M.REGISTER_W = 0.02

-- The register is re-measured from each round's answer, so the rounds are
-- iterated until they agree. Three is a cap, not a plan: a round can only move
-- whole octaves and in practice the second one already settles.
local MAX_ROUNDS = 3

-- One octave, in the semitone units the transition cost is measured in.
local OCT = 12

-- Both edges of an excursion, which is what correcting one saves.
local EDGES = 2 * OCT

local SHIFTS = { -1, 0, 1 }

-- The same voicing test the clustering uses. It lives here because this stage
-- runs first and cluster.lua asks for it, rather than the two keeping their
-- own copies and disagreeing about which frames are pitch at all.
function M.voiced(F, i, cfg)
  return (F.aper[i] or 1) < cfg.yin_threshold
     and (F.level_db[i] or -120) > cfg.voice_gate_db
     and (F.f0[i] or 0) > 0
end

function M.midi(hz) return 69 + 12 * math.log(hz / 440, 2) end

-- Everything that changes the answer. Cached on the frame table under this,
-- so the panel's plot and the clustering share one repair rather than each
-- running their own -- and so dragging a leveling slider does not redo it.
local function signature(cfg)
  return table.concat({
    tostring(cfg.octave_fix), cfg.octave_hold_ms, cfg.octave_link_ms,
    cfg.octave_range,
    cfg.yin_threshold, cfg.voice_gate_db, cfg.min_hz, cfg.max_hz, cfg.hop_ms,
  }, "|")
end

-- One Viterbi pass. `centre` is the take's own register in MIDI, or nil for
-- the first pass, which has no register to speak of yet. Returns a shift per
-- entry of `idx`.
local function solve(F, cfg, idx, m, centre, half)
  local hop_ms = cfg.hop_ms
  local hold = math.max(cfg.octave_hold_ms, hop_ms)
  local emit = EDGES * hop_ms / hold
  local link = cfg.octave_link_ms

  -- The register charge. Quadratic outside a dead zone rather than linear from
  -- the median, and the difference is the whole safety of the thing: a linear
  -- pull toward the median would collapse every phrase into the median's
  -- octave, because for any note at all the nearer octave is the one closer to
  -- the middle. A dead zone says nothing about pitches inside the singer's
  -- range -- which is nearly all of them -- and the square then rises slowly
  -- just outside it and steeply far outside, so a high note that is merely
  -- high survives and one that is a whole octave out of range does not.
  local function register(hz)
    if not centre or not half or half <= 0 then return 0 end
    local over = math.abs(M.midi(hz) - centre) - half
    if over <= 0 then return 0 end
    return M.REGISTER_W * over * over
  end

  local function emission(j, s)
    local hz = F.f0[idx[j]] * 2 ^ s
    local c = emit * math.abs(s) + register(hz)
    if s ~= 0 and (hz < cfg.min_hz or hz > cfg.max_hz) then
      c = c + M.OUT_OF_RANGE
    end
    return c
  end

  local INF = math.huge
  local cost, back = {}, {}
  cost[1] = {}
  for si, s in ipairs(SHIFTS) do cost[1][si] = emission(1, s) end

  for j = 2, #idx do
    -- A long enough silence between two voiced frames is a phrase boundary,
    -- not a melodic interval. Coupling across it would let a breath decide
    -- which octave the next line is sung in.
    local linked = (idx[j] - idx[j - 1]) * hop_ms <= link
    cost[j], back[j] = {}, {}
    for si, s in ipairs(SHIFTS) do
      local best, bestk = INF, 1
      for pi, ps in ipairs(SHIFTS) do
        local t = cost[j - 1][pi]
        if linked then
          t = t + math.abs((m[j] + OCT * s) - (m[j - 1] + OCT * ps))
        end
        if t < best then best, bestk = t, pi end
      end
      cost[j][si] = best + emission(j, s)
      back[j][si] = bestk
    end
  end

  local si, best = 1, INF
  for k = 1, #SHIFTS do
    if cost[#idx][k] < best then best, si = cost[#idx][k], k end
  end
  local shift = {}
  for j = #idx, 1, -1 do
    shift[j] = SHIFTS[si]
    si = back[j] and back[j][si] or si
  end
  return shift
end

-- The singer's register under a given set of shifts: where the voice sits, and
-- how far it wanders. Both are taken as MEDIANS, which is what lets them
-- survive the errors they are being used to find -- the wrong octaves have to
-- outnumber the right ones before either moves.
--
-- The width matters as much as the centre. A fixed dead zone has to be set for
-- the widest singer it might meet, and is then far too generous for a narrow
-- one: on the take this was built against the voice spans barely ten semitones
-- end to end, so a note twelve above the median is obviously suspect -- and a
-- fixed half of ten would have called it fine. Three times the median absolute
-- deviation tracks that, and `octave_range` becomes the floor under it rather
-- than the whole answer, so a genuinely wide melody widens its own dead zone
-- instead of being flattened into the middle of itself.
local MAD_K = 3

local function register_of(m, shift, floor_semitones)
  local v = {}
  for j = 1, #m do v[j] = m[j] + OCT * shift[j] end
  if #v == 0 then return nil, nil end
  table.sort(v)
  local centre = v[(#v + 1) // 2]

  local dev = {}
  for j = 1, #v do dev[j] = math.abs(v[j] - centre) end
  table.sort(dev)
  local mad = dev[(#dev + 1) // 2]

  return centre, math.max(floor_semitones, MAD_K * mad)
end

-- Returns f0, nmoved, moved -- a NEW pitch array, how many frames were
-- shifted, and a per-frame shift in octaves for anything that wants to draw
-- what happened. F.f0 itself is never touched: it belongs to the analysis
-- cache, and the octave settings are not analysis settings.
function M.repair(F, cfg)
  local sig = signature(cfg)
  if F._oct_sig == sig then return F._oct, F._oct_n, F._oct_moved end

  local out, moved, nmoved = {}, {}, 0
  for i = 1, F.n do out[i] = F.f0[i] end

  local idx = {}
  if cfg.octave_fix then
    for i = 1, F.n do
      if M.voiced(F, i, cfg) then idx[#idx + 1] = i end
    end
  end

  if #idx >= 2 then
    local m = {}
    for j, i in ipairs(idx) do m[j] = M.midi(F.f0[i]) end

    -- Continuity first, with no register in hand; then the register measured
    -- from that answer, then again with it. Two rounds because the first one
    -- has to be told what the take's register IS, and the pitch track is the
    -- only thing that knows -- errors and all. Repeated until it settles, at
    -- most a few times: each round can only move whole octaves, so there is
    -- nothing to converge slowly toward.
    local shift = solve(F, cfg, idx, m, nil, nil)
    for _ = 1, MAX_ROUNDS do
      local centre, half = register_of(m, shift, cfg.octave_range)
      local next_shift = solve(F, cfg, idx, m, centre, half)
      local same = true
      for j = 1, #idx do
        if next_shift[j] ~= shift[j] then same = false break end
      end
      shift = next_shift
      if same then break end
    end

    for j, i in ipairs(idx) do
      local sj = shift[j]
      if sj ~= 0 then
        out[i] = F.f0[i] * 2 ^ sj
        moved[i] = sj
        nmoved = nmoved + 1
      end
    end
  end

  F._oct, F._oct_n, F._oct_moved, F._oct_sig = out, nmoved, moved, sig
  return out, nmoved, moved
end

return M
