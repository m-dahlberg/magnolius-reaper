-- @noindex
-- Loudness Envelope -- stage 1: read the source and reduce it to frames.
--
-- The only stage that touches audio. It walks each clip once at the source
-- rate and leaves behind one 10 ms energy table per clip, already scaled by
-- the take and item volume. Everything after this -- the detector, the gate,
-- the outline, the shaping -- works off those tables, which is why every
-- control in the panel can be dragged without re-reading a sample.
--
-- Written as a coroutine so a long take does not freeze REAPER: the UI steps
-- it under a time budget and can cancel between blocks.

local Kernel = require "le.kernel"

local M = {}

-- A take's source can report 0 for its sample rate and channel count when the
-- project has had that media offline at some point, and goes on reporting 0
-- once the file is back -- while the accessor returns perfectly good audio.
-- Never fall back to the project rate on its own: a 48 kHz take framed as 44.1
-- puts every frame 8% long. A fresh source over the same file answers
-- correctly, so ask that first. `known` is false only when it had to guess.
local function source_format(src)
  local rate  = reaper.GetMediaSourceSampleRate(src)
  local nchan = reaper.GetMediaSourceNumChannels(src)
  if rate > 0 and nchan > 0 then return rate, nchan, true end

  local fn = reaper.GetMediaSourceFileName(src, "")
  if fn ~= "" then
    local probe = reaper.PCM_Source_CreateFromFile(fn)
    if probe then
      local r = reaper.GetMediaSourceSampleRate(probe)
      local c = reaper.GetMediaSourceNumChannels(probe)
      reaper.PCM_Source_Destroy(probe)
      if r > 0 then rate = r end
      if c > 0 then nchan = c end
      if rate > 0 and nchan > 0 then return rate, nchan, true end
    end
  end

  if rate <= 0 then
    rate = tonumber(reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)) or 0
    if rate <= 0 then rate = 48000 end
  end
  return rate, math.max(1, nchan), false
end

-- What the read needs to know about one clip. The accessor applies the take's
-- playrate, pitch, channel mode and take FX; it applies NEITHER take volume
-- NOR item volume, and the rider on that track would hear both -- so they are
-- folded into the energies here. Squared, so a polarity flip (negative D_VOL)
-- is a gain of one, as it is to a level meter.
function M.geometry(clip)
  local src = reaper.GetMediaItemTake_Source(clip.take)
  local rate, nchan, known = source_format(src)
  local g = reaper.GetMediaItemTakeInfo_Value(clip.take, "D_VOL")
          * reaper.GetMediaItemInfo_Value(clip.item, "D_VOL")
  return {
    rate = rate, nchan = nchan, rate_known = known, gain2 = g * g,
    playrate = reaper.GetMediaItemTakeInfo_Value(clip.take, "D_PLAYRATE"),
  }
end

-- Reading audio, and why the job does not do it itself ------------------------
--
-- GetAudioAccessorSamples does not work inside a Lua coroutine: it returns nil
-- and leaves the buffer as it was -- no error, not even the documented 0. A job
-- that read its own audio would measure a completely silent take, and the
-- curve for silence is a perfectly plausible flat line. So the job fills in a
-- request and yields it, and whoever drives the coroutine -- by definition on
-- the main thread -- does the read and resumes. `service` is that half.

function M.service(req)
  if type(req) ~= "table" or not req.buf then return false end
  req.buf.clear(0)
  req.got = reaper.GetAudioAccessorSamples(req.aa, req.rate, req.nchan,
                                           req.t, req.n, req.buf)
  return true
end

-- Run a job to completion, servicing its reads. The panel steps its jobs a
-- slice at a time; tests and one-shot callers want the whole thing.
function M.drive(body)
  local job = coroutine.create(body)
  while true do
    local ok, a, b = coroutine.resume(job)
    if not ok then return nil, tostring(a) end
    if coroutine.status(job) == "dead" then return a, b end
    M.service(a)
  end
end

-- Coroutine body for one clip. Yields read requests; returns
-- { t = project time of the first frame, e = { mean energy per frame } },
-- or nil + message.
--
-- frac0/frac1 scale this clip's progress into the caller's range, so a track
-- of forty clips shows one bar that fills once.
function M.run(clip, k, geo, frac0, frac1)
  frac0, frac1 = frac0 or 0, frac1 or 1
  local aa = reaper.CreateTakeAudioAccessor(clip.take)
  if not aa then return nil, "Could not create an audio accessor." end

  -- Ask the accessor where it starts and ends rather than deriving it, so the
  -- take-time assumption is checked against the thing that makes it true.
  local a0 = reaper.GetAudioAccessorStartTime(aa)
  local aend = reaper.GetAudioAccessorEndTime(aa)
  local tstart = a0 + clip.toff
  local dur = math.min(clip.dur, aend - tstart)

  local hopf = k.hopf
  local total = math.max(1, math.floor(dur / k.hop_s))
  local avail = math.max(0, math.floor(dur * geo.rate))
  local out = { t = clip.pos + clip.toff, e = {} }

  -- pcall so the accessor is always released; yield across pcall is legal
  -- since Lua 5.2, which is what makes a cancellable read possible.
  local ok, finished = pcall(function()
    local done = 0
    local req = { aa = aa, rate = geo.rate, nchan = k.nchan, buf = k.inbuf }
    while done < total do
      local nf = math.min(k.frames, total - done)
      local s0 = Kernel.frame_sample(done, hopf)
      local s1 = math.min(Kernel.frame_sample(done + nf, hopf), avail)
      req.n = math.max(0, s1 - s0)
      req.t = tstart + s0 / geo.rate
      req.progress = frac0 + (frac1 - frac0) * (done / total)
      req.got = nil
      if coroutine.yield(req) == "cancel" then return false end
      -- nil means the read did not happen -- made from a coroutine after all,
      -- or never serviced. Either would be an entirely plausible flat curve.
      if req.got == nil then
        error("the audio accessor read was not serviced on the main thread", 0)
      end
      local E, N = k:measure(done, nf, req.n)
      local e, n = E.table(1, nf), N.table(1, nf)
      for i = 1, nf do
        out.e[done + i] = n[i] > 0 and (e[i] / n[i] * geo.gain2) or 0
      end
      done = done + nf
    end
    return true
  end)

  reaper.DestroyAudioAccessor(aa)
  if not ok then return nil, tostring(finished) end
  if not finished then return nil, "cancelled" end
  return out
end

return M
