-- @noindex
-- Adaptive De-Click -- stage 3: process the take and write the result.
--
-- Reads the take a second time, applies the gain envelopes detection already
-- built, and writes a 32-bit float WAV beside the project media.
--
-- What is NOT here is the thing its DeNoise counterpart spends most of its
-- length on: latency compensation. The gain envelope for every step was known
-- before rendering started, so there is no lookahead and no delay to unwind --
-- the peaking filters have phase response but no bulk delay. The output lines
-- up with the input sample for sample, which is what makes the alignment test
-- an exact null at shift 0 rather than a search for the right offset.
--
-- Rate: the file is written at the *source* sample rate and covers exactly the
-- span the item uses, so the new take carries the original playrate and a zero
-- start offset and lands in the same place.
--
-- A coroutine, like analysis, so the UI stays alive and cancellable.

local Analyze = require "dc.analyze"
local Wav     = require "dc.wav"

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
  local suffix = cfg.isolate and "-clicks" or "-declicked"
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

-- Coroutine body. Yields read requests, returns { path, peak, ... } or nil+msg.
function M.run(take, cfg, k, path, range)
  local geo = Analyze.geometry(take, range)
  local total = geo.total_samples
  if total < 1 then return nil, "Item has no audio" end
  if Wav.will_overflow(total, geo.nchan) then
    return nil, "Result would exceed the 4 GB WAV limit -- split the item first"
  end

  k:reset_stream()

  local w, werr = Wav.create(path, geo.nchan, geo.rate)
  if not w then return nil, werr end

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then w:abort() return nil, "Could not create audio accessor" end

  local nch = geo.nchan
  local written, want = 0, total * nch
  local peak = 0

  local function block(n)
    peak = k:process(n, cfg.isolate)
    local vals = n * nch
    local t = k.outbuf.table(1, vals)
    local to = math.min(vals, want - written)
    if to >= 1 then
      w:write(t, 1, to)
      written = written + to
    end
  end

  local ok, finished = pcall(Analyze.pump, aa, k, geo, geo.t0, total, block, 0, 1)
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
