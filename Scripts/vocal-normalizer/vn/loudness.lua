-- @noindex
-- Vocal Normalizer -- stage 2: frames to one number, and that number to a gain.
--
-- Pure Lua. Nothing here knows what an accessor or a filter is; it is handed
-- per-frame sums of squares and gives back a gated loudness, a loudness range
-- and the move the item needs. That split is what lets every control below the
-- band and the block length redraw the panel without re-reading a sample --
-- and it is what makes the gate, the reduction and the gain law directly
-- unit-testable.
--
-- The measurement is BS.1770's, with exactly one thing changed: the signal it
-- integrates has been through the vocal band instead of the K-weighting curve.
-- Everything else -- the 400 ms blocks at 75% overlap, the -0.691 offset, the
-- absolute-then-relative gate -- is the standard's, because the standard's
-- gating is good and the part that misjudges a bright vocal is the weighting,
-- not the integration.
--
-- Why the numbers are not LUFS, and why they are not calibrated to look like
-- LUFS: the band throws energy away, so a band measurement always reads lower.
-- The amount it reads lower is a property OF THE VOICE -- more for a bright,
-- sibilant take, less for a dark one -- which is the entire bias this script
-- exists to remove. A constant offset that made the numbers "look like LUFS"
-- would therefore be a lie about a quantity that is not constant. The scale is
-- its own, the panel shows the take's real LUFS alongside it, and the target
-- is set from a take you already like.

local M = {}

-- The overlap is fixed, unlike the block length. BS.1770 blocks overlap by
-- 75%, and the gate's behaviour is tuned to that: each block is exactly four
-- consecutive non-overlapping quarter-blocks, so the analysis stage measures
-- quarter-blocks and this file slides a four-wide window over them. That is
-- exact rather than approximate, and it is why the kernel never has to know
-- what a gating block is.
M.OVERSAMPLE = 4

-- BS.1770's calibration constant: with it, a full-scale 997 Hz sine in one
-- channel reads -3.01 LKFS. Kept even for the band measurement so that
-- opening the band wide and switching K-weighting on gives real LUFS.
M.OFFSET = -0.691

-- Short-term window for loudness range, per EBU Tech 3342.
M.LRA_WINDOW_S = 3.0
M.LRA_GATE_LU  = -20
M.LRA_LO_PCT   = 10
M.LRA_HI_PCT   = 95

local FLOOR_DB = -200

local function db10(z)
  if z <= 0 then return FLOOR_DB end
  local v = M.OFFSET + 10 * math.log(z, 10)
  return v < FLOOR_DB and FLOOR_DB or v
end
M.db10 = db10

function M.hop_s(cfg) return cfg.block_ms / 1000 / M.OVERSAMPLE end

-- Blocks ---------------------------------------------------------------------
--
-- `F` is the frame table analyze.lua produces: F.n frames on a grid of F.hop_s
-- seconds, F.cnt[i] samples actually read into frame i, and one sum-of-squares
-- series per chain (F.zb the band, F.zk the K-weighted reference). Sums rather
-- than means, because a block is four frames and summing four sums and
-- dividing once is both cheaper and exact where averaging four means is not
-- when the last frame of an item is short.
--
-- `t0` is take seconds; adding the item position gives project time, with no
-- playrate factor -- the accessor already applied it.
--
-- An item shorter than one gating block gets ONE block covering everything it
-- has. Refusing to measure a 300 ms ad-lib would be worse than measuring it
-- over a shorter window and saying so, and `short` says so.
--
-- `vol_lin` is the linear volume already on the clip -- take volume times item
-- volume. The accessor applies neither, so without it every number here would
-- describe the raw file rather than what comes out of the item, and
-- normalising an already-normalised clip would ask for the same move twice.
-- It is folded in as a factor on z (squared, because z is a mean SQUARE) so
-- that the gate, the plot and the reported level are all on one scale and
-- there is no second, raw scale for anything downstream to confuse it with.
function M.blocks(F, which, cfg, vol_lin)
  local z = F[which]
  local g2 = (vol_lin or 1) ^ 2
  local nsub = M.OVERSAMPLE
  local out = {}
  local total = F.n

  if total < 1 then return out end
  if total < nsub then
    local sz, sn = 0, 0
    for i = 1, total do sz = sz + z[i] * g2; sn = sn + F.cnt[i] end
    if sn > 0 then
      out[1] = { i = 1, t0 = 0, t1 = total * F.hop_s, z = sz / sn,
                 db = db10(sz / sn), short = true }
    end
    return out
  end

  for i = 1, total - nsub + 1 do
    local sz, sn = 0, 0
    for j = i, i + nsub - 1 do sz = sz + z[j] * g2; sn = sn + F.cnt[j] end
    if sn > 0 then
      local m = sz / sn
      out[#out + 1] = { i = i, t0 = (i - 1) * F.hop_s,
                        t1 = (i - 1 + nsub) * F.hop_s,
                        z = m, db = db10(m) }
    end
  end
  return out
