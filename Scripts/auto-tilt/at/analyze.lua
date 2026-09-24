-- @noindex
-- AutoTilt -- stage 1: read the clips and build the level-bucketed cube.
--
-- The only stage that touches audio. It runs the kernel's analysis task over
-- each selected clip once and leaves behind a spectrum cube per side.
-- Everything after it -- the gate, the band limits, the pivot, the solve --
-- works off that, which is why dragging the pivot re-answers the whole
-- question without re-reading a sample.
--
-- Written as a coroutine so a long take does not freeze REAPER: the UI steps
-- it under a time budget and can cancel between blocks.
--
-- Every clip is read at the TARGET take's sample rate and channel count, not
-- at its own. The accessor resamples on the way out, so this costs nothing,
-- and it buys two things that would otherwise be bugs: several reference clips
-- can be power-summed into one cube, and one bin-to-Hz mapping covers both
-- sides. A 44.1 kHz reference against a 48 kHz target would otherwise put the
-- pivot between different bins on each side.

local Config   = require "at.config"
local Spectrum = require "at.spectrum"

local M = {}

-- Anything that changes which samples would be read. The pivot, the band
-- limits, the gate and the shelf slope are all deliberately absent: they only
-- change what is computed from the cube, and excluding them is what makes them
-- live controls.
function M.cache_key(sel, cfg)
  local parts = { Config.analysis_sig(cfg) }
  local function add(list, tag)
    for _, e in ipairs(list) do
      local src = reaper.GetMediaItemTake_Source(e.take)
      parts[#parts + 1] = table.concat({
        tag,
        reaper.GetMediaSourceFileName(src, ""),
        reaper.GetMediaItemTakeInfo_Value(e.take, "D_STARTOFFS"),
        reaper.GetMediaItemInfo_Value(e.item, "D_LENGTH"),
        reaper.GetMediaItemTakeInfo_Value(e.take, "D_PLAYRATE"),
      }, ",")
    end
  end
  add(sel.target, "t")
  add(sel.refs, "r")
  return table.concat(parts, "|")
end

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

function M.geometry(take, range)
  local item = reaper.GetMediaItemTake_Item(take)
  local src  = reaper.GetMediaItemTake_Source(take)

  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then playrate = 1 end
  local rate, nchan, rate_known = source_format(src)

  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  local _t0, _span = M.clip_span(item, range)

  return {
    item = item, playrate = playrate, rate = rate, nchan = nchan,
    rate_known = rate_known,
    -- acc_len is the accessor's span. Named for what it is, so it cannot
    -- quietly be confused with the length of the source file again.
    item_len = item_len, acc_len = _span, t0 = _t0, range = range,
    total_samples = math.floor(_span * rate + 0.5),
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

-- One side of the comparison: every clip in `clips`, accumulated into the same
-- cube. Several reference clips summing into one spectrum is a power sum,
-- which is the right way to combine them -- two takes of the same part read as
-- one louder take, not as an average that could sit between two tones neither
-- of them has.
--
-- `rate` and `nchan` come from the target, not from each clip. See the header.
--- Where a time-selection range falls inside ONE item, in take seconds.
---
--- Returns (t0, span). A span of 0 means the item lies outside the range entirely and should be
--- skipped -- with several clips on a track, a selection over one phrase touches some of them
--- and misses the rest, and a zero-length read is not the same as an error.
function M.clip_span(item, range)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if not range or range.whole then return 0, len end
  local a = math.max(pos, range.t0)
  local b = math.min(pos + len, range.t1)
  if b <= a then return 0, 0 end
  return a - pos, b - a
end

function M.run_side(clips, k, rate, nchan, frac0, frac1, range)
  k:reset_analysis()
  local span = frac1 - frac0

  local total = 0
  for _, e in ipairs(clips) do
    local _, len = M.clip_span(e.item, range)
    total = total + math.floor(len * rate + 0.5)
  end
  if total < k.fft_size * 2 then
    return nil, "Too little audio to analyse at this FFT size"
  end

  local done = 0
  for _, e in ipairs(clips) do
    local t0, len = M.clip_span(e.item, range)
    local n = math.floor(len * rate + 0.5)
    if n > 0 then
      local geo = { rate = rate, nchan = nchan }
      local aa = reaper.CreateTakeAudioAccessor(e.take)
      if not aa then return nil, "Could not create audio accessor" end
      -- pcall so the accessor is always released; coroutine.yield across pcall
      -- is allowed since Lua 5.2, which is what makes progress reporting and
      -- cancellation possible from inside the read.
      local ok, finished = pcall(M.pump, aa, k, geo, t0, n,
        function(nn) k:analyze(nn) end,
        frac0 + span * (done / total),
        frac0 + span * ((done + n) / total))
      reaper.DestroyAudioAccessor(aa)
      if not ok then return nil, tostring(finished) end
      if not finished then return nil, "cancelled" end
      done = done + n
    end
  end

  local frames = k:frames()
  if frames < 2 then
    return nil, "Analysis produced no frames -- are the clips silent?"
  end

  local rows, counts = k:cube()
  local ana = Spectrum.build(rows, counts, k.nbins, k.nlev, k.lev0)
  ana.rate, ana.fft_size, ana.nchan = rate, k.fft_size, nchan
  ana.clips = #clips
  return ana
end

-- Coroutine body. Yields read requests, returns { target, ref } or nil + msg.
--
-- The target is read first so that a cancel part way through still leaves the
-- more expensive half done, and because the reference half is skipped entirely
-- when there is none.
--- `range` narrows BOTH sides. Matching a section of the target against the whole of the
--- reference compares different moments of the arrangement, and reading a full-length backing
--- item for a twelve-second selection is most of the wait. Same window, both sides.
function M.run(sel, cfg, k, geo, range)
  local half = #sel.refs > 0 and 0.5 or 1.0

  local target, err = M.run_side(sel.target, k, geo.rate, geo.nchan, 0, half, range)
  if not target then return nil, err end

  local ref
  if #sel.refs > 0 then
    ref, err = M.run_side(sel.refs, k, geo.rate, geo.nchan, half, 1.0, range)
    if not ref then return nil, err end
  end

  return { target = target, ref = ref, geo = geo }
end

return M
