-- @noindex
-- The accessor edge: everything that reads audio, and nothing that decides.
--
-- THE load-bearing constraint in this family of scripts:
-- `reaper.GetAudioAccessorSamples` returns nil and leaves the buffer UNTOUCHED
-- when it is called from inside a Lua coroutine. Silently -- not an error, and
-- not the documented 0. A job that reads its own audio therefore analyses a
-- completely silent file and every stage downstream looks healthy.
--
-- So the job never reads. It yields a request table and the driver, which is
-- by definition on the main thread, fills it and resumes. An unserviced
-- request is a hard error, never an empty buffer.
--
-- Geometry facts encoded here, each of which is invisible at playrate 1:
--   * the take accessor's timeline is TAKE time, 0 .. item_len, and the audio
--     already has playrate, pitch shift and channel mode applied. The span to
--     read is item_len, NOT item_len * playrate.
--   * reads are anchored at 0 wherever the item sits on the timeline.
--   * GetMediaSourceSampleRate returns 0 forever on a take whose media has
--     been offline, so the file is re-probed before the project rate is ever
--     guessed.
--
-- Four passes, all at low sample rates -- the accessor resamples for us, and
-- reading low is both cheaper and, for the modal pass, finer.

local Config      = require "dr.config"
local PitchKernel = require "dr.pitch_kernel"

local M = {}

M.FLOOR_DB = -140

function M.db(ms) return (ms > 0) and 10.0 * math.log(ms, 10) or M.FLOOR_DB end

local function source_format(src)
  local rate  = reaper.GetMediaSourceSampleRate(src)
  local nchan = reaper.GetMediaSourceNumChannels(src)
  if rate > 0 and nchan > 0 then return rate, nchan, true end
  -- the file itself knows; ask it before guessing
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
  -- a guessed rate is a fact the panel and the report should both be able to
  -- state, because every later symptom is downstream of it
  return (rate > 0 and rate or 44100), (nchan > 0 and nchan or 1), false
end

function M.geometry(take)
  local item = reaper.GetMediaItemTake_Item(take)
  local src  = reaper.GetMediaItemTake_Source(take)
  local rate, nchan, known = source_format(src)
  return {
    item      = item,
    take      = take,
    playrate  = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    item_pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    item_len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    rate = rate, nchan = nchan, rate_known = known,
  }
end

function M.cache_key(take, cfg)
  local src = reaper.GetMediaItemTake_Source(take)
  return table.concat({
    reaper.GetMediaSourceFileName(src, ""),
    reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    Config.analysis_sig(cfg),
  }, "|")
end

-- MAIN THREAD ONLY. Returns true if `req` was a read request.
function M.service(req)
  if type(req) ~= "table" or not req.buf then return false end
  req.buf.clear(0)   -- the accessor does not clear; a short block would keep
                     -- the previous block's tail
  req.got = reaper.GetAudioAccessorSamples(req.aa, req.rate, req.nchan,
                                           req.t, req.n, req.buf)
  return true
end

-- Run a job to completion, servicing its reads. For tests and one-shot actions.
function M.drive(body)
  local co = coroutine.create(body)
  local a, b
  while true do
    local ok, x, y = coroutine.resume(co)
    if not ok then return nil, x end
    if coroutine.status(co) == "dead" then return x, y end
    if not M.service(x) then a, b = x, y end
  end
end

