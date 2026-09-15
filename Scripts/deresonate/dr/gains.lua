-- @noindex
-- The per-bin dereverb gain chain, in Lua.
--
-- The suppression maths -- Berouti oversubtraction, Wiener gain, reduction
-- floor -- is transcribed from `DeNoise script/dn/gains.lua`, which is checked
-- headlessly there and here. What is different is WHERE the "noise" comes
-- from. DeNoise subtracts a static profile captured from a silent passage;
-- this subtracts an estimate of the LATE REVERBERATION, which is a decayed
-- copy of what the same bin held a few frames ago (Lebart):
--
--     lambda(n,k) = strength * |X(n-D,k)|^2 * 10^(-6 * D*hop/fs / T60)
--
-- so the only thing the model needs is T60, which the analysis measures.
--
-- This runs during notes as well as between them, which is the reason it was
-- chosen over an expander keyed to note ends: reverb is present under the
-- singing too, just masked, and a tool that only touches exposed tails makes
-- the timbre inconsistent.
--
-- Serves two purposes, as its DeNoise counterpart does: it draws the gain curve
-- in the panel, and it is the reference the headless tests check without
-- needing REAPER to run the EEL.
--
-- Pure Lua: imports no `reaper`.

local M = {}

M.ALPHA_MIN = 1
M.ALPHA_MAX = 4
M.SUP_LO_DB = -5
M.SUP_HI_DB = 20
M.EPSP      = 1e-20
M.SPEC_EPS  = 1e-12

-- Power decay across `tau` seconds for a given T60. At tau == T60 this is
-- exactly -60 dB, which is what T60 means.
function M.decay(tau, t60)
  if not t60 or t60 <= 0 then return 0.0 end
  return 10 ^ (-6.0 * tau / t60)
end

-- Berouti per-bin oversubtraction: alpha runs from `amax` at low SNR down to 1
-- at high SNR, so bins dominated by the tail are cut hard and bins carrying
-- direct sound are left alone.
function M.alpha(snr_db, amax)
  if snr_db <= M.SUP_LO_DB then return amax end
  if snr_db >= M.SUP_HI_DB then return M.ALPHA_MIN end
  return amax - (snr_db - M.SUP_LO_DB) / (M.SUP_HI_DB - M.SUP_LO_DB)
         * (amax - M.ALPHA_MIN)
end

function M.wiener(sp, np, amax)
  local snr_db = 10 * math.log(sp / (np + M.SPEC_EPS), 10)
  local sn = np * M.alpha(snr_db, amax)
  if sn <= M.EPSP then return 1 end
  if sp > sn then return (sp - sn) / sp end
  return 0
end

-- Clamp to the reduction floor. At ~0 dB reduction gains are forced to 1,
-- which is the transparency guard the null test depends on.
function M.floor_gain(g, gainfloor)
  if gainfloor >= 0.999 then return 1 end
  if g < gainfloor then return gainfloor end
  return g
end

function M.amax(cfg)
  return M.ALPHA_MIN + (cfg.strength / 100) * (M.ALPHA_MAX - M.ALPHA_MIN)
end

-- Late-reverb estimate for one bin from a delayed magnitude-squared value.
function M.late(prev_sq, tau, t60, strength_scale)
  return prev_sq * M.decay(tau, t60) * (strength_scale or 1.0)
end

-- The full curve. `spec` and `prev` are power spectra of n bins; `t60_of(i)`
-- may vary T60 with frequency, which is how the tail-vs-direct measurement
-- gets used -- the room is not equally live at every frequency.
function M.curve(spec, prev, n, tau, t60_of, cfg)
  local gainfloor = 10 ^ (-cfg.reduction / 20)
  local amax = M.amax(cfg)
  local scale = cfg.strength / 100.0
  local g, lam = {}, {}
  for i = 1, n do
    local t60 = (type(t60_of) == "function") and t60_of(i) or t60_of
    lam[i] = M.late(prev[i] or 0, tau, t60, scale)
    g[i] = M.floor_gain(M.wiener(spec[i], lam[i], amax), gainfloor)
  end
  return g, lam
end

return M
