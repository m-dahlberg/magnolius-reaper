-- @noindex
-- The second pass: read the take again, run it through the render chain, and
-- write a 32-bit float WAV.
--
-- Offline rendering has NO host PDC. The chain's latency is pushed through as
-- extra samples and the same count is dropped from the head of the output; off
-- by one and the whole take slides against the original. `Config.latency` and
-- the kernel must agree exactly, which the selftest asserts at +-1 sample.
--
-- The file is written at the take's SOURCE rate over the item's span, and the
-- filters are designed at that rate too -- a biquad designed at the wrong rate
-- puts its centre frequency somewhere else.

local Config  = require "dr.config"
local Analyze = require "dr.analyze"
local Wav     = require "dr.wav"

local M = {}

function M.output_path(take, cfg, avoid)
  local src = reaper.GetMediaItemTake_Source(take)
  local fn  = reaper.GetMediaSourceFileName(src, "")
  local base = fn:match("([^/\\]+)%.[^.]*$") or fn:match("([^/\\]+)$") or "take"
  local dir = reaper.GetProjectPath("")
  if dir == "" then dir = fn:match("^(.*[/\\])") or "." end
  local sep = dir:match("[/\\]$") and "" or "/"
  local function exists(p)
    local fh = io.open(p, "r")
    if fh then fh:close(); return true end
    return (avoid and avoid[p]) or false
  end
  local tag = cfg.residual and "residual" or "deresonated"
  local p = string.format("%s%s%s-%s.wav", dir, sep, base, tag)
  local n = 1
  while exists(p) do
    n = n + 1
    p = string.format("%s%s%s-%s-%d.wav", dir, sep, base, tag, n)
  end
  if avoid then avoid[p] = true end
  return p
end

-- Coroutine body. Drive with Analyze.drive or the panel's step_job.
function M.run(take, cfg, k, filters, t60_of, path, frac0, frac1)
  return function()
    local geo = Analyze.geometry(take)
    if geo.nchan ~= k.nchan then
      return nil, string.format(
        "the kernel was built for %d channel(s) and this take has %d",
        k.nchan, geo.nchan)
    end
    local aa = reaper.CreateTakeAudioAccessor(take)
    if not aa then return nil, "could not open an audio accessor" end
    local span = math.min(reaper.GetAudioAccessorEndTime(aa)
                          - reaper.GetAudioAccessorStartTime(aa), geo.item_len)
    local rate  = geo.rate
    local total = math.floor(span * rate)
    local lat   = Config.latency(cfg)

    if Wav.will_overflow(total, geo.nchan) then
      reaper.DestroyAudioAccessor(aa)
      return nil, "the rendered file would exceed 4 GB"
    end
    local w, werr = Wav.create(path, geo.nchan, rate)
    if not w then reaper.DestroyAudioAccessor(aa); return nil, werr end

    k:begin_render(cfg, rate, filters, t60_of)


    local want    = total * geo.nchan     -- values to keep
    local dropped = 0                     -- values still to discard
    local todrop  = lat * geo.nchan
    local written = 0
    local peak    = 0

    local ok, err = pcall(function()
      -- read `lat` extra samples past the end; the accessor returns silence
      -- there, which is what flushes the chain
      Analyze.pump(aa, k.inbuf, rate, geo.nchan, total + lat, k.block, 0,
        function(_, n)
          local p = k:render(n)
          if p > peak then peak = p end
          local o = k.outbuf.table(1, n * geo.nchan)
          local from = 1
          if dropped < todrop then
            local skip = math.min(todrop - dropped, #o)
            dropped = dropped + skip
            from = skip + 1
          end
          if from <= #o and written < want then
            local to = math.min(#o, from + (want - written) - 1)
            if to >= from then
              w:write(o, from, to)
              written = written + (to - from + 1)
            end
          end
        end, frac0 or 0, frac1 or 1)
    end)

    reaper.DestroyAudioAccessor(aa)
    if not ok then w:abort(); return nil, err end
    w:close()
    return { path = path, peak = peak, nchan = geo.nchan, rate = rate,
             samples = math.floor(written / geo.nchan), playrate = geo.playrate }
  end
end

return M
