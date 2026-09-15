-- @noindex
-- Adaptive De-Click -- where the recording stops and the edit begins.
--
-- The threshold this script derives is read off the shape of the OVERSHOOT
-- distribution: how far each candidate stood above its own local background.
-- Overshoot is a ratio, and that is the detector's great strength -- a click in
-- a loud passage and a click in a quiet one land in the same place, so the
-- estimators see one population rather than a smear of level.
--
-- It is also a blind spot. A passage that holds no audio at all still has a
-- foreground and a background, and the ratio between them is a perfectly
-- ordinary small number. Strip-silence, a hard noise gate, or the noise-shaped
-- dither a 16-bit master carries in its pauses therefore fill the survey with
-- candidates that are not events: they are the dither fluctuating against
-- itself.
--
-- They never survive a threshold -- measured on a take with 27 % stripped
-- pauses, the two overshoot histograms were identical event for event above
-- 4 dB -- so nothing is repaired that should not be. But 1908 of 9308
-- candidates came from silence, and `tail_departure` anchors its fit on
-- p50..p95 of the distribution, so they drag those anchors down and the
-- derived threshold with them. Measured at three silence ratios, against the
-- same audio with the silence trimmed off:
--
--     27 % silence   8.88 dB   vs   9.12 dB    -0.24 dB
--     67 % silence   6.12 dB   vs   9.12 dB    -3.00 dB
--     80 % silence   6.12 dB   vs   8.12 dB    -2.00 dB
--
-- and the drift is in the AGGRESSIVE direction, which is the wrong one: this
-- script's whole bias is that a missed click is recoverable by ear and a
-- chewed consonant is not.
--
-- So the kernel also builds a histogram of the file's own broadband step-peak
-- level during analysis, and this stage reads off it the level below which
-- there is no recording. Pure Lua, no reaper dependency, unit-testable.
--
-- Why the file's level and not the candidates' own: a candidate's foreground
-- is a BAND peak, and the kernel adds a -100 dB guard to those, which
-- compresses every silent step into the same few buckets. Measured, the
-- candidate levels from dither and from the quietest real material were three
-- buckets apart -- too close to build a rule on. The broadband step level
-- separates them by twenty.

local M = {}

-- A bucket holding fewer steps than this is empty for our purposes. The floor
-- is absolute on purpose: a share of the total scales with the SILENCE, so on
-- a file that is mostly silence it grows until the material's own sparse
-- mid-range reads as empty and the search walks straight through it. Measured
-- at 0.2 % on a 67 %-silent file: the buckets from -46 to -39 dB held 2 to 7
-- steps each against a threshold of 12, so the rule found a second "gap" in
-- the middle of the speech and put the floor 20 dB too high.
local DEAD_MIN      = 2
local DEAD_FRAC     = 0.0002
-- Empty buckets that mark a population as detached from everything else. The
-- histogram is 1 dB wide, so this is 8 dB of nothing. A recording's own noise
-- floor is CONTINUOUS with the material above it -- every phrase decays
-- through it -- so a population with a wide dead run above it was not made by
-- the microphone.
local GAP_DB        = 8
-- Guards. Never step over most of the file, and never leave so little that
-- what remains says nothing.
local MAX_SKIP_FRAC = 0.95
local MIN_KEPT_FRAC = 0.02
-- Headroom under the first real level, in dB. The point is to remove a
-- population twenty dB away, not to shave the edge.
local HEADROOM_DB   = 6

function M.db_of(h, b) return h.lo + (b + 0.5) * h.bin end

-- Find the level below which there is no recording.
--
-- Returns a table:
--   floor_db    dBFS to reject below, or nil if there is nothing to reject
--   skipped     steps below it
--   total       steps in the histogram
--   refused     an island was found but a guard stopped it being applied
--
-- MAX_SKIP_FRAC is deliberately loose here, and that is the opposite of the
-- call the same rule makes in DeResonate. There, stepping over a population
-- MOVES a percentile, so eating signal silently changes an answer. Here it can
-- only ever remove candidates, and a candidate removed is at worst a click
-- left in the file -- which is the recoverable direction. A dialogue take that
-- is 80 % stripped pauses is entirely ordinary, and refusing on it would leave
-- the 3 dB drift in place on exactly the files that suffer it most.
function M.floor(hist)
  local out = { floor_db = nil, skipped = 0, total = 0, refused = false }
  if not hist or not hist.counts then return out end

  local n = hist.n
  local total = 0
  for b = 0, n - 1 do total = total + (hist.counts[b] or 0) end
  out.total = total
  if total == 0 then return out end

  local dead = math.max(DEAD_MIN, total * DEAD_FRAC)
  local from, skipped = 0, 0

  for _ = 1, 8 do                        -- a file may hold more than one island
    local b = from
    while b < n and (hist.counts[b] or 0) < dead do b = b + 1 end
    if b >= n then break end
    from = b

    local gap, j = 0, b
    while j < n and gap < GAP_DB do
      gap = ((hist.counts[j] or 0) >= dead) and 0 or (gap + 1)
      j = j + 1
    end
    if gap < GAP_DB then break end       -- no gap above: b is the floor

    -- Every histogram ends in empty buckets -- the axis reaches 0 dBFS and
    -- nothing reaches it. That is the end of the distribution, not a gap in
    -- it; a gap needs something on the far side.
    local nxt = j
    while nxt < n and (hist.counts[nxt] or 0) < dead do nxt = nxt + 1 end
    if nxt >= n then break end

    local below = 0
    for i = 0, nxt - 1 do below = below + (hist.counts[i] or 0) end
    if below > total * MAX_SKIP_FRAC
       or total - below < total * MIN_KEPT_FRAC then
      out.refused, out.skipped = true, below
      return out
    end
    from, skipped = nxt, below
  end

  if skipped > 0 then
    out.skipped = skipped
    out.floor_db = M.db_of(hist, from) - HEADROOM_DB
  end
  return out
end

return M
