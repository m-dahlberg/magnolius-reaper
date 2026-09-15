-- @noindex
-- Vocal Normalizer -- stage 1: read the take and reduce it to frames.
--
-- The only stage that touches audio. It walks the take once at the source rate
-- and leaves behind one frame table: per-quarter-block sums of squares through
-- the vocal band and through K-weighting, the sample count behind each, and
-- the take's peak. Everything after this works off that table, which is why
-- the gate, the target and the limits can all be dragged without re-reading a
-- sample.
--
-- Written as a coroutine so a long take does not freeze REAPER: the UI steps
-- it under a time budget and can cancel between blocks.

local Kernel = require "vn.kernel"

local M = {}

-- Anything that changes which samples would be read, or what they are filtered
-- through, or the grid they land on. Measurement and gain parameters must NOT
-- invalidate this -- they only re-derive from frames already in memory.
function M.cache_key(take, cfg)
  local Config = require "vn.config"
  local src  = reaper.GetMediaItemTake_Source(take)
  local item = reaper.GetMediaItemTake_Item(take)
  return table.concat({
    reaper.GetMediaSourceFileName(src, ""),
    reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    Config.analysis_sig(cfg),
  }, "|")
end

-- A take's source can report 0 for its sample rate and channel count. It
-- happens when the project has had that media offline at some point -- the
-- drive was unplugged, the file moved -- and the source object goes on
-- reporting 0 afterwards even once the file is back, while the audio accessor
-- still returns perfectly good audio. Nothing about it looks broken.
--
-- Never fall back to the project rate on its own. That is a guess, and when it
-- is wrong the frame grid, the filter coefficients and the reported loudness
-- are all wrong with it -- a 48 kHz take measured as 44.1 puts the band's
-- corners 8% low and reports a number that is quietly not the one asked for.
--
-- The file itself knows. A fresh source over the same path answers correctly
-- even when the take's own source does not, so ask that before guessing.
-- Returns rate, nchan, known -- `known` is false only when it had to guess,
-- and the panel says so, because everything downstream is downstream of it.
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

-- Take geometry.
--
-- The take accessor's timeline is TAKE time: it spans 0 .. item length, with
-- the take's playrate, pitch shift and channel mode ALREADY applied to the
-- audio it hands back. So the span to read is the item length, not the item
-- length times the playrate, and a take-time offset becomes project time by
-- adding the item position with no playrate factor anywhere.
--
-- That matters here even though this script writes no audio: read the scaled
-- span and the last fifth of a stretched take comes back as silence, which
-- drags a gated measurement down by however much silence got past the gate.
--
-- D_VOL and the item's D_VOL are read but never applied -- the accessor does
-- not apply them, so the measurement is of the raw audio and the gain that
-- comes out of it is an absolute volume, not a relative move. apply.lua is
-- where the two are reconciled.
function M.geometry(take)
  local item = reaper.GetMediaItemTake_Item(take)
  local src  = reaper.GetMediaItemTake_Source(take)

  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then playrate = 1 end
  local rate, nchan, rate_known = source_format(src)

  return {
    item = item, take = take,
    playrate = playrate, rate = rate, nchan = nchan, rate_known = rate_known,
    item_len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    item_pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    take_vol  = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL"),
    item_vol  = reaper.GetMediaItemInfo_Value(item, "D_VOL"),
    startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
  }
end

-- Reading audio, and why the job does not do it itself ------------------------
--
-- REAPER refuses to run GetAudioAccessorSamples inside a Lua coroutine: the
-- call returns nil and leaves the buffer exactly as it was. It does not error
-- and it does not return 0, so a job that read its own audio would quietly
-- measure an entirely silent file -- and a silent file has a perfectly
-- plausible-looking answer, several dB of boost. Nothing else on this path has
-- the problem: reaper.array's own methods and ImGui's Function_SetValue_Array
-- both work fine from a coroutine. It is this one call.
--
-- So the job never reads. It fills in a request and yields it, and whoever is
-- driving the coroutine -- which is by definition on the main thread -- does
-- the read and resumes. `service` is that half.

function M.service(req)
  if type(req) ~= "table" or not req.buf then return false end
  req.buf.clear(0)
  req.got = reaper.GetAudioAccessorSamples(req.aa, req.rate, req.nchan,
                                           req.t, req.n, req.buf)
  return true
end

