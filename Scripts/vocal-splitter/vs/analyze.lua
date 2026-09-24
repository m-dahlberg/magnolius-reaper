-- @noindex
-- Vocal Splitter -- stage 1: sample reading and feature extraction.
--
-- Reads the take once through an audio accessor and reduces it to a frame
-- table. This is the only stage that touches audio; everything after it works
-- on the frames produced here, which is why the result is cached.

local M = {}

local FLOOR_DB = -90
local EPS = 1e-20

-- The EEL kernel is the hot loop. Interpreted Lua would take tens of seconds
-- on a five minute take, which would make live parameter tuning impossible.
local function compile_kernel(ImGui, ctx, script_dir)
  local path = script_dir .. "vs/dsp/features.eel"
  local fh = io.open(path, "rb")
  if not fh then return nil, "Cannot open " .. path end
  local code = fh:read("a")
  fh:close()

  local ok, func = pcall(ImGui.CreateFunctionFromEEL, code)
  if not ok or not func then
    return nil, "EEL compile failed: " .. tostring(func)
  end
  -- Attach or it is garbage collected out from under us.
  ImGui.Attach(ctx, func)
  return func
end

-- TPT state-variable filter coefficient. Kernel derives the rest from these.
local function svf_g(hz, rate)
  return math.tan(math.pi * math.min(hz, rate * 0.49) / rate)
end

local function db(x)
  if x <= 0 then return FLOOR_DB end
  local v = 10 * math.log(x, 10)
  return v < FLOOR_DB and FLOOR_DB or v
end

-- Cache key: anything that changes the samples we would read, or the rate we
-- would read them at. Parameter tweaks that only affect later stages must not
-- invalidate it.
function M.cache_key(take, rate)
  local src = reaper.GetMediaItemTake_Source(take)
  local fn = reaper.GetMediaSourceFileName(src, "")
  local item = reaper.GetMediaItemTake_Item(take)
  return table.concat({
    fn,
    reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    rate,
  }, "|")
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

function M.pick_rate(take, cfg)
  local src = reaper.GetMediaItemTake_Source(take)
  local sr = source_format(src)
  local rate = math.min(sr, cfg.max_rate)
  return math.max(rate, cfg.min_rate)
end

