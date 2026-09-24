-- @noindex
-- AutoTilt -- stage 4: process the target take and write the result.
--
-- Reads the take a second time and runs it through the shelf pair solve.lua
-- designed, writing a 32-bit float WAV beside the project media.
--
-- What is NOT here is latency compensation, and that is worth saying because
-- its DeNoise counterpart spends most of its length on it. Two biquads in
-- series have phase response but no bulk delay, so the output lines up with
-- the input sample for sample -- which is what makes a zero-gain render an
-- exact null at shift 0 rather than a search for the right offset.
--
-- Rate: the file is written at the take's own SOURCE sample rate and covers
-- exactly the span the item uses, so the new take carries a playrate of 1 and
-- a zero start offset and lands in the same place. This is deliberately not
-- the rate analysis read at -- analysis reads every clip at the target's rate
-- so the two sides share a bin mapping, but a render that resampled the audio
-- on the way out would be a second, invisible change to the file.
--
-- A coroutine, like analysis, so the UI stays alive and cancellable.

local Analyze = require "at.analyze"
local Wav     = require "at.wav"

local M = {}

local function sanitize(s)
  return (s:gsub("[^%w%-%. ]", "_"):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A path in the project's media directory that does not exist yet, and that
-- nothing in `avoid` has already claimed.
--
-- `avoid` matters whenever the target row is several clips off one source
-- file: none of the candidate names exists yet, so without it every clip would
-- be handed the same path and each render would overwrite the last.
function M.output_path(take, cfg, avoid)
  local src = reaper.GetMediaItemTake_Source(take)
  local fn = reaper.GetMediaSourceFileName(src, "")
  -- An unsaved project has no media directory; fall back to the source's own.
  local dir = reaper.GetProjectPath("")
  if dir == "" then dir = fn:match("^(.*)[/\\][^/\\]*$") or "." end
  local base = fn:match("([^/\\]+)$") or "audio"
  base = sanitize(base:gsub("%.[^.]+$", ""))
  local sep = package.config:sub(1, 1)
  for i = 0, 999 do
    local name = base .. "-tilt" .. (i > 0 and ("-" .. i) or "") .. ".wav"
    local p = dir .. sep .. name
    if not (avoid and avoid[p]) then
      local fh = io.open(p, "rb")
      if not fh then
        if avoid then avoid[p] = true end
        return p
      end
      fh:close()
    end
  end
  return nil
end

-- Coroutine body. Yields read requests, returns { path, peak, ... } or nil+msg.
function M.run(take, cfg, k, plan, path, frac0, frac1, range)
  local geo = Analyze.geometry(take, range)
  local total = geo.total_samples
  if total < 1 then return nil, "Item has no audio" end
  if Wav.will_overflow(total, geo.nchan) then
    return nil, "Result would exceed the 4 GB WAV limit -- split the item first"
  end

  -- The kernel's memory map fixes its channel count. A target row whose clips
  -- disagree about that would otherwise interleave into the wrong stride and
  -- come back as a render that plays at the wrong speed.
  if geo.nchan ~= k.nchan then
    return nil, string.format(
      "This clip has %d channel%s and the analysis was built for %d. " ..
      "Render the target clips in matching groups.",
      geo.nchan, geo.nchan == 1 and "" or "s", k.nchan)
  end

  k:reset_stream()
  k:set_plan(plan)

  local w, werr = Wav.create(path, geo.nchan, geo.rate)
  if not w then return nil, werr end

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then w:abort() return nil, "Could not create audio accessor" end

  local nch = geo.nchan
  local written, want = 0, total * nch
  local peak = 0

  local function block(n)
    peak = k:render(n)
    local vals = n * nch
    local t = k.outbuf.table(1, vals)
    local to = math.min(vals, want - written)
    if to >= 1 then
      w:write(t, 1, to)
      written = written + to
    end
  end

  local ok, finished = pcall(Analyze.pump, aa, k, geo, geo.t0, total, block,
                             frac0 or 0, frac1 or 1)
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
