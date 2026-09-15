-- @noindex
-- The multiband gate/expander: the law, the band fold, and what the analysis
-- suggests.
--
-- WHY THIS EXISTS BESIDE THE DEREVERB. The spectral stage in `dr/gains.lua`
-- subtracts a decayed copy of what each bin held a few frames ago, and for
-- STATIONARY material that reduces to `snr = 60*tau/T60` with the reverb level
-- absent from the expression -- so on a sung phrase with no gaps it moves the
-- level by 0.40 dB, measured in `test/sustained_in_reaper.lua`, and no setting
-- of T60, reduction or strength changes it. The material it cannot help with
-- is material that never stops.
--
-- A gate has the opposite shape. It can do nothing at all under a held note --
-- the level never falls -- and it is at its best exactly where the spectral
-- stage is weakest: the exposed pause, where the tail is unmasked and the
-- decision is easy. Neither replaces the other, which is the whole argument
-- for carrying both.
--
-- TWO DOMAINS, one law. The same thresholds, ranges and releases drive either
-- a band gain inside the dereverb's STFT or a Linkwitz-Riley filterbank in the
-- time domain, and `gate_domain` chooses. They differ in what they are good at
-- rather than in what they do:
--
--   spectral    phase untouched, so the residual render stays a clean
--               diagnostic and the stage cannot clip an onset; no crossover
--               interference when neighbouring bands move differently. Costs a
--               window of latency, decides on a ~43 ms grain, and has a
--               pre-echo of one window before every onset.
--   filterbank  sample-accurate, zero latency, no pre-echo, and the classic
--               build. Costs allpass phase even while inert -- which is what
--               makes its residual much less useful -- and the crossover
--               regions move when adjacent bands gate differently.
--
-- Serves three consumers, as `dr/gains.lua` does: the panel draws the
-- thresholds from it, the headless suite checks the law without REAPER, and
-- the EEL in `dr/dsp/deresonate.eel` must reproduce `gain_db` and `step`
-- exactly in both.
--
-- Pure Lua: imports no `reaper`.

local M = {}

-- Eight bands, roughly octave-spaced. These are the CROSSOVERS, so band 1 is
-- everything below 90 Hz and band 8 everything above 5600.
M.EDGES  = { 90, 180, 360, 720, 1400, 2800, 5600 }
M.NBANDS = #M.EDGES + 1

M.RANGE_MAX     = 30.0   -- what amount 100% asks for, before the floor clamp
M.GATE_BELOW_DB = 12.0   -- how far under the band's working level the threshold
                         -- sits. See `suggest` for why this, and not the pause
                         -- level, is the reference.
M.VOICE_MARGIN  = 6.0    -- the closest to that level it may ever be pushed
M.MIN_SEP_DB    = 8.0    -- below this the pause and the voice are not separated
M.FLOOR_HEAD_DB = 3.0    -- a threshold at the noise floor never triggers
M.MIN_PAUSE_N   = 50     -- frames; a percentile over a handful is not one
M.HYST_DB       = 3.0    -- gate mode only; an expander is continuous
M.HOLD_S        = 0.030
M.REL_DIV       = 4.0    -- release = T60/4: slower than that and the gate just
                         -- follows the room down and removes nothing
M.REL_MIN, M.REL_MAX = 0.03, 0.50

-- The filterbank's detector is a mean square; the analysis reports a band as a
-- power sum normalised by N^2/8, the SINGLE-BIN coherent-gain constant. Those
-- are not the same number. For broadband content Parseval gives
-- sum|X|^2 = N^2 * 0.375 * sigma^2, so dividing by N^2/8 lands
-- 10*log10(0.375/0.125) = 4.77 dB above the mean square -- the same constant
-- the README warns about in the other direction, where using the broadband
-- 0.375 on one bin reads 4.77 dB low.
--
-- Without this offset every threshold the analysis suggests would sit 4.8 dB
-- too high for the filterbank and it would gate far less than the spectral
-- path on the same settings. On a pure TONE the two still differ by
-- 10*log10(1.5) = 1.76 dB, because a Hann main lobe sums to one and a half
-- times its peak bin; a reverb tail is broadband, which is the case worth
-- matching. test/selftest_in_reaper.lua drives both domains with the same
-- noise and asserts they agree.
M.FB_OFFSET_DB = 10 * math.log(0.375 / 0.125, 10)

