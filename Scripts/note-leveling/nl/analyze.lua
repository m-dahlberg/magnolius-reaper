-- @noindex
-- Note Leveling -- stage 1: read the take and reduce it to frames.
--
-- The only stage that touches audio. It walks the take twice -- once at the
-- source rate for level, once at the pitch rate for YIN -- and leaves behind
-- one frame table on a single time grid. Everything after this works off that
-- table, which is why a floor or ceiling slider can redraw the panel without
-- re-reading a sample.
--
-- Written as a coroutine so a long take does not freeze REAPER: the UI steps
-- it under a time budget and can cancel between blocks.

local Kernel = require "nl.kernel"

local M = {}

local FLOOR_DB = -120

-- Anything that changes which samples we would read, or the grid they are
-- reduced onto. Cluster and level parameters must not invalidate it -- they
-- only re-derive from frames already in memory.
function M.cache_key(take, cfg)
  local Config = require "nl.config"
  local src = reaper.GetMediaItemTake_Source(take)
  local item = reaper.GetMediaItemTake_Item(take)
  return table.concat({
    reaper.GetMediaSourceFileName(src, ""),
    reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    Config.analysis_sig(cfg),
  }, "|")
end

-- Take geometry.
--
-- The take accessor's timeline is TAKE time, not source time and not project
-- time: it spans 0 .. item length, with the take's playrate and preserve-pitch
-- setting already applied to the audio it hands back. Verified on 7.75 across
-- playrates 1.0, 1.5 and 0.5 -- GetAudioAccessorEndTime returned the item
-- length in every case, and a burst one second into a 3 s source came back at
-- 0.6 s on an item stretched to playrate 1.5.
--
-- Two consequences, and they are the whole reason this comment exists:
--   * the span to analyse is the item length, NOT item_length * playrate;
--   * a take-time offset becomes project time by adding the item position,
--     with no playrate factor anywhere.
-- Reads still anchor at the accessor's own start time rather than at the
-- item's project position.
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
    item_len = item_len,
    item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    -- Only the take markers need this. They are stored in SOURCE position,
    -- which is the one coordinate system in this script that is neither take
    -- time nor project time.
    startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
  }
end

-- Reading audio, and why the job does not do it itself ------------------------
--
-- REAPER refuses to run GetAudioAccessorSamples inside a Lua coroutine: the
-- call returns nil and leaves the buffer exactly as it was. It does not error
-- and it does not return 0, so a job that reads its own audio quietly analyses
-- an entirely silent file. Nothing else on this path has the problem:
-- reaper.array's own methods and ImGui's Function_SetValue_Array all work fine
-- from a coroutine. It is this one call.
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

-- Walk `total_frames` frames in blocks, asking the driver for the samples each
-- block needs and then handing them to `fn(foff, nframes, nsamp)`.
--
-- `lookahead` is what makes the pitch pass work without any carry-over state
-- in the kernel: YIN's last frame reaches win + taumax samples past its own
-- start, so the read is that much longer than the span the block advances by.
-- Successive reads overlap by that much, which costs a few hundred samples and
-- saves a ring buffer.
function M.pump(aa, k, rate, hopf, total_frames, block_frames, lookahead,
                fn, frac0, frac1, t0)
  local done = 0
  local req = { aa = aa, rate = rate, nchan = k.nchan, buf = k.inbuf }
  while done < total_frames do
    local nf = math.min(block_frames, total_frames - done)
    local s0 = Kernel.frame_sample(done, hopf)
    local s1 = Kernel.frame_sample(done + nf, hopf)
    req.n = s1 - s0 + lookahead
    req.t = (t0 or 0) + s0 / rate
    req.progress = frac0 + (frac1 - frac0) * (done / total_frames)
    req.got = nil
    if coroutine.yield(req) == "cancel" then return false end
    -- nil means the read did not happen: either it was made from a coroutine
    -- after all, or nobody serviced the request. Both would otherwise show up
    -- as silence hundreds of lines later, so fail here instead.
    if req.got == nil then
      error("the audio accessor read was not serviced on the main thread", 0)
    end
    fn(done, nf, req.n)
    done = done + nf
  end
  return true
end

local function db(ms)
  if ms <= 0 then return FLOOR_DB end
  local v = 10 * math.log(ms, 10)
  return v < FLOOR_DB and FLOOR_DB or v
end

