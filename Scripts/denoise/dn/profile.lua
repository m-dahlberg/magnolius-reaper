-- @noindex
-- Spectral DeNoise -- stage 2: pick the noise band out of the file histogram.
--
-- This is what replaces the JSFX's manual "Learn Noise Profile" pass. The
-- kernel has already reduced the whole file to a level-binned spectrogram: for
-- every 1 dB of broadband frame level it holds the summed power spectrum and
-- the frame count. Choosing a *level band* therefore chooses a set of frames,
-- and averaging their spectra gives exactly the quantity learn mode would have
-- accumulated by hand -- except the frames are picked by the distribution
-- rather than by the user finding a gap in the take.
--
-- Pure Lua. Everything here takes plain tables and returns numbers, so the
-- whole stage is testable without REAPER or audio.

local M = {}

local MIN_BAND_FRAMES = 30    -- below this the mean is too noisy to trust
local MAX_WIDEN_DB    = 30    -- how far the band may be widened to reach it
local PEAK_PROMINENCE = 0.4    -- a lobe must stand this far clear of its own col
local PEAK_RADIUS     = 3     -- bins either side it must dominate
local MIN_SEP_DB      = 12    -- a lobe closer than this to the signal reference
                              -- is not a noise floor, it is the material
local DEAD_FRAC       = 0.001 -- a level bin holding less of the file than this
                              -- holds nothing the recording actually visited
local ISLAND_GAP_DB   = 6     -- dead bins that separate an island from the rest

-- hist = { counts = { [0..nlev-1] = n }, lev0 = dB of bin 0, nlev, total }
function M.histogram(counts, nlev, lev0)
  local c, total = {}, 0
  for b = 0, nlev - 1 do
    local v = counts[b] or 0
    c[b] = v
    total = total + v
  end
  return { counts = c, nlev = nlev, lev0 = lev0, total = total }
end

function M.db_of(hist, bin) return hist.lev0 + bin end
function M.bin_of(hist, db)
  local b = math.floor(db - hist.lev0 + 0.5)
  if b < 0 then return 0 end
  if b > hist.nlev - 1 then return hist.nlev - 1 end
  return b
end

-- Percentile in dB, interpolated inside the bin so a coarse histogram still
-- moves smoothly. `from` skips the underflow bins.
function M.percentile(hist, p, from)
  from = from or 0
  local total = 0
  for b = from, hist.nlev - 1 do total = total + hist.counts[b] end
  if total == 0 then return hist.lev0 end
  local want, cum = total * p / 100, 0
  for b = from, hist.nlev - 1 do
    local c = hist.counts[b]
    if cum + c >= want then
      local frac = c > 0 and (want - cum) / c or 0
      return M.db_of(hist, b) - 0.5 + frac
    end
    cum = cum + c
  end
  return M.db_of(hist, hist.nlev - 1)
end

local function smooth(counts, nlev)
  local s = {}
  for b = 0, nlev - 1 do
    local a = counts[b - 1] or 0
    local c = counts[b + 1] or 0
    s[b] = (a + 2 * counts[b] + c) * 0.25
  end
  return s
end

-- Topographic prominence: how far the peak at `b` stands above the higher of
-- the two cols separating it from any taller peak. A peak with nothing taller
-- on a side is fully prominent on that side.
--
-- Height alone is the wrong test. A take with only brief pauses puts a few
-- hundred frames in the room-tone lobe against tens of thousands in the speech
-- lobe -- a lobe that is 3% as tall as the tallest but is still a clean,
-- isolated mode with seconds of room tone in it, and still exactly what we
-- want. Prominence sees that; a fraction-of-the-maximum threshold does not.
local function prominence(s, b, from, nlev)
  local h = s[b]
  local function col(step, stop)
    local m = h
    for j = b + step, stop, step do
      if s[j] > h then return m end
      if s[j] < m then m = s[j] end
    end
    return 0                    -- nothing taller that way: clear to the edge
  end
  return h - math.max(col(-1, from), col(1, nlev - 1))
