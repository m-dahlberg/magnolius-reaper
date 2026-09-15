-- Load and save a frame table as text, so detection can be regression-tested
-- against real audio without REAPER, an accessor or a WAV decoder.
--
-- Only the features the kernel actually measures are stored. The geometry, ms
-- and slope_db are derived on load exactly as analyze.lua derives them, so the
-- file cannot disagree with itself, and level_db at 0.01 dB is far finer than
-- any threshold that reads it.
--
-- What this fixture cannot cover: it starts *after* stage 1, so a change to
-- the kernel or to the accessor reads clean here and still breaks the real
-- pipeline. Regenerate it with test/dump_frames.lua whenever stage 1 changes,
-- and keep test/verify_edit_in_reaper.lua in the habitual run.

local M = {}

-- Only the primitives are stored. The two frame durations and the accessor
-- span are derived from them on load, exactly as analyze.lua derives them, so
-- a fixture cannot carry a stale idea of the geometry: the pair used to be
-- written into the header, and at playrate 1 -- which is what every fixture is
-- captured at -- they are the same number, so a header could have agreed with
-- an analyze.lua that had them the wrong way round.
local SCALARS = { "n", "rate", "hop", "item_len", "playrate", "nchan" }

local function db(x)
  if x <= 0 then return -90 end
  local v = 10 * math.log(x, 10)
  return v < -90 and -90 or v
end

-- The geometry and the same 10 ms lookback analyze.lua uses. Header keys an
-- older fixture may still carry -- frame_dur, src_frame_dur -- are overwritten
-- here rather than trusted.
local function derive(F)
  local playrate = (F.playrate and F.playrate > 0) and F.playrate or 1
  F.playrate      = playrate
  F.acc_frame_dur = F.hop / F.rate                 -- project seconds
  F.src_frame_dur = F.hop / F.rate * playrate      -- source seconds
  F.acc_len       = F.item_len
  F.frame_dur     = nil

  local lb = math.max(1, math.floor(0.010 / F.acc_frame_dur + 0.5))
  for i = 1, F.n do
    F.ms[i] = (F.level_db[i] <= -90) and 0 or 10 ^ (F.level_db[i] / 10)
    local j = i - lb
    F.slope_db[i] = (j >= 1) and (F.level_db[i] - F.level_db[j]) or 0
  end
  return F
end

function M.load(path)
  local fh = assert(io.open(path, "r"), "cannot open " .. path)
  local hdr = fh:read("l")
  local F = { level_db = {}, sib_ratio = {}, voice_ratio = {},
              crest = {}, zcr = {}, slope_db = {}, ms = {} }
  -- `%w` does not match an underscore, so the key pattern has to say so or
  -- item_len comes back nil three stages later.
  for k, v in hdr:gmatch("([%w_]+)=([%-%d%.e]+)") do F[k] = tonumber(v) end
  fh:read("l")
  local i = 0
  for line in fh:lines() do
    i = i + 1
    local l, s, v, c, z = line:match("^(%S+)\t(%S+)\t(%S+)\t(%S+)\t(%S+)$")
    F.level_db[i], F.sib_ratio[i] = tonumber(l), tonumber(s)
    F.voice_ratio[i], F.crest[i], F.zcr[i] = tonumber(v), tonumber(c), tonumber(z)
  end
  fh:close()
  assert(i == F.n, ("frame count mismatch: %d rows, header says %d"):format(i, F.n))
  return derive(F)
end

function M.save(F, path)
  local fh = assert(io.open(path, "w"))
  local parts = {}
  for _, k in ipairs(SCALARS) do
    parts[#parts + 1] = ("%s=%.9g"):format(k, F[k])
  end
  fh:write("# " .. table.concat(parts, " ") .. "\n")
  fh:write("level_db\tsib_ratio\tvoice_ratio\tcrest\tzcr\n")
  for i = 1, F.n do
    fh:write(("%.2f\t%.4f\t%.4f\t%.2f\t%.0f\n"):format(
      F.level_db[i], F.sib_ratio[i], F.voice_ratio[i], F.crest[i], F.zcr[i]))
  end
  fh:close()
end

M.db = db
return M
