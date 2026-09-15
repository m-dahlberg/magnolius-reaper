-- @noindex
-- Spectral DeNoise -- stage 4: process the take and write the result.
--
-- Reads the take a second time, runs the denoise chain over it and writes a
-- 32-bit float WAV beside the project media. Two details do the real work:
--
--   Latency. The STFT delays everything by one FFT (two with NLM), exactly as
--   the JSFX reports through pdc_delay. Offline there is no host to
--   compensate, so we push that many extra samples through and drop the same
--   number from the head of the output. The file then lines up with the source
--   sample for sample, which is what lets the result drop in as a take.
--
--   Rate. The file is written at the *source* sample rate and covers exactly
--   the accessor's span, which is the item's own length. The audio already has
--   the playrate applied, so the new take gets a zero start offset and neutral
--   stretch settings -- see apply.lua.
--
-- A coroutine, like analysis, so the UI stays alive and cancellable.

local Config  = require "dn.config"
local Analyze = require "dn.analyze"
local Wav     = require "dn.wav"

local M = {}

local function sanitize(s)
  return (s:gsub("[^%w%-%. ]", "_"):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A path in the project's media directory that does not exist yet.
function M.output_path(take, cfg)
  local src = reaper.GetMediaItemTake_Source(take)
  local fn = reaper.GetMediaSourceFileName(src, "")
  -- An unsaved project has no media directory; fall back to the source's own.
  local dir = reaper.GetProjectPath("")
  if dir == "" then dir = fn:match("^(.*)[/\\][^/\\]*$") or "." end
  local base = fn:match("([^/\\]+)$") or "audio"
  base = sanitize(base:gsub("%.[^.]+$", ""))
  local suffix = cfg.residual and "-residual" or "-denoised"
  local sep = package.config:sub(1, 1)
  for i = 0, 999 do
    local name = base .. suffix .. (i > 0 and ("-" .. i) or "") .. ".wav"
    local p = dir .. sep .. name
    local fh = io.open(p, "rb")
    if not fh then return p end
    fh:close()
  end
  return nil
end

-- Coroutine body. Yields progress, returns { path, peak, ... } or nil + msg.
function M.run(take, cfg, k, path)
  local geo = Analyze.geometry(take)
  local total = geo.total_samples
  if total < 1 then return nil, "Item has no audio" end
  if Wav.will_overflow(total, geo.nchan) then
    return nil, "Result would exceed the 4 GB WAV limit -- split the item first"
  end

  local latency = Config.latency(cfg)

  k:set_params(cfg)
  k:reset()                       -- streaming state only; keeps the profile

  local w, werr = Wav.create(path, geo.nchan, geo.rate)
  if not w then return nil, werr end

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then w:abort() return nil, "Could not create audio accessor" end

  -- Everything the per-block closure needs to carry between calls.
  local nch = geo.nchan
  local skipped, written = 0, 0
  local want = total * nch
  local peak = 0

  local function block(n)
    peak = k:process(n)
    local vals = n * nch
    local t = k.outbuf.table(1, vals)
    local from = 1
    if skipped < latency * nch then
      local drop = math.min(latency * nch - skipped, vals)
      skipped = skipped + drop
      from = from + drop
    end
    if from > vals then return end
    local to = math.min(vals, from + (want - written) - 1)
    if to >= from then
      w:write(t, from, to)
      written = written + (to - from + 1)
    end
  end

  -- Read `latency` samples past the end so the tail flushes out of the STFT.
  local ok, finished = pcall(Analyze.pump, aa, k, geo, 0, total + latency,
                             block, 0, 1)
  reaper.DestroyAudioAccessor(aa)

  if not ok then w:abort() return nil, tostring(finished) end
  if not finished then w:abort() return nil, "cancelled" end

  w:close()
  return {
    path = path, peak = peak, nchan = nch, rate = geo.rate,
    samples = written / nch, playrate = geo.playrate,
  }
end

return M