-- Coroutine body. Yields read requests, returns the frame table or nil + msg.
--
-- frac0/frac1 scale the progress this run reports into a caller's own range.
-- The rider's job runs the target and then several reference clips, and a
-- progress bar that restarted at zero four times would be worse than none.
function M.run(take, cfg, k, geo, frac0, frac1)
  geo = geo or M.geometry(take)
  frac0, frac1 = frac0 or 0, frac1 or 1
  local function at(f) return frac0 + (frac1 - frac0) * f end
  local hop_s = cfg.hop_ms / 1000

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil, "Could not create audio accessor" end

  -- Ask the accessor where it starts and ends rather than deriving it. The
  -- span is the item length, but taking it from the accessor means the one
  -- assumption this stage rests on is checked against the thing that makes it
  -- true, every run.
  local a0 = reaper.GetAudioAccessorStartTime(aa)
  local span = math.min(reaper.GetAudioAccessorEndTime(aa) - a0, geo.item_len)

  local total = math.floor(span / hop_s)
  if total < 8 then
    reaper.DestroyAudioAccessor(aa)
    return nil, "Item is too short to analyse"
  end

  local F = {
    n = total, hop_s = hop_s,
    src_rate = geo.rate, pitch_rate = cfg.pitch_rate, nchan = geo.nchan,
    -- Take seconds. Adding item_pos gives project time; there is no playrate
    -- factor, because the accessor already applied it.
    span = span, item_len = geo.item_len,
    playrate = geo.playrate, item_pos = geo.item_pos,
    -- ms/level_db are broadband, and are what the per-note leveling measures.
    -- bp_ms/bp_db are the same frames through the vocal band, and are what the
    -- rider measures -- on the target and, via M.run_ref, on the reference.
    ms = {}, level_db = {}, bp_ms = {}, bp_db = {}, f0 = {}, aper = {},
  }

  -- pcall so the accessor is always released; coroutine.yield across pcall is
  -- allowed since Lua 5.2, which is what makes the progress reporting possible.
  local ok, finished = pcall(function()
    -- Pass one: level, at the source rate, no lookahead.
    local first = true
    local done = M.pump(aa, k, geo.rate, k.hopf_level, total,
      k.level_frames, 0,
      function(foff, nf, nsamp)
        local sumsq, cnt, bpsq = k:level(foff, nf, nsamp, first)
        first = false
        local ss, nn, bb = sumsq.table(1, nf), cnt.table(1, nf), bpsq.table(1, nf)
        for i = 1, nf do
          local n = nn[i]
          if n < 1 then n = 1 end
          local ms, bms = ss[i] / n, bb[i] / n
          F.ms[foff + i] = ms
          F.level_db[foff + i] = db(ms)
          F.bp_ms[foff + i] = bms
          F.bp_db[foff + i] = db(bms)
        end
      end, at(0), at(0.35), a0)
    if not done then return false end

    -- Pass two: YIN, on audio the accessor resamples down for us.
    done = M.pump(aa, k, cfg.pitch_rate, k.hopf_pitch, total,
      k.pitch_frames, k.need,
      function(foff, nf, nsamp)
        local f0, aper = k:pitch(foff, nf, nsamp)
        local ff, aa_ = f0.table(1, nf), aper.table(1, nf)
        for i = 1, nf do
          F.f0[foff + i]   = ff[i]
          F.aper[foff + i] = aa_[i]
        end
      end, at(0.35), at(1), a0)
    return done
  end)

  reaper.DestroyAudioAccessor(aa)

  if not ok then return nil, tostring(finished) end
  if not finished then return nil, "cancelled" end
  return F
end

-- Reference pass --------------------------------------------------------------
--
-- The rider's reference clips need the level pass and nothing else: no pitch,
-- no notes, just how loud the arrangement is over the vocal band, frame by
-- frame. That is the whole difference between this and M.run -- same accessor,
-- same grid, same kernel task, one pass instead of two -- and it is worth its
-- own entry point rather than a flag on M.run, because skipping YIN is the
-- entire reason a reference clip does not cost minutes.
--
-- Returns a frame table carrying bp_ms on the same hop grid as the target's,
-- plus the item position, which is what lets several references at different
-- places on the timeline be mixed onto one project-time axis.
function M.run_ref(take, cfg, k, geo, frac0, frac1)
  geo = geo or M.geometry(take)
  local hop_s = cfg.hop_ms / 1000

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil, "Could not create audio accessor" end

  local a0 = reaper.GetAudioAccessorStartTime(aa)
  local span = math.min(reaper.GetAudioAccessorEndTime(aa) - a0, geo.item_len)
  local total = math.floor(span / hop_s)

  local R = {
    n = total, hop_s = hop_s, span = span,
    item_pos = geo.item_pos, playrate = geo.playrate,
    rate = geo.rate, nchan = geo.nchan,
    bp_ms = {}, ms = {},
  }
  if total < 1 then
    reaper.DestroyAudioAccessor(aa)
    return R
  end

  local first = true
  local ok, finished = pcall(function()
    return M.pump(aa, k, geo.rate, k.hopf_level, total, k.level_frames, 0,
      function(foff, nf, nsamp)
        local sumsq, cnt, bpsq = k:level(foff, nf, nsamp, first)
        first = false
        local ss, nn, bb = sumsq.table(1, nf), cnt.table(1, nf), bpsq.table(1, nf)
        for i = 1, nf do
          local n = nn[i]
          if n < 1 then n = 1 end
          R.ms[foff + i]    = ss[i] / n
          R.bp_ms[foff + i] = bb[i] / n
        end
      end, frac0 or 0, frac1 or 1, a0)
  end)

  reaper.DestroyAudioAccessor(aa)
  if not ok then return nil, tostring(finished) end
  if not finished then return nil, "cancelled" end
  return R
end

M.FLOOR_DB = FLOOR_DB
M.db = db
return M
