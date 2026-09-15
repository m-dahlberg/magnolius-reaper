-- @noindex
-- AutoTilt -- parameter defaults, persistence, and the shared geometry.
--
-- Pure Lua beyond the load/save helpers, so spectrum and solve can be
-- exercised headlessly.
--
-- The split that matters is ANALYSIS vs everything else. Analysis parameters
-- decide the level-bucketed spectrum cube, which is what the accessor pass
-- produces and what everything downstream reads; changing one costs a re-read
-- of both clips. The pivot, the band limits, the gate and the shelf slope are
-- all pure functions of that cube, so moving any of them is a few thousand
-- multiplies and the panel stays live -- which is what makes the pivot a
-- tuning control you drag rather than a setting you commit to.

local M = {}

M.EXT_SECTION = "auto_tilt"
M.VERSION = 1

-- The level histogram the cube is bucketed by. Shared with the kernel, which
-- allocates NLEV rows: named here so the pure stages can turn a bucket index
-- back into dB without asking the kernel, and the two cannot drift apart.
M.NLEV = 127                    -- 1 dB level buckets
M.LEV0 = -120                   -- dB of bucket 0; digital silence lands here

-- Changing any of these changes the cube, so the audio must be re-read.
-- target_track is here because it changes *which clips* get read, which is the
-- same cost even though it is not an FFT parameter.
M.ANALYSIS_KEYS = { "fft_size", "ana_hop", "target_track" }

-- Pure functions of the cube: gate, band limit, split, weight.
M.MEASURE_KEYS = { "pivot_hz", "band_lo_hz", "band_hi_hz", "gate_db", "gate_pct" }

-- Pure functions of the measured spectra: the shelf response and the search.
M.SOLVE_KEYS = {
  "shelf_slope", "max_gain", "use_fixed_ref", "fixed_ref_ratio",
}

-- Change nothing that is computed; only what gets written.
M.OUTPUT_KEYS = { "new_take", "select_take", "compensate_level" }

