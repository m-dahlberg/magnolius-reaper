-- Spectral DeNoise -- shared fixture and measurement for the in-REAPER suites
-- that need real audio.
--
-- Where the fixture lives, and why it is not anywhere more obvious:
--
--   Not the user's selected item. A suite has no business editing something
--   the user chose, and a harness that runs repeatedly will eventually do it
--   at the worst moment.
--
--   Not a throwaway project tab. Measured on 7.75, an undo block dirties a
--   project permanently and no save clears it, so closing the tab raises the
--   modal "save changes?" prompt -- which in a headless run hangs REAPER until
--   somebody clicks it.
--
-- So: a track added at the END of whatever project is open (at the end, so no
-- existing track index moves), built up inside, and deleted on the way out
-- even when the body raised. Existing items are never touched.

local M = {}

-- Windows hand-picked off "DeNoise test 02.wav", in seconds. TONE is room tone
-- between phrases -- the preamp hiss with no voice in it. VOICE is continuous
-- speech well above the floor. Both are what the measurements below contrast;
-- for other material, re-pick them by ear and by level.
M.TONE  = { {20.70, 20.97}, {27.58, 27.75}, {40.84, 41.03},
            {48.06, 48.30}, {54.52, 54.85}, {61.50, 61.69} }
M.VOICE = { {21.85, 23.39}, {27.84, 30.60}, {35.95, 37.57}, {49.67, 50.97} }

M.HP_FC = 3000                -- "high frequency hiss" is measured above this
M.PAD   = 0.050               -- filter warm-up, read and then discarded

function M.db(p) return 10 * math.log(math.max(p, 1e-30), 10) end

-- Butterworth high-pass, one biquad, in place.
function M.highpass(t, n, sr, fc)
  local w0 = 2 * math.pi * fc / sr
  local cw, alpha = math.cos(w0), math.sin(w0) / (2 * 0.70710678)
  local a0 = 1 + alpha
  local b0, b1, b2 = (1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0
  local a1, a2 = -2 * cw / a0, (1 - alpha) / a0
  local x1, x2, y1, y2 = 0, 0, 0, 0
  for i = 1, n do
    local x = t[i]
    local y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
    x2, x1, y2, y1 = x1, x, y1, y
    t[i] = y
  end
  return t
end

-- Mean power of t[pad+1..n], broadband and above HP_FC. Destroys t.
function M.powers(t, n, pad, sr)
  local s = 0
  for i = pad + 1, n do s = s + t[i] * t[i] end
  local broad = s / (n - pad)
  M.highpass(t, n, sr, M.HP_FC)
  s = 0
  for i = pad + 1, n do s = s + t[i] * t[i] end
  return broad, s / (n - pad)
end

------------------------------------------------------------------- the track

local function snapshot_selection()
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    sel[#sel + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  return sel
end

local function restore_selection(sel)
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(sel) do
    if reaper.ValidatePtr(it, "MediaItem*") then
      reaper.SetMediaItemSelected(it, true)
    end
  end
end

-- Runs fn(track) on a fresh track at the end of the project and cleans up
-- afterwards, whether or not fn raised. Returns ok, err, plus a second flag
-- that is false if the project did not come back the way it was found.
function M.with_track(fn)
  local sel = snapshot_selection()
  local tracks0, items0 = reaper.CountTracks(0), reaper.CountMediaItems(0)
  reaper.InsertTrackAtIndex(tracks0, true)
  local tr = reaper.GetTrack(0, tracks0)

  local ok, err = pcall(fn, tr)

  pcall(reaper.DeleteTrack, tr)
  restore_selection(sel)
  local clean = reaper.CountTracks(0) == tracks0
            and reaper.CountMediaItems(0) == items0
  return ok, err, clean
end

-- An item covering the whole of `path`, on `tr`. Returns item, take.
function M.add_media(tr, path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then error("cannot open " .. path, 0) end
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",
                                reaper.GetMediaSourceLength(src))
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0)
  return item, take
end

------------------------------------------------------------------ measuring

-- Compares one window of the take against the same window of a rendered
-- 32-bit float WAV. The input comes back through the accessor and the output
-- off the file; both reads are made here, on the main thread, so neither is
-- the coroutine read that silently returns nil.
--
-- Returns in_broadband, in_hf, out_broadband, out_hf, all in dB.
function M.compare(aa, fh, data_off, geo, w)
  local nch = geo.nchan
  local n   = math.floor((w[2] - w[1] + M.PAD) * geo.rate + 0.5)
  local pad = math.floor(M.PAD * geo.rate + 0.5)
  local t0  = w[1] - M.PAD

  local buf = reaper.new_array(n * nch)
  buf.clear(0)
  if reaper.GetAudioAccessorSamples(aa, geo.rate, nch, t0, n, buf) == nil then
    error("the accessor read returned nil", 0)
  end
  local flat = buf.table(1, n * nch)
  local mono_in = {}
  for i = 1, n do
    local s = 0
    for c = 1, nch do s = s + flat[(i - 1) * nch + c] end
    mono_in[i] = s / nch
  end

  fh:seek("set", data_off + math.floor(t0 * geo.rate + 0.5) * nch * 4)
  local raw = fh:read(n * nch * 4)
  if not raw or #raw < n * nch * 4 then error("short read from the render", 0) end
  local mono_out = {}
  for i = 1, n do
    local s = 0
    for c = 1, nch do
      s = s + string.unpack("<f", raw, ((i - 1) * nch + c - 1) * 4 + 1)
    end
    mono_out[i] = s / nch
  end

  local ib, ih = M.powers(mono_in, n, pad, geo.rate)
  local ob, oh = M.powers(mono_out, n, pad, geo.rate)
  return M.db(ib), M.db(ih), M.db(ob), M.db(oh)
end

-- Energy-summed change across a group of windows: how much quieter the render
-- is than the source, broadband and above HP_FC, in dB.
function M.group(aa, fh, data_off, geo, wins, each)
  local si, sih, so, soh = 0, 0, 0, 0
  for _, w in ipairs(wins) do
    local a, b, c, d = M.compare(aa, fh, data_off, geo, w)
    if each then each(w, a, b, c, d) end
    si, sih = si + 10 ^ (a / 10), sih + 10 ^ (b / 10)
    so, soh = so + 10 ^ (c / 10), soh + 10 ^ (d / 10)
  end
  local n = #wins
  return M.db(so / n) - M.db(si / n), M.db(soh / n) - M.db(sih / n),
         M.db(si / n), M.db(sih / n)
end

-- The `data` chunk offset of a WAV. The renders here are written by dn/wav.lua
-- and always have a 44-byte header, but a file is cheap to ask.
function M.data_offset(fh)
  fh:seek("set", 12)
  while true do
    local hdr = fh:read(8)
    if not hdr or #hdr < 8 then return nil end
    local id, sz = string.unpack("<c4I4", hdr)
    local at = fh:seek()
    if id == "data" then return at end
    fh:seek("set", at + sz + (sz % 2))
  end
end

return M