-- Run a job to completion, servicing its reads. The panel drives its own jobs
-- a slice at a time under a time budget so the UI stays alive; tests and
-- one-shot callers want the whole thing in one go.
function M.drive(body)
  local job = coroutine.create(body)
  while true do
    local ok, a, b = coroutine.resume(job)
    if not ok then return nil, tostring(a) end
    if coroutine.status(job) == "dead" then return a, b end
    M.service(a)
  end
end

-- Walk `total_frames` frames in contiguous, non-overlapping blocks.
--
-- Contiguous is not a detail: the kernel's filter state carries from one
-- Execute to the next, so the reads have to tile the take exactly once. A gap
-- would ring the filters at every block boundary and an overlap would count
-- the same samples twice.
--
-- `avail` caps the last read at the samples the accessor actually has, so a
-- take whose final frame is short is measured over what is there rather than
-- over a frame padded with silence.
function M.pump(aa, k, rate, hopf, total_frames, avail, fn, frac0, frac1, t0)
  local done = 0
  local first = true
  local req = { aa = aa, rate = rate, nchan = k.nchan, buf = k.inbuf }
  while done < total_frames do
    local nf = math.min(k.frames, total_frames - done)
    local s0 = Kernel.frame_sample(done, hopf)
    local s1 = Kernel.frame_sample(done + nf, hopf)
    if s1 > avail then s1 = avail end
    req.n = s1 - s0
    if req.n < 0 then req.n = 0 end
    req.t = (t0 or 0) + s0 / rate
    req.progress = frac0 + (frac1 - frac0) * (done / total_frames)
    req.got = nil
    if coroutine.yield(req) == "cancel" then return false end
    -- nil means the read did not happen: either it was made from a coroutine
    -- after all, or nobody serviced the request. Both would otherwise show up
    -- as an entirely plausible wrong number, so fail here instead.
    if req.got == nil then
      error("the audio accessor read was not serviced on the main thread", 0)
    end
    fn(done, nf, req.n, first)
    first = false
    done = done + nf
  end
  return true
end

-- Coroutine body. Yields read requests, returns the frame table or nil + msg.
--
-- frac0/frac1 scale the progress this run reports into a caller's own range,
-- so a job measuring eight selected items shows one bar that fills once rather
-- than eight that each restart at zero.
function M.run(take, cfg, k, geo, frac0, frac1)
  geo = geo or M.geometry(take)
  frac0, frac1 = frac0 or 0, frac1 or 1

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil, "Could not create audio accessor" end

  -- Ask the accessor where it starts and ends rather than deriving it. The
  -- span is the item length, but taking it from the accessor means the one
  -- assumption this stage rests on is checked against the thing that makes it
  -- true, on every run.
  local a0 = reaper.GetAudioAccessorStartTime(aa)
  local span = math.min(reaper.GetAudioAccessorEndTime(aa) - a0, geo.item_len)

  local hop_s = k.hop_s
  local avail = math.floor(span * geo.rate)
  -- At least one frame even for a very short item: measuring a 60 ms ad-lib
  -- over what it has beats refusing to measure it. The kernel clamps the frame
  -- to the samples that exist, and Loudness.blocks marks the result `short`.
  local total = math.max(1, math.floor(span / hop_s))

  local F = {
    n = total, hop_s = hop_s,
    rate = geo.rate, nchan = geo.nchan,
    -- Take seconds. Adding item_pos gives project time; no playrate factor,
    -- because the accessor already applied it.
    span = span, item_len = geo.item_len,
    playrate = geo.playrate, item_pos = geo.item_pos,
    zb = {}, zk = {}, cnt = {}, peak = 0,
  }

  -- pcall so the accessor is always released; coroutine.yield across pcall has
  -- been legal since Lua 5.2, which is what makes a cancellable read possible.
  local ok, finished = pcall(function()
    return M.pump(aa, k, geo.rate, k.hopf, total, avail,
      function(foff, nf, nsamp, first)
        local zb, zk, cnt, pk = k:measure(foff, nf, nsamp, first)
        local b, kk = zb.table(1, nf), zk.table(1, nf)
        local c, p  = cnt.table(1, nf), pk.table(1, nf)
        for i = 1, nf do
          F.zb[foff + i]  = b[i]
          F.zk[foff + i]  = kk[i]
          F.cnt[foff + i] = c[i]
          if p[i] > F.peak then F.peak = p[i] end
        end
      end, frac0, frac1, a0)
  end)

  reaper.DestroyAudioAccessor(aa)

  if not ok then return nil, tostring(finished) end
  if not finished then return nil, "cancelled" end
  return F
end

return M
