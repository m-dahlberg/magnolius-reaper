-- @noindex
-- Spectral DeNoise -- stage 1: read the file and build the histogram.
--
-- The only stage that touches audio on the way in. It runs the kernel's
-- analysis task over the whole take once and leaves behind a level-binned
-- spectrogram histogram in the kernel's heap. Everything after it -- band
-- placement, the profile, the gain curve -- works off that, which is why the
-- panel can respond to a slider without re-reading a single sample.
--
-- Written as a coroutine so a long take does not freeze REAPER: the UI steps
-- it under a time budget and can cancel between blocks.

local M = {}

-- Anything that changes which samples we would read, or at what rate. Denoise
-- parameters must not invalidate it -- NLM and Reduction change the render,
-- not the file's level distribution. The FFT size must, since the histogram is
-- per-bin and the bin layout changes with it, and so must max_frames, which
-- decides how many frames went into it.
function M.cache_key(take, cfg)
  local src = reaper.GetMediaItemTake_Source(take)
  local item = reaper.GetMediaItemTake_Item(take)
  return table.concat({
    reaper.GetMediaSourceFileName(src, ""),
    reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    cfg.fftsel, cfg.max_frames,
  }, "|")
end

-- Take geometry.
--
-- The take audio accessor's timeline is ITEM time, and the audio it returns
-- already has the take's playrate, pitch and channel mode applied. Measured on
-- REAPER 7.75: GetAudioAccessorEndTime returns item_len at every playrate, and
-- with B_PPITCH off a 440 Hz source comes back at 550 Hz on a playrate of 1.25.
--
-- So the span to read is item_len, NOT item_len * playrate. This was wrong for
-- as long as it existed and could not be seen at playrate 1, where the two are
-- the same number: on a stretched item the read ran past the end of the
-- accessor, capturing item_len seconds of already-stretched audio followed by
-- silence, and apply.lua then stretched it a second time.
-- A take's source can report 0 for its sample rate and channel count. It
-- happens when the project has had that media offline at some point -- the
-- drive was unplugged, the file moved -- and the source object goes on
-- reporting 0 afterwards even once the file is back, while the audio accessor
-- still returns perfectly good audio. Nothing about it looks broken.
--
-- Guessing the project rate here is what silently turned a 48 kHz take into a
-- 44.1 kHz render: analysis, the kernel and the written file all ran at the
-- wrong rate, the take still played at the right *duration*, and the only
-- visible symptom was a null test that would not null -- because the two sides
-- were then resampled independently at different seek offsets, which is a
-- sub-sample phase error no integer shift search can correct.
--
-- The file itself knows. A fresh source over the same path answers correctly
-- even when the take's own source does not, so ask that before guessing.
-- Returns rate, nchan, known -- `known` is false only when it had to guess.
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

function M.geometry(take)
  local item = reaper.GetMediaItemTake_Item(take)
  local src  = reaper.GetMediaItemTake_Source(take)

  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then playrate = 1 end
  local rate, nchan, rate_known = source_format(src)

  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  return {
    item = item, playrate = playrate, rate = rate, nchan = nchan,
    rate_known = rate_known,
    -- acc_len is the accessor's span. Named for what it is, so it cannot
    -- quietly be confused with the length of the source file again.
    item_len = item_len, acc_len = item_len,
    total_samples = math.floor(item_len * rate + 0.5),
  }
end

-- Reading audio, and why the job does not do it itself ------------------------
--
-- REAPER refuses to run GetAudioAccessorSamples inside a Lua coroutine: the
-- call returns nil and leaves the buffer exactly as it was. It does not error
-- and it does not return 0, so a job that reads its own audio quietly analyses
-- an entirely silent file -- every frame bins as digital silence, the silence
-- floor excludes all of them, and no noise lobe can be found. Nothing else on
-- this path has the problem: reaper.array's own methods and ImGui's
-- Function_SetValue_Array all work fine from a coroutine. It is this one call.
--
-- So the job never reads. It fills in a request and yields it, and whoever is
-- driving the coroutine -- which is by definition on the main thread -- does
-- the read and resumes. `service` is that half.

-- Fill a request yielded by a running job. Main thread only; that is the point.
-- Returns false if this yield was not a read request, so a driver can pass
-- anything else through untouched.
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

-- Walks `count` samples per channel from source-time `t0`, one Execute-sized
-- block at a time: ask for a block, let the driver fill the kernel's input
-- buffer, then run `fn(nsamp)` over it. The yielded request carries the 0..1
-- progress fraction with it.
-- Returns false if the caller cancelled (a yield answered with "cancel").
function M.pump(aa, k, geo, t0, count, fn, frac0, frac1)
  local done = 0
  local req = { aa = aa, rate = geo.rate, nchan = geo.nchan, buf = k.inbuf }
  while done < count do
    req.n = math.min(k.block, count - done)
    req.t = t0 + done / geo.rate
    req.progress = frac0 + (frac1 - frac0) * (done / count)
    req.got = nil
    if coroutine.yield(req) == "cancel" then return false end
    -- nil means the read did not happen: either it was made from a coroutine
    -- after all, or nobody serviced the request. Both used to show up as
    -- silence hundreds of lines later, so fail here instead.
    if req.got == nil then
      error("the audio accessor read was not serviced on the main thread", 0)
    end
    fn(req.n)
    done = done + req.n
  end
  return true
end

-- Coroutine body. Yields progress, returns true or nil + message.
function M.run(take, cfg, k)
  local geo = M.geometry(take)
  if geo.total_samples < k.fft_size * 4 then
    return nil, "Item is too short to analyse at this FFT size"
  end

  k:set_params(cfg)
  k:reset_analysis()
  k:set_stride(geo.total_samples, cfg.max_frames)

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil, "Could not create audio accessor" end

  -- pcall so the accessor is always released; coroutine.yield across pcall is
  -- allowed since Lua 5.2, which is what makes the progress reporting possible.
  local ok, finished = pcall(M.pump, aa, k, geo, 0, geo.total_samples,
                             function(n) k:analyze(n) end, 0, 1)
  reaper.DestroyAudioAccessor(aa)

  if not ok then return nil, tostring(finished) end
  if not finished then return nil, "cancelled" end

  local frames = k:frames()
  if frames < 4 then
    return nil, "Analysis produced no frames -- is the item silent?"
  end
  return { geo = geo, frames = frames, ana_hop = k.ana_hop }
end

return M