M.defaults = {
  -- Analysis ----------------------------------------------------------------
  -- 4096 at 48 kHz is an 85 ms window and 11.7 Hz bins. The bins are the
  -- reason for the size rather than the window: at the 80 Hz band edge a
  -- coarser transform puts the edge between bins 1 and 2, and the low sum then
  -- depends on rounding rather than on the audio.
  fft_size      = 4096,
  -- 1024 is 21 ms at 48 kHz, four-fold overlap. The hop is what sets how
  -- finely the gate can separate a word from the breath before it, so it is
  -- deliberately shorter than the window.
  ana_hop       = 1024,

  -- Selection ---------------------------------------------------------------
  -- 0 means "the highest-numbered selected track". A 1-based track number
  -- overrides it, for the case where the layout says otherwise.
  target_track  = 0,

  -- Measurement -------------------------------------------------------------
  pivot_hz      = 1000,   -- the tilt pivot, and the split point of the ratio

  -- The band the ratio is measured over -- NOT a limit on what the tilt does.
  -- Below 80 Hz a close mic carries proximity rumble, plosives, stand thumps
  -- and HVAC; above 16 kHz it carries preamp hiss. Both hold real energy and
  -- no tone, and both would otherwise move the ratio for inaudible reasons.
  band_lo_hz    = 80,
  band_hi_hz    = 16000,

  -- The gate rides the clip's own level: the gate_pct percentile frame level,
  -- less gate_db. A vocal track is mostly not vocal, and room tone has a
  -- completely different slope from a voice, so how tightly a clip happens to
  -- be trimmed would otherwise leak straight into its measured balance.
  -- 95 rather than 100 so one clipped sample or one stray thump cannot define
  -- "loud" for the whole clip.
  gate_pct      = 95,
  gate_db       = 30,

  -- Tilt --------------------------------------------------------------------
  -- RBJ shelf S. 1 is the steepest slope that does not overshoot; a tilt wants
  -- to be broad, so the default is gentler than that.
  shelf_slope   = 0.7,
  -- The search bounds, and the clamp. Two close-miked takes of the same part
  -- needing more than this apart are not a tilt problem.
  max_gain      = 12,

  -- Reference ---------------------------------------------------------------
  -- With only one clip selected there is nothing to measure against, so the
  -- fixed ratio stands in. Captured from a measured reference by the panel's
  -- capture button, which is how a house target accumulates across sessions.
  use_fixed_ref   = true,
  fixed_ref_ratio = 0.0,

  -- Output ------------------------------------------------------------------
  -- A tilt about the pivot changes overall level, because a vocal's energy is
  -- not centred there. On by default: the point of the script is to match
  -- tone, and a level change arriving with it would be read as the tilt being
  -- wrong.
  compensate_level = true,
  new_take      = true,
  select_take   = true,
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- In place, because the panel holds one cfg table as an upvalue and hands it to
-- the kernel and the render -- swapping the table would leave those pointing at
-- the old one. Keys the panel added for itself go too, so a reset really is the
-- state a fresh install starts in.
function M.reset(cfg)
  local extra = {}
  for k in pairs(cfg) do
    if M.defaults[k] == nil then extra[#extra + 1] = k end
  end
  for _, k in ipairs(extra) do
    cfg[k] = nil
    if reaper then reaper.DeleteExtState(M.EXT_SECTION, k, true) end
  end
  for k, v in pairs(M.defaults) do cfg[k] = v end
  M.save(cfg)
  return cfg
end

local function signature(cfg, keys)
  local t = {}
  for i, k in ipairs(keys) do t[i] = tostring(cfg[k]) end
  return table.concat(t, "|")
end

function M.analysis_sig(cfg) return signature(cfg, M.ANALYSIS_KEYS) end
function M.measure_sig(cfg)  return signature(cfg, M.MEASURE_KEYS)  end
function M.solve_sig(cfg)    return signature(cfg, M.SOLVE_KEYS)    end
function M.output_sig(cfg)   return signature(cfg, M.OUTPUT_KEYS)   end

-- A change to channel count or FFT size changes the kernel's memory map, which
-- means a new kernel rather than a reconfigure. The hop rides as a parameter.
function M.kernel_sig(cfg, nchan)
  return table.concat({ nchan, M.fft_size(cfg) }, "|")
end

-- Derived geometry -----------------------------------------------------------
-- Kept here so the kernel, the pure stages and the panel cannot disagree.

-- The FFT size, forced to a power of two in [256, 16384]. The kernel's radix-2
-- transform has no other option, and a silently-wrong size would show up as a
-- wrong spectrum rather than as an error.
function M.fft_size(cfg)
  local n = math.floor(tonumber(cfg.fft_size) or 4096)
  local p = 256
  while p < n and p < 16384 do p = p * 2 end
  return p
end

function M.hop(cfg)
  local n = M.fft_size(cfg)
  local h = math.floor(tonumber(cfg.ana_hop) or (n / 4))
  if h < 1 then h = 1 end
  if h > n then h = n end
  return h
end

function M.nbins(cfg) return M.fft_size(cfg) // 2 + 1 end

-- Bin index -> the frequency at its centre.
function M.bin_hz(bin, rate, fft_size)
  return bin * rate / fft_size
end

-- The inclusive bin range the measurement covers, and the bin the split falls
-- in. Bin 0 is DC and is never included: it carries the frame's mean, which is
-- an offset rather than a tone, and its "frequency" of 0 Hz has no place on a
-- log axis.
--
-- Clamped into the transform, and ordered, so a band typed backwards or a
-- pivot dragged outside the band still yields a usable -- if degenerate --
-- answer rather than two empty sums and a NaN ratio.
function M.band_bins(cfg, rate, fft_size)
  local nb = fft_size // 2 + 1
  local function idx(hz)
    local b = math.floor(hz * fft_size / rate + 0.5)
    if b < 1 then b = 1 end
    if b > nb - 1 then b = nb - 1 end
    return b
  end
  local lo_hz = math.min(cfg.band_lo_hz, cfg.band_hi_hz)
  local hi_hz = math.max(cfg.band_lo_hz, cfg.band_hi_hz)
  local lo, hi = idx(lo_hz), idx(hi_hz)
  if hi < lo then hi = lo end
  local piv = idx(cfg.pivot_hz)
  if piv < lo then piv = lo end
  if piv > hi then piv = hi end
  return lo, hi, piv
end

-- Persistence ----------------------------------------------------------------
-- Values round-trip through ExtState as strings; the type is recovered from the
-- default, so an absent or corrupt key falls back rather than erroring.

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
  end
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  for k, default in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      local s = reaper.GetExtState(M.EXT_SECTION, k)
      if type(default) == "number" then
        cfg[k] = tonumber(s) or default
      elseif type(default) == "boolean" then
        cfg[k] = (s == "true")
      else
        cfg[k] = s
      end
    end
  end
  return cfg
end

return M