-- Returns a frames table:
--   n, rate, hop, acc_frame_dur, src_frame_dur, acc_len, item_len, playrate
--   level_db[], ms[], sib_ratio[], voice_ratio[], crest[], zcr[], slope_db[]
-- ms[] is the linear mean square; levels are averaged there, not in dB.
--
-- Frame times are ITEM-relative PROJECT seconds -- see the geometry note below
-- -- so apply.lua only has to add the item position to place an edit.
-- `range` is an optional time-selection range in PROJECT seconds (see vs/timesel.lua). The
-- accessor is anchored at 0 at the start of the ITEM, so the analysed span starts at
-- `range.t0 - item_pos` -- `t0` below -- and `origin` is where frame 0 sits in PROJECT time,
-- which is what the split points are measured from.
function M.run(take, cfg, ImGui, ctx, script_dir, progress_cb, range)
  local func, err = compile_kernel(ImGui, ctx, script_dir)
  if not func then return nil, err end

  local item     = reaper.GetMediaItemTake_Item(take)
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then playrate = 1 end
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

  -- The true OVERLAP of the item with the range; a span of 0 means no overlap.
  local t0, span_len = 0, item_len
  if range and not range.whole then
    local a = math.max(item_pos, range.t0)
    local b = math.min(item_pos + item_len, range.t1)
    if b > a then t0, span_len = a - item_pos, b - a else t0, span_len = 0, 0 end
  end

  local src   = reaper.GetMediaItemTake_Source(take)
  local nchan = math.max(1, reaper.GetMediaSourceNumChannels(src))
  local rate  = M.pick_rate(take, cfg)
  local hop   = cfg.hop

  -- Take geometry.
  --
  -- The take audio accessor's timeline is ITEM time, and the audio it returns
  -- already has the take's playrate, pitch shift and channel mode applied.
  -- Measured on REAPER 7.75: GetAudioAccessorEndTime returns item_len at every
  -- playrate (4.0 s source -> 4.0 s at playrate 1, 3.2 s at 1.25, 5.0 s at
  -- 0.8), and with B_PPITCH off a 440 Hz source read at playrate 1.25 comes
  -- back at 550 Hz. Take D_VOL, item D_VOL and D_PAN are measurably NOT
  -- applied, which is why levels here are the file's, not the mix's.
  --
  -- So the span to read is item_len, NOT item_len * playrate. Reading the
  -- longer span asked for 75 s of a stretched 60 s item and got 60 s of audio
  -- followed by 15 s of silence, which reads as a pause and moves the
  -- section and phrase structure, not merely the tail.
  --
  -- And frames are `hop` samples apart in ACCESSOR time, which is item time,
  -- which is project time. That makes hop / rate the frame duration in project
  -- seconds; the source advances playrate times faster.
  --
  -- Neither error is visible at playrate 1, where every one of these is the
  -- same number. `acc_len` and `acc_frame_dur` are named for the accessor so
  -- they cannot quietly be read as source quantities again.
  local acc_len = span_len
  local total_samples = math.floor(acc_len * rate + 0.5)
  local total_frames  = math.floor(total_samples / hop)
  if total_frames < 4 then return nil, "Item too short to analyse" end

  local block_frames  = cfg.block_frames
  local block_samples = block_frames * hop

  local inbuf = reaper.new_array(block_samples * nchan)
  local out = {}
  local OUTS = { "SUMSQ", "PEAK", "ELOW", "EHIGH", "ZCR", "N" }
  for _, name in ipairs(OUTS) do out[name] = reaper.new_array(block_frames) end

  -- Memory layout: input first, then one output array per accumulator.
  local addr = block_samples * nchan
  ImGui.Function_SetValue(func, "_SAMPLES", 0)
  for _, name in ipairs(OUTS) do
    ImGui.Function_SetValue(func, "_OUT_" .. name, addr)
    out[name .. "_addr"] = addr
    addr = addr + block_frames
  end

  ImGui.Function_SetValue(func, "_NCHAN", nchan)
  ImGui.Function_SetValue(func, "_HOP",   hop)
  ImGui.Function_SetValue(func, "_G_LO",  svf_g(cfg.lo_hz, rate))
  ImGui.Function_SetValue(func, "_K_LO",  1 / cfg.svf_q)
  ImGui.Function_SetValue(func, "_G_HI",  svf_g(cfg.hi_hz, rate))
  ImGui.Function_SetValue(func, "_K_HI",  1 / cfg.svf_q)
  ImGui.Function_SetValue(func, "_R_DC",  math.exp(-2 * math.pi * cfg.dc_hz / rate))

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil, "Could not create audio accessor" end

  local F = {
    n = total_frames, rate = rate, hop = hop,
    -- One frame, in each of the two time bases. Everything downstream asks a
    -- project-time question -- how long a pause sounds, how long a breath is,
    -- where to cut -- so acc_frame_dur is the one nearly everything wants.
    acc_frame_dur = hop / rate,              -- project (= item = accessor) s
    src_frame_dur = hop / rate * playrate,   -- source file seconds
    playrate = playrate, acc_len = acc_len, item_len = item_len, nchan = nchan,
    -- Where frame 0 sits, in take seconds and in project time. Split points are measured from
    -- origin, so a run over a time selection cuts inside it rather than at the item start.
    t0 = t0, item_pos = item_pos, origin = item_pos + t0, range = range,
    total_samples = math.floor(acc_len * rate + 0.5),
    level_db = {}, sib_ratio = {}, voice_ratio = {},
    crest = {}, zcr = {}, slope_db = {}, ms = {},
  }

  local ok, ferr = pcall(function()
    local done, first = 0, true
    while done < total_frames do
      local nf = math.min(block_frames, total_frames - done)
      local nsamp = nf * hop
      local t = t0 + (done * hop) / rate  -- accessor time, i.e. item-relative

      inbuf.clear(0)
      reaper.GetAudioAccessorSamples(aa, rate, nchan, t, nsamp, inbuf)

      ImGui.Function_SetValue(func, "_SAMPLES", 0)
      ImGui.Function_SetValue_Array(func, "_SAMPLES", inbuf)
      ImGui.Function_SetValue(func, "_NSAMP",   nsamp)
      ImGui.Function_SetValue(func, "_NFRAMES", nf)
      ImGui.Function_SetValue(func, "_RESET",   first and 1 or 0)
      first = false

      ImGui.Function_Execute(func)

      for _, name in ipairs(OUTS) do
        ImGui.Function_SetValue(func, "_OUT_" .. name, out[name .. "_addr"])
        ImGui.Function_GetValue_Array(func, "_OUT_" .. name, out[name])
      end

      local sumsq = out.SUMSQ.table(1, nf)
      local peak  = out.PEAK.table(1, nf)
      local elow  = out.ELOW.table(1, nf)
      local ehigh = out.EHIGH.table(1, nf)
      local zcr   = out.ZCR.table(1, nf)
      local cnt   = out.N.table(1, nf)

      for i = 1, nf do
        local n = cnt[i]
        if n < 1 then n = 1 end
        -- DC is already gone: the kernel blocks it at 20 Hz, before the band
        -- accumulators split. Subtracting a per-frame mean here instead used
        -- to shrink `energy` without touching elow/ehigh, which made
        -- voice_ratio -- a fraction of frame energy -- exceed 1 on most of a
        -- real take.
        local energy = sumsq[i]
        local ms = energy / n

        local k = done + i
        F.ms[k]          = ms
        F.level_db[k]    = db(ms)
        F.sib_ratio[k]   = ehigh[i] / (energy + EPS)
        F.voice_ratio[k] = elow[i]  / (energy + EPS)
        F.crest[k]       = peak[i] / (math.sqrt(ms) + EPS)
        F.zcr[k]         = zcr[i] * rate / n
      end

      done = done + nf
      if progress_cb then progress_cb(done / total_frames) end
    end
  end)

  reaper.DestroyAudioAccessor(aa)
  if not ok then return nil, tostring(ferr) end

  -- Onset slope over ~10 ms, used to tell a plosive burst from a breath.
  --
  -- Project time, like every other duration in this script: the frames hold
  -- the audio the accessor returned, which is already stretched, so 10 ms here
  -- means 10 ms of what the item plays -- which is what the ear judges a burst
  -- by. The source-time equivalent would shrink the window on a slowed take
  -- and stretch it on a sped-up one, for no reason anyone could state.
  local lookback = math.max(1, math.floor(0.010 / F.acc_frame_dur + 0.5))
  for i = 1, total_frames do
    local j = i - lookback
    F.slope_db[i] = (j >= 1) and (F.level_db[i] - F.level_db[j]) or 0
  end

  return F
end

M.FLOOR_DB = FLOOR_DB
return M
