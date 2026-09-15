-- @noindex
-- Spectral DeNoise -- the per-bin gain chain, in Lua.
--
-- A transcription of the same maths the kernel runs (Berouti oversubtraction,
-- Wiener gain, whitened reduction floor), minus the parts that only exist
-- across time: the rising-only temporal smoother and NLM. It serves two
-- purposes -- it draws the gain curve in the panel, so Reduction, Strength and
-- Whitening respond instantly to a drag, and it is the reference the headless
-- tests check the algorithm against without needing REAPER to run the EEL.
--
-- Arrays are 1-based and n = half + 1 bins long; the kernel's bin 0 is [1].

local M = {}

M.ALPHA_MIN = 1
M.ALPHA_MAX = 4
M.SUP_LO_DB = -5
M.SUP_HI_DB = 20
M.EPSP      = 1e-20
M.SPEC_EPS  = 1e-12
M.NF_SMOOTH = 0.5

-- smooth_spectrum (spectral_utils.c): a 3-point moving average blended in at
-- NF_SMOOTH. In place.
function M.smooth_spectrum(buf, n)
  local S = M.NF_SMOOTH
  local prev = buf[1]
  buf[1] = (buf[1] + buf[2]) * 0.5 * S + buf[1] * (1 - S)
  for i = 2, n - 1 do
    local cur = buf[i]
    buf[i] = ((prev + cur + buf[i + 1]) / 3) * S + cur * (1 - S)
    prev = cur
  end
  buf[n] = (prev + buf[n]) * 0.5 * S + buf[n] * (1 - S)
  return buf
end

local function median(t, n)
  local c = {}
  for i = 1, n do c[i] = t[i] end
  table.sort(c)
  return c[math.floor(n / 2) + 1]
end

-- spectral_whitening_get_weights: valley-filling weights >= 1 anchored to the
-- median of the smoothed profile. Raising the reduction floor in the profile's
-- valleys is what makes the residual come out spectrally flat instead of
-- keeping the noise's colour.
function M.whitening_weights(prof, n, whitening_pct)
  local w = {}
  local wf = (whitening_pct or 0) / 100
  if wf <= 0 then
    for i = 1, n do w[i] = 1 end
    return w
  end
  local s = {}
  for i = 1, n do s[i] = prof[i] end
  M.smooth_spectrum(s, n)
  local anchor = math.max(median(s, n), M.SPEC_EPS)
  for i = 1, n do
    w[i] = s[i] > M.SPEC_EPS and (anchor / s[i]) ^ wf or 1
  end
  return w
end

-- Berouti per-bin oversubtraction: alpha runs from `amax` at low SNR down to 1
-- at high SNR, so quiet bins are cut hard and loud ones are left alone.
function M.alpha(snr_db, amax)
  if snr_db <= M.SUP_LO_DB then return amax end
  if snr_db >= M.SUP_HI_DB then return M.ALPHA_MIN end
  return amax - (snr_db - M.SUP_LO_DB) / (M.SUP_HI_DB - M.SUP_LO_DB)
         * (amax - M.ALPHA_MIN)
end

-- Wiener gain for one bin: subtract alpha-scaled noise power from the signal.
function M.wiener(sp, np, amax)
  local snr_db = 10 * math.log(sp / (np + M.SPEC_EPS), 10)
  local sn = np * M.alpha(snr_db, amax)
  if sn <= M.EPSP then return 1 end
  if sp > sn then return (sp - sn) / sp end
  return 0
end

-- noise_floor_manager_apply: clamp the gain to the whitened reduction floor.
-- At ~0 dB reduction gains are forced to 1 (the reference transparency guard).
function M.floor_gain(g, gainfloor, wht_depth, weight)
  if gainfloor >= 0.999 then return 1 end
  local fl = gainfloor * (1 + wht_depth * (weight - 1))
  if fl > 1 then fl = 1 end
  if g < fl then return fl end
  return g
end

-- The full static curve. `spec` and `prof` are power spectra of n bins.
-- Returns gains[], and the floor[] actually in force per bin.
function M.curve(spec, prof, n, cfg)
  local gainfloor = 10 ^ (-cfg.reduction / 20)
  local wht_depth = 1 - gainfloor
  local amax = M.ALPHA_MIN + (cfg.strength / 100) * (M.ALPHA_MAX - M.ALPHA_MIN)
  local w = M.whitening_weights(prof, n, cfg.whitening)

  local g, fl = {}, {}
  for i = 1, n do
    local raw = M.wiener(spec[i], prof[i], amax)
    g[i] = M.floor_gain(raw, gainfloor, wht_depth, w[i])
    fl[i] = gainfloor >= 0.999 and 1
            or math.min(1, gainfloor * (1 + wht_depth * (w[i] - 1)))
    if cfg.residual then g[i] = 1 - g[i] end
  end
  return g, fl, w
end

return M