end

-- Percentile of a list of numbers, by linear interpolation between the two
-- neighbouring order statistics. Sorts a copy: the caller's block list stays
-- in time order, which the plot depends on.
function M.percentile(values, p)
  local n = #values
  if n == 0 then return nil end
  local v = {}
  for i = 1, n do v[i] = values[i] end
  table.sort(v)
  if n == 1 then return v[1] end
  local x = 1 + (p / 100) * (n - 1)
  if x <= 1 then return v[1] end
  if x >= n then return v[n] end
  local lo = math.floor(x)
  return v[lo] + (v[lo + 1] - v[lo]) * (x - lo)
end

-- Integration ----------------------------------------------------------------
--
-- `blocks` is one item's blocks, or every selected item's blocks concatenated
-- when they are being measured as one programme. Pooling BLOCKS rather than
-- frames is what makes linked measurement correct across an item boundary: a
-- window that straddled the gap between two clips would average a phrase with
-- whatever silence follows it, and there is no such window here.
--
-- Marks each block with `.abs` and `.gated` in place, so the plot can draw
-- what the gate actually kept without recomputing it.
--
-- Returns a table, or nil plus a message when there is nothing above the
-- absolute gate -- which for a band measurement means the band is empty, not
-- that the file is. Saying which is the panel's job; saying that it happened
-- is this one's.
function M.integrate(blocks, cfg)
  if #blocks == 0 then return nil, "no gating block fits in this item" end

  local abs = {}
  for _, b in ipairs(blocks) do
    b.abs = b.db > cfg.gate_abs_lu
    b.gated = false
    if b.abs then abs[#abs + 1] = b end
  end
  if #abs == 0 then
    return nil, string.format("everything is below the %g dB absolute gate",
                              cfg.gate_abs_lu)
  end

  local sum = 0
  for _, b in ipairs(abs) do sum = sum + b.z end
  local rel = db10(sum / #abs) + cfg.gate_rel_lu

  local kept = {}
  for _, b in ipairs(abs) do
    if b.db > rel then kept[#kept + 1] = b end
  end
  -- The relative gate can only remove blocks, never all of them in practice --
  -- the mean of a set always has something above it minus 10 dB. Falling back
  -- rather than erroring covers the degenerate single-block case.
  if #kept == 0 then kept = abs end
  for _, b in ipairs(kept) do b.gated = true end

  local value
  if cfg.reduce == "percentile" then
    -- Deliberately over the ABSOLUTELY gated set, not the relatively gated
    -- one: a percentile is already an outlier-robust way of ignoring the quiet
    -- end, so applying the relative gate first would discard the same blocks
    -- twice and pull the answer up by several dB.
    local vals = {}
    for i, b in ipairs(abs) do vals[i] = b.db end
    value = M.percentile(vals, cfg.percentile)
  else
    local s = 0
    for _, b in ipairs(kept) do s = s + b.z end
    value = db10(s / #kept)
  end

  local mx = FLOOR_DB
  for _, b in ipairs(blocks) do if b.db > mx then mx = b.db end end

  return {
    db = value,
    abs_gate_db = cfg.gate_abs_lu,
    rel_gate_db = rel,
    nblocks = #blocks, nabs = #abs, ngated = #kept,
    max_db = mx,
    short = blocks[1] and blocks[1].short or false,
  }
end

-- Loudness range, EBU Tech 3342: 3 s windows on the same frame grid, an
-- absolute gate, a relative gate 20 LU down, and the spread between the 10th
-- and 95th percentile of what survives.
--
-- It is a readout, not an input to anything -- but it is the readout that says
-- whether normalising this take to a single number is even a sensible thing to
-- do. A vocal at 4 LU takes a gain well; one at 15 LU is asking for a rider.
-- Returns nil when the item is shorter than one window. No volume factor:
-- LRA is a difference between two percentiles of the same series, so a
-- constant gain cancels out of it exactly -- except in the absolute gate,
-- where it could only matter for a clip already 70 dB down.
function M.lra(F, which, cfg)
  local z = F[which]
  local nsub = math.floor(M.LRA_WINDOW_S / F.hop_s + 0.5)
  if nsub < 1 or F.n < nsub then return nil end

  local st = {}
  for i = 1, F.n - nsub + 1 do
    local sz, sn = 0, 0
    for j = i, i + nsub - 1 do sz = sz + z[j]; sn = sn + F.cnt[j] end
    if sn > 0 then st[#st + 1] = { z = sz / sn, db = db10(sz / sn) } end
  end

  local abs = {}
  for _, s in ipairs(st) do
    if s.db > cfg.gate_abs_lu then abs[#abs + 1] = s end
  end
  if #abs < 2 then return nil end

  local sum = 0
  for _, s in ipairs(abs) do sum = sum + s.z end
  local rel = db10(sum / #abs) + M.LRA_GATE_LU

  local vals = {}
  for _, s in ipairs(abs) do
    if s.db > rel then vals[#vals + 1] = s.db end
  end
  if #vals < 2 then return nil end

  return M.percentile(vals, M.LRA_HI_PCT) - M.percentile(vals, M.LRA_LO_PCT)
end

-- The gain law ----------------------------------------------------------------
--
-- Target minus measured, then clamped -- and the order matters. The boost and
-- cut limits express taste ("never move a take more than this"), so they are
-- applied first. The peak ceiling expresses a fact about the file, so it is
-- applied last and is allowed to override them: a take that would clip the
-- chain must come down whatever the cut limit says. It can only ever reduce
-- the gain, never raise it, so it cannot fight the boost limit.
--
-- `peak_db` is the SAMPLE peak. There is no true-peak measurement here and the
-- default ceiling of -1.0 dB is chosen to leave room for the difference rather
-- than to pretend it does not exist.
--
-- Returns gain_db, limit -- where limit is nil, "boost", "cut" or "peak",
-- naming which constraint decided the answer. The panel colours the row by it,
-- which is the difference between "this take is now at target" and "this take
-- is as close as it was allowed to get".
function M.gain(measured_db, peak_db, cfg)
  local g = cfg.target_db - measured_db
  local limit = nil
  if g > cfg.max_boost_db then g, limit = cfg.max_boost_db, "boost" end
  if g < -cfg.max_cut_db then g, limit = -cfg.max_cut_db, "cut" end
  if cfg.limit_peak and peak_db and peak_db > FLOOR_DB then
    local room = cfg.peak_ceiling_db - peak_db
    if g > room then g, limit = room, "peak" end
  end
  return g, limit
end

function M.db_from_amp(a)
  if not a or a <= 0 then return FLOOR_DB end
  return 20 * math.log(a, 10)
end

M.FLOOR_DB = FLOOR_DB
return M