end

local function is_local_max(s, b, from, nlev)
  for j = math.max(from, b - PEAK_RADIUS), math.min(nlev - 1, b + PEAK_RADIUS) do
    if s[j] > s[b] then return false end
  end
  return true
end

-- The lowest lobe that is a real mode of the distribution. Scanning upward
-- matters: in a take with pauses the room-tone lobe sits below the signal
-- lobe, and it is the one we want even when the signal lobe dwarfs it.
-- Returns a bin index, or nil if the histogram has no such structure.
local function find_noise_lobe(hist, from)
  local nlev = hist.nlev
  local s = smooth(hist.counts, nlev)
  for b = from, nlev - 1 do
    if s[b] > 0 and is_local_max(s, b, from, nlev)
       and prominence(s, b, from, nlev) >= PEAK_PROMINENCE * s[b] then
      -- and enough frames actually under it for a mean to mean anything
      local n = 0
      for j = math.max(from, b - PEAK_RADIUS), math.min(nlev - 1, b + PEAK_RADIUS) do
        n = n + hist.counts[j]
      end
      if n >= MIN_BAND_FRAMES then return b end
    end
  end
  return nil
end

-- Silence islands, and why the lowest lobe is not always the noise.
--
-- A recording's own noise floor is continuous with the material above it:
-- every phrase decays through it, so the histogram bins between the two are
-- populated. Edited-in silence is not continuous with anything. Strip-silence,
-- a hard noise gate, or the noise-shaped dither a 16-bit master carries in its
-- pauses all put a lobe on the histogram with a wide *dead* gap above it --
-- the recording never passed through those levels at all.
--
-- "DeNoise test 02.wav" is the case in point: 5700 frames of dithered digital
-- silence at -84 dB, twenty dB of nothing, then the real room tone at -59 dB
-- and the voice above that. Scanning up from the bottom finds the dither,
-- builds a profile 45 dB under the hiss, and the render is a measured 0.1 dB
-- no-op -- with the panel reporting a healthy 64 dB of separation the whole
-- time, because by every measure it had, it was.
--
-- A fixed dB threshold cannot do this job: the island's level is set by the
-- master's bit depth, not by the room, so it moves from file to file. The
-- shape does not.
--
-- The first bin past the dead gap above `b`, or nil if there is no such gap.
local function island_top(hist, b)
  local dead = hist.total * DEAD_FRAC
  local nlev = hist.nlev
  local gap, j = 0, b
  -- Walk up from the lobe. A dead stretch shorter than ISLAND_GAP_DB is a dip
  -- inside the lobe, not the end of it.
  while j <= nlev - 1 and gap < ISLAND_GAP_DB do
    gap = (hist.counts[j] > dead) and 0 or (gap + 1)
    j = j + 1
  end
  if gap < ISLAND_GAP_DB then return nil end          -- ran off the top
  while j <= nlev - 1 and hist.counts[j] <= dead do j = j + 1 end
  if j > nlev - 1 then return nil end
  return j
end

-- Frames inside [lo, hi] inclusive, in bins.
local function count_band(hist, lo, hi)
  local n = 0
  for b = lo, hi do n = n + hist.counts[b] end
  return n
end