-- Read `total` units at `rate` in blocks, calling fn(done, n, nsamp) per block.
--
-- With `hopf` given, `total` and `block` count FRAMES and the request is sized
-- from the frame grid; without it they count samples. The frame grid is defined
-- in TIME, not samples: 5 ms at 44100 is 220.5 samples, so an integer hop would
-- drift half a sample per frame -- nearly half a second over a three minute
-- take, every measurement sliding against the audio it came from. Each frame
-- rounds its own start from its ABSOLUTE frame number, so nothing accumulates.
--
-- `lookahead` extra samples are appended to each request for kernels that need
-- them (YIN), overlapping successive reads.
function M.pump(aa, buf, rate, nchan, total, block, lookahead, fn, frac0, frac1, hopf)
  local done = 0
  local req = { aa = aa, rate = rate, nchan = nchan, buf = buf }
  while done < total do
    local n = math.min(block, total - done)
    local nsamp, t
    if hopf then
      local s0 = math.floor(done * hopf + 0.5)
      local s1 = math.floor((done + n) * hopf + 0.5)
      nsamp, t = s1 - s0 + lookahead, s0 / rate
    else
      nsamp, t = n + lookahead, done / rate
    end
    req.n, req.t, req.got = nsamp, t, nil
    req.progress = frac0 + (frac1 - frac0) * (done / total)
    if coroutine.yield(req) == "cancel" then return false end
    if req.got == nil then
      error("the audio accessor read was not serviced on the main thread", 0)
    end
    fn(done, n, nsamp)
    done = done + n
  end
  return true
end

-- Full analysis of one take. Coroutine body: drive it with M.drive or the
-- panel's step_job.
--   pk  a pitch kernel built at (nchan, cfg, cfg.pitch_rate)
--   k   the spectral kernel
function M.run(take, cfg, pk, k, geo)
  return function()
    local aa = reaper.CreateTakeAudioAccessor(take)
    if not aa then return nil, "could not open an audio accessor" end
    local a0, a1 = reaper.GetAudioAccessorStartTime(aa), reaper.GetAudioAccessorEndTime(aa)
    -- the span is item_len; reading item_len * playrate runs off the end
    local span = math.min(a1 - a0, geo.item_len)

    local res, err = nil, nil
    local ok, ferr = pcall(function()
      local hop_s = cfg.hop_ms / 1000.0
      local nframes = math.floor(span / hop_s)
      if nframes < 8 then error("Item is too short to analyse", 0) end

      local F = {
        n = nframes, hop_s = hop_s, span = span,
        src_rate = geo.rate, nchan = geo.nchan,
        item_len = geo.item_len, item_pos = geo.item_pos,
        playrate = geo.playrate,
        ms = {}, level_db = {}, f0 = {}, aper = {},
      }

      -- pass 1: level, at pitch_rate -- the gate only needs 0..4 kHz
      local first = true
      M.pump(aa, pk.inbuf, cfg.pitch_rate, geo.nchan, nframes,
             pk.level_frames, 0,
        function(off, nf, nsamp)
          local sq, cnt = pk:level(off, nf, nsamp, first)
          first = false
          local s, c = sq.table(1, nf), cnt.table(1, nf)
          for i = 1, nf do
            local m = (c[i] > 0) and (s[i] / c[i]) or 0
            F.ms[off + i] = m
            F.level_db[off + i] = M.db(m)
          end
        end, 0.00, 0.20, pk.hopf_level)

      -- pass 2: YIN, at pitch_rate, with the lookahead the kernel needs
      M.pump(aa, pk.inbuf, cfg.pitch_rate, geo.nchan, nframes,
             pk.pitch_frames, pk.need,
        function(off, nf, nsamp)
          local f0, ap = pk:pitch(off, nf, nsamp)
          local a, b = f0.table(1, nf), ap.table(1, nf)
          for i = 1, nf do F.f0[off + i] = a[i]; F.aper[off + i] = b[i] end
        end, 0.20, 0.45, pk.hopf_pitch)

      -- pass 3: the modal cube, at modal_rate
      k:rewind()
      local mtot = math.floor(span * cfg.modal_rate)
      M.pump(aa, k.inbuf, cfg.modal_rate, geo.nchan, mtot, k.block, 0,
        function(_, nf) k:modal(nf) end, 0.45, 0.75)

      -- pass 4: the ring cube, at pitch_rate
      local rtot = math.floor(span * cfg.pitch_rate)
      M.pump(aa, k.inbuf, cfg.pitch_rate, geo.nchan, rtot, k.block, 0,
        function(_, nf) k:ring(nf) end, 0.75, 1.00)

      F.modal_frames = k:frames()
      F.ring_frames  = k:rframes()
      res = F
    end)
    reaper.DestroyAudioAccessor(aa)
    if not ok then return nil, ferr end
    return res, err
  end
end

return M
