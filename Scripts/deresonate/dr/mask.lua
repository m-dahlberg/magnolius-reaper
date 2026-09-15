-- @noindex
-- Harmonic occupancy: for every frequency, how often the singer was putting
-- energy there.
--
-- The single fact this stage exists for: a sung note puts energy at F0 AND at
-- 2F0, 3F0, 4F0..., so masking against the detected fundamental alone leaves
-- every harmonic looking like a resonance. Validated on a real take -- peaks at
-- 1296, 1311, 1011 and 1008 Hz came back with occupancy 0.53-0.58 and were
-- correctly rejected, while the genuinely non-vocal candidates sat at 0.00.
--
-- Known limit, and it is structural rather than a tuning problem: on a low male
-- voice a resonance that is only ever excited by a harmonic sweeping through it
-- is removed from the conditional statistic by the very mask that protects the
-- singer. Occupancy can say "not proven", never "not there". That is what the
-- ring test in `ring.lua` is for.
--
-- Pure Lua: imports no `reaper`.

local M = {}

-- The voicing test, in one place so every stage agrees.
function M.voiced(F, i, cfg)
  return (F.aper[i] or 1) < cfg.yin_threshold
     and (F.level_db[i] or -140) > cfg.voice_gate_db
     and (F.f0[i] or 0) > 0
end

-- Mark every point covered by the harmonic series of one f0.
-- `out` is reused across frames by the caller; it must be cleared first.
function M.stamp(out, f0, hz, cents, nyquist)
  if not f0 or f0 <= 0 then return out end
  local lo_r, hi_r = 2 ^ (-cents / 1200.0), 2 ^ (cents / 1200.0)
  local n, np = 1, #hz
  local first = 1
  while n * f0 < nyquist do
    local fh = n * f0
    local lo, hi = fh * lo_r, fh * hi_r
    -- the axis is monotonic, so walk forward rather than rescanning
    while first <= np and hz[first] < lo do first = first + 1 end
    local j = first
    while j <= np and hz[j] <= hi do out[j] = true; j = j + 1 end
    if first > np then break end
    n = n + 1
  end
  return out
end

-- Fraction of voiced frames whose harmonic series covers each point.
function M.occupancy(F, hz, cfg)
  local np = #hz
  local occ, hits = {}, {}
  for i = 1, np do hits[i] = 0 end
  local nyquist = hz[np] + (hz[2] - hz[1])
  local nvoiced = 0
  local scratch = {}
  for i = 1, F.n do
    if M.voiced(F, i, cfg) then
      nvoiced = nvoiced + 1
      for j = 1, np do scratch[j] = nil end
      M.stamp(scratch, F.f0[i], hz, cfg.mask_cents, nyquist)
      for j = 1, np do
        if scratch[j] then hits[j] = hits[j] + 1 end
      end
    end
  end
  for i = 1, np do occ[i] = (nvoiced > 0) and (hits[i] / nvoiced) or 0.0 end
  return occ, nvoiced
end

-- Per-STFT-frame class array the kernel needs: for frame `f` covering take
-- seconds [t0,t1), the union of the harmonic masks of every voiced pitch frame
-- inside it. Returned as the f0 list rather than a bitmap, because the kernel
-- re-derives the mask per bin far more cheaply than Lua can ship one.
function M.frame_f0(F, cfg, nframes, hop_s, win_s)
  local out = {}
  for f = 1, nframes do
    local ta = (f - 1) * hop_s
    local tb = ta + win_s
    local ia = math.max(1, math.floor(ta / (cfg.hop_ms / 1000.0)) + 1)
    local ib = math.min(F.n, math.floor(tb / (cfg.hop_ms / 1000.0)) + 1)
    -- the median voiced f0 in the window; 0 if the window carries no voicing
    local v = {}
    for i = ia, ib do
      if M.voiced(F, i, cfg) then v[#v + 1] = F.f0[i] end
    end
    if #v == 0 then
      out[f] = 0.0
    else
      table.sort(v)
      out[f] = v[math.floor((#v + 1) / 2)]
    end
  end
  return out
end

return M