local function clampi(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- Returns the band and everything the panel needs to explain it.
--   lo_bin, hi_bin, lo_db, hi_db   the chosen band
--   frames, fraction               how much of the file it selects
--   lobe_db                        the detected room-tone lobe, or nil
--   noise_floor, signal_ref        p10 / p85, for orientation
--   fallback                       true when no lobe was found and a low
--                                  percentile was used instead
--   warning                        one line, or nil
function M.band(hist, cfg)
  local silence_bin = M.bin_of(hist, cfg.silence_db)
  local from = math.min(silence_bin, hist.nlev - 1)
  local lobe = find_noise_lobe(hist, from)

  -- Step over silence islands -- but never into the programme material. A
  -- room-tone lobe can sit behind a dead gap too, on a take whose speech is
  -- loud and whose pauses are clean, and skipping that one would put the band
  -- on the voice. The test that separates the two is what waits above the gap:
  -- a genuine noise floor is still far below the material, and the material is
  -- not. So an island is only abandoned for a lobe that is itself a candidate.
  --
  -- The reference is p85 of the frames *above the gap*, not of the whole file:
  -- on a take that is mostly silence, p85 of everything lands inside the
  -- island and would argue that nothing is far enough below anything.
  local skipped
  if cfg.skip_silence ~= false then
    for _ = 1, 8 do                          -- a file may hold several islands
      if not lobe then break end
      local top = island_top(hist, lobe)
      if not top then break end
      local nxt = find_noise_lobe(hist, top)
      if not nxt then break end
      if M.db_of(hist, nxt) > M.percentile(hist, 85, top) - MIN_SEP_DB then
        break
      end
      skipped, from, lobe = M.db_of(hist, lobe), top, nxt
    end
  end

  local th = {
    noise_floor = M.percentile(hist, 10, from),
    signal_ref  = M.percentile(hist, 85, from),
    fallback    = false,
    skipped_db  = skipped,
    from_db     = M.db_of(hist, from),
  }

  th.lobe_db = lobe and M.db_of(hist, lobe) or nil

  -- How far the noise sits below the material. Not p10..p85: on a take that is
  -- almost all speech, p10 is *in* the speech and would report no separation
  -- even though a clean room-tone lobe is sitting right there.
  th.separation = th.signal_ref - (th.lobe_db or th.noise_floor)

  local lo_db, hi_db
  if not cfg.band_auto then
    lo_db, hi_db = cfg.band_lo_db, cfg.band_hi_db
  elseif lobe then
    lo_db = th.lobe_db - cfg.band_below_db
    hi_db = th.lobe_db + cfg.band_above_db
  else
    -- No mode to sit on: take the quietest tenth and say so.
    th.fallback = true
    lo_db = M.percentile(hist, 1, from)
    hi_db = M.percentile(hist, 10, from)
  end

  local lo = clampi(M.bin_of(hist, lo_db), from, hist.nlev - 1)
  local hi = clampi(M.bin_of(hist, hi_db), lo, hist.nlev - 1)

  -- Widen symmetrically until the mean has enough frames behind it. Only ever
  -- widens: a band the user set wide stays wide.
  local widened = 0
  while count_band(hist, lo, hi) < MIN_BAND_FRAMES and widened < MAX_WIDEN_DB do
    if lo > from then lo = lo - 1 end
    if hi < hist.nlev - 1 then hi = hi + 1 end
    if lo == from and hi == hist.nlev - 1 then break end
    widened = widened + 1
  end
  th.widened_db = widened

  th.lo_bin, th.hi_bin = lo, hi
  th.lo_db, th.hi_db = M.db_of(hist, lo), M.db_of(hist, hi)
  th.frames = count_band(hist, lo, hi)
  th.fraction = hist.total > 0 and th.frames / hist.total or 0

  if th.frames < MIN_BAND_FRAMES then
    th.warning = "Only " .. th.frames ..
      " frames in the noise band -- the profile will be unreliable."
  elseif th.separation < MIN_SEP_DB then
    th.warning = string.format(
      "The band sits only %.0f dB below the programme material: this file " ..
      "has no quiet passages to learn from, so the profile will contain " ..
      "signal as well as noise.", th.separation)
  elseif th.fraction > 0.9 then
    th.warning = "The band covers almost the whole file -- check it is not " ..
      "sitting on the programme material."
  end

  return th
end

M.MIN_BAND_FRAMES = MIN_BAND_FRAMES
M.island_top       = island_top
return M