-- Percentiles of the per-band level distributions. `pause` describes where a
-- band sits once the voice has stopped; it is read near the top, because the
-- distribution is a decay and its middle is the very end of the tail.
M.PAUSE_PCT = 0.95
M.VOICE_PCT = 0.90
M.FLOOR_PCT = 0.10

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- 1-based band index for a frequency.
function M.band_of(hz)
  for i = 1, #M.EDGES do
    if hz < M.EDGES[i] then return i end
  end
  return M.NBANDS
end

-- Lower and upper edge of band `g`. The open ends are 0 and infinity, which is
-- what the band map in the kernel must also do, or bins fall through.
function M.band_range(g)
  local lo = (g == 1) and 0 or M.EDGES[g - 1]
  local hi = (g == M.NBANDS) and math.huge or M.EDGES[g]
  return lo, hi
end

function M.band_label(g)
  if g == 1 then return string.format("below %d Hz", M.EDGES[1]) end
  if g == M.NBANDS then return string.format("above %d Hz", M.EDGES[#M.EDGES]) end
  return string.format("%d-%d Hz", M.EDGES[g - 1], M.EDGES[g])
end

-- dB at percentile `p` of a level histogram, 1 dB buckets from `lev0`. `from`
-- is the first bucket that is part of the recording, which is how edited-in
-- silence is stepped over -- the same argument `Kernel:ring_hist` applies to
-- its p10 floors.
-- Returns the dB and the population it was taken over, so a caller can refuse
-- a percentile that rests on a handful of frames.
function M.percentile_db(hist, lev0, p, from)
  from = from or 1
  local total = 0
  for i = from, #hist do total = total + hist[i] end
  if total <= 0 then return nil, 0 end
  local want, run = p * total, 0
  for i = from, #hist do
    run = run + hist[i]
    if run >= want then return lev0 + (i - 1), total end
  end
  return lev0 + (#hist - 1), total
end

-- Fold per-1/12-octave-band levels into the eight gate bands.
--
-- THIS IS A POWER SUM, NOT A MEDIAN OF dB. A gate band spans up to twelve
-- analysis bands, and twelve equal bands sum to 10*log10(12) = 10.79 dB above
-- any one of them. Taking a median instead puts every threshold about 10 dB
-- low, and it looks entirely plausible while doing it.
function M.fold(db, hz, nband)
  local out, n = {}, {}
  for g = 1, M.NBANDS do out[g], n[g] = 0, 0 end
  for b = 1, (nband or #hz) do
    if db[b] and hz[b] then
      local g = M.band_of(hz[b])
      out[g] = out[g] + 10 ^ (db[b] / 10)
      n[g] = n[g] + 1
    end
  end
  for g = 1, M.NBANDS do
    out[g] = (n[g] > 0) and (10 * math.log(out[g], 10)) or nil
  end
  return out, n
end

M.CROSS_OCT = 1/6   -- half-width of each crossfade, in octaves

-- Which gate band a frequency belongs to, and how far it has crossed into the
-- next one: a raised cosine over +-CROSS_OCT either side of every edge.
--
-- A hard edge is the thing to avoid. A band gain that steps between adjacent
-- bins makes the implied impulse response long enough to wrap the 2048-point
-- frame, and circular convolution of that is heard as pre-echo. Returns a
-- 1-based band and a weight in [0,1] toward band+1, which sum to one, so the
-- kernel splits a bin's energy rather than counting it twice.
function M.bin_band(hz)
  if hz <= 0 then return 1, 0.0 end
  local c = M.CROSS_OCT
  for i = 1, #M.EDGES do
    local lo = M.EDGES[i] * 2 ^ (-c)
    local hi = M.EDGES[i] * 2 ^ (c)
    if hz < lo then return i, 0.0 end
    if hz <= hi then
      local t = math.log(hz / lo, 2) / (2 * c)
      return i, 0.5 - 0.5 * math.cos(math.pi * t)
    end
  end
  return M.NBANDS, 0.0
end

-- The law. A gate is the ratio -> infinity limit of a downward expander, so
-- there is one expression and `mode` only chooses the ratio.
function M.gain_db(level_db, thr_db, ratio, range_db)
  if level_db >= thr_db then return 0.0 end
  if ratio == math.huge then return -range_db end
  return math.max(-range_db, (level_db - thr_db) * (ratio - 1))
end

function M.ratio_of(cfg)
  if cfg.gate_mode == "gate" then return math.huge end
  return cfg.gate_ratio or 1.0
end

-- One band's envelope state, advanced by one step of `dt` seconds.
--
-- Closing waits out `hold` and then runs a one-pole toward the target, because
-- a hard switch on a band sitting near its threshold chatters.
--
-- `attack` is nil or 0 in the SPECTRAL domain, where opening is instant: the
-- STFT window is 43 ms wide, so the gain a frame carries is already smeared
-- either side of the moment it was decided, the stage cannot clip a syllable
-- onset, and it opens slightly early -- the safe direction. The FILTERBANK has
-- no such smoothing, and a gain step at sample rate is a click, so it opens
-- through a one-pole of its own, floored at about a cycle of the band (see
-- `detect_times`).
--
-- `st` is { g = <dB, <= 0>, held = <seconds below threshold> }.
function M.step(st, level_db, thr_db, ratio, range_db, release, dt, attack)
  local open_thr = thr_db
  if ratio == math.huge then
    -- hysteresis, gate mode only: an expander is continuous and needs none
    open_thr = (st.g < 0) and (thr_db + M.HYST_DB) or thr_db
  end
  local target = M.gain_db(level_db, open_thr, ratio, range_db)
  if target >= st.g then
    st.held = 0
    if not attack or attack <= 0 then
      st.g = target
    else
      st.g = st.g + (target - st.g) * (1 - math.exp(-dt / attack))
    end
    return st.g
  end
  st.held = st.held + dt
  if st.held < M.HOLD_S then return st.g end
  local a = 1 - math.exp(-dt / math.max(release, 1e-4))
  st.g = st.g + (target - st.g) * a
  return st.g
end

function M.new_state()
  local st = {}
  for g = 1, M.NBANDS do st[g] = { g = 0.0, held = 0.0 } end
  return st
end

function M.release_of(t60)
  if not t60 or t60 <= 0 then return M.REL_MAX end
  return clamp(t60 / M.REL_DIV, M.REL_MIN, M.REL_MAX)
end

-- ------------------------------------------------------- the filterbank
-- Linkwitz-Riley 4th order: two identical Butterworth sections in cascade, so
-- each branch is 24 dB/octave and both are -6 dB at the crossover, which is
-- what makes LP + HP sum to unity magnitude.
--
-- The design lives here rather than in the kernel for the same reason the band
-- map does: the EEL only ever receives coefficients, so the geometry can be
-- checked without REAPER. `dr/solve.lua` owns the peaking sections the
-- correction cascade uses; these are a different job and a different shape, so
-- they are not shared.
local function butter(kind, fc, rate)
  local w0 = 2 * math.pi * math.min(fc, 0.45 * rate) / rate
  local cw, sw = math.cos(w0), math.sin(w0)
  local alpha = sw / (2 * math.sqrt(0.5))       -- Q = 1/sqrt(2)
  local a0 = 1 + alpha
  local b0, b1, b2
  if kind == "lp" then
    b0 = (1 - cw) / 2; b1 = 1 - cw;    b2 = (1 - cw) / 2
  elseif kind == "hp" then
    b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
  else
    b0 = 1 - alpha;    b1 = -2 * cw;   b2 = 1 + alpha
  end
  return { b0 = b0 / a0, b1 = b1 / a0, b2 = b2 / a0,
           a1 = (-2 * cw) / a0, a2 = (1 - alpha) / a0 }
end

-- One crossover: the lowpass and highpass halves (applied TWICE each) and the
-- 2nd-order allpass their sum is equal to.
--
-- That last one is what makes an eight-band tree reconstruct. Splitting the
-- highpass branch again and again leaves every band already extracted with the
-- wrong phase for the splits that came after it, and the bands then sum with
-- ripple at every crossover instead of flat. Passing each extracted band
-- through the allpass of every LATER split fixes it exactly: the whole bank
-- sums to AP1*AP2*...*AP7, which is unity magnitude at every frequency.
function M.crossover(fc, rate)
  return { fc = fc,
           lp = butter("lp", fc, rate),
           hp = butter("hp", fc, rate),
           ap = butter("ap", fc, rate) }
end

function M.crossovers(rate)
  local out = {}
  for i = 1, #M.EDGES do out[i] = M.crossover(M.EDGES[i], rate) end
  return out
end

-- Complex response of one normalised biquad, as re, im. `dr/solve.lua` has the
-- magnitude-squared form; the allpass assertion needs the phase too, because
-- LP^2 + HP^2 = AP is a statement about complex sums and is true of the
-- magnitudes only by accident.
function M.biquad_at(c, f, rate)
  local w = 2 * math.pi * f / rate
  local c1, s1 = math.cos(w), math.sin(w)
  local c2, s2 = math.cos(2 * w), math.sin(2 * w)
  local nr = c.b0 + c.b1 * c1 + c.b2 * c2
  local ni = -(c.b1 * s1 + c.b2 * s2)
  local dr = 1 + c.a1 * c1 + c.a2 * c2
  local di = -(c.a1 * s1 + c.a2 * s2)
  local den = dr * dr + di * di
  if den <= 0 then return 1.0, 0.0 end
  return (nr * dr + ni * di) / den, (ni * dr - nr * di) / den
end

-- Detector and attack time constants for one band.
--
-- Both are floored at a few cycles of the band, and that floor is not taste: a
-- one-pole shorter than the period it is watching tracks the waveform itself
-- rather than its envelope, so the gain moves at the signal frequency and the
-- band buzzes. Band 1 has no lower edge, so it is referred to its upper one.
function M.detect_times(g)
  local lo, hi = M.band_range(g)
  local fref = (g == 1) and hi or lo
  return clamp(3.0 / fref, 0.003, 0.050),    -- detector
         clamp(1.0 / fref, 0.001, 0.020)     -- attack
end

-- What the analysis suggests, per gate band.
--
-- `pause`, `voice` and `floor` are per-1/12-octave-band dB, `hz` their centres,
-- `t60` their measured decay. Returns one entry per gate band; `measured` is
-- false where no analysis band falls inside it or the two populations do not
-- separate, and `thr` is nil there.
--
-- WHY THE THRESHOLD IS SET FROM THE VOICE AND NOT FROM THE PAUSE. The obvious
-- rule -- put it just above where the pauses are -- was tried and measured, and
-- it produces a gate that does nothing. The pause cube is filled on the decay
-- cube's `quiet` flag, which fires only once the take's running level has
-- fallen `edc_gate_db` below its own average, and on the reverberant fixture
-- that is 200 ms into every gap: the LOUDEST frame the cube can hold was
-- -33.6 dB while the tail entering the gap was -22 dB. A threshold placed at
-- the top of that distribution still sits 11 dB under the tail it is meant to
-- catch, and the stage measured a 0.0 dB change.
--
-- So the reference is the band's own working level, which is what a gate is
-- set from by hand as well. 12 dB under it is the same figure `edc_gate_db`
-- uses to mean "the voice has stopped", and like `reduction_from_t60` it is a
-- taste boundary rather than a measurement -- the measured parts are WHERE
-- that level is per band, whether there are pauses to gate at all, and how far
-- down the band may be taken.
--
-- REFUSING IS THE POINT. The ring pass runs at `pitch_rate` over
-- `search_lo_hz..search_hi_hz`, so nothing above about 1.9 kHz is measured at
-- all and nothing above 4 kHz can be. Carrying the top band's threshold upward
-- would put a number on the two bands where the singer's sibilance and breath
-- live, and gating those is the most audible way to ruin a vocal. They are
-- handed back for the ear instead, and the panel says which they are.
function M.suggest(pause, voice, floor, hz, t60, nband, pinned, pause_n)
  if pinned then
    return nil, "the level statistic is pinned; the pause levels cannot be trusted"
  end
  local P = M.fold(pause, hz, nband)
  local V = M.fold(voice, hz, nband)
  local F = M.fold(floor, hz, nband)
  local out, nmeas = {}, 0
  for g = 1, M.NBANDS do
    local e = { pause = P[g], voice = V[g], floor = F[g], measured = false }
    -- T60 for the band is the median of the analysis bands inside it: each
    -- rests on a handful of pauses, and a mean would carry the one fit that
    -- landed on a breath where a median absorbs it.
    local ts = {}
    for b = 1, (nband or #hz) do
      if t60[b] and hz[b] and M.band_of(hz[b]) == g then ts[#ts + 1] = t60[b] end
    end
    table.sort(ts)
    e.t60 = (#ts > 0) and ts[math.max(1, math.floor(0.5 * (#ts + 1)))] or nil
    e.release = M.release_of(e.t60)

    -- how many pause frames the bands inside this one collected
    local pn = 0
    if pause_n then
      for b = 1, (nband or #hz) do
        if hz[b] and M.band_of(hz[b]) == g then pn = math.max(pn, pause_n[b] or 0) end
      end
    end
    e.pause_n = pn

    if not (P[g] and V[g] and F[g]) then
      e.why = "not measured: the analysis does not reach this band"
    elseif pause_n and pn < M.MIN_PAUSE_N then
      e.why = string.format(
        "not measured: only %d pause frames here, which is not a distribution", pn)
    elseif V[g] - P[g] < M.MIN_SEP_DB then
      e.why = string.format(
        "not gateable: the pauses sit only %.1f dB under the voice here", V[g] - P[g])
    else
      local thr = V[g] - M.GATE_BELOW_DB
      -- a threshold at the noise floor never triggers; one that has been
      -- raised to clear the floor must still stay clear of the voice
      thr = math.max(thr, F[g] + M.FLOOR_HEAD_DB)
      thr = math.min(thr, V[g] - M.VOICE_MARGIN)
      e.thr = thr
      -- A band can only be pulled down to its own measured noise floor: a
      -- signal sitting AT the threshold must not be pushed under it. Gating a
      -- pause to -60 dB when the room floor is at -55 sounds like the
      -- recording stopping and starting again; stopping at the floor sounds
      -- like the room.
      e.range_cap = math.max(0.0, thr - F[g])
      e.measured = true
      nmeas = nmeas + 1
    end
    out[g] = e
  end
  if nmeas == 0 then
    return nil, "no band separated its pauses from the voice"
  end
  return out, nil, nmeas
end

-- The threshold and range the render actually runs with, per band: the
-- suggestion or the hand-set key, plus the global offset, and the range scaled
-- by `amount` and clamped by what the measurement says is there.
function M.effective_band(cfg, sug, g)
  local thr
  if cfg.gate_auto and sug and sug[g] and sug[g].thr then
    thr = sug[g].thr
  else
    thr = cfg["gate_thr" .. g]
  end
  thr = (thr or -140) + (cfg.gate_offset_db or 0)
  local range = (cfg.gate_amount / 100.0) * M.RANGE_MAX
  if cfg.gate_auto and sug and sug[g] and sug[g].range_cap then
    range = math.min(range, sug[g].range_cap)
  end
  local rel = (sug and sug[g] and sug[g].release) or M.REL_MAX
  rel = rel * (cfg.gate_release / 100.0)
  return thr, range, clamp(rel, 0.005, 4.0)
end

return M
