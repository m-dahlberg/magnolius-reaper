-- @noindex
-- Spectral DeNoise -- parameter defaults and persistence.
--
-- Pure Lua with no hard reaper dependency beyond the load/save helpers, so
-- the profile and gain stages can be exercised headlessly.

local M = {}

M.EXT_SECTION = "spectral_denoise"

M.FFT_SIZES = { 1024, 2048, 4096 }

M.defaults = {
  -- A time selection narrows what is analysed and what is written; this overrides that back
  -- to the whole item without making you clear the selection.
  ignore_time_selection = false,
  -- The one place the two halves usefully differ: build the noise profile from the selection
  -- -- a passage of room tone, say -- and clean the WHOLE item with it. No split then, because
  -- everything is processed.
  process_whole_item = false,

  -- Analysis ----------------------------------------------------------------
  fftsel        = 2,        -- index into FFT_SIZES
  max_frames    = 20000,    -- analysis frames; the stride is derived from this

  -- Noise band ---------------------------------------------------------------
  -- Which frames of the file count as noise-only, as a range on the frame
  -- level histogram. Auto puts it on the room-tone lobe.
  band_auto     = true,
  band_below_db = 8,        -- auto: band starts this far under the lobe peak
  band_above_db = 4,        -- auto: and ends this far over it
  band_lo_db    = -60,      -- used when band_auto is off
  band_hi_db    = -48,
  silence_db    = -100,     -- frames below this are edited-in digital silence,
                            -- not room tone, and never join the profile
  skip_silence  = true,     -- and so is any lobe with a wide empty gap above
                            -- it, whatever its level -- stripped pauses, a
                            -- hard gate, or a 16-bit master's dithered
                            -- silence. See profile.first_real_bin.
  prof_offset_db = 0,       -- trim the whole profile up or down

  -- Denoise (SpectralDenoise JSFX sliders 1-6, 16-17) -------------------------
  mode          = 0,        -- 0 static profile, 1 adaptive SPP-MMSE
  reduction     = 10,       -- dB
  strength      = 30,       -- Berouti alpha 1..4
  smoothing     = 50,
  residual      = false,    -- render what is removed instead
  whitening     = 0,        -- %
  nlm           = 0,        -- 0 off, 1 eco, 2 full

  -- Output gate / expander (JSFX sliders 8-15) --------------------------------
  gate_on       = false,
  gthresh       = -50,
  gattack       = 5,
  ghold         = 100,
  grelease      = 200,
  gmode         = 0,        -- 0 gate, 1 expander
  gratio        = 3,
  gauto         = false,    -- auto vocal timing

  -- Output --------------------------------------------------------------------
  new_take      = true,     -- add the result as a take, keeping the original
  select_take   = true,     -- and make it the active one
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- Restore every tunable to its default. In place, because the panel holds one
-- cfg table as an upvalue and hands it to the kernel, the profile and the
-- render -- swapping the table would leave those pointing at the old one.
-- Keys the panel added for itself (the band record the render stamps on) go
-- too, so a reset really is the state a fresh install starts in.
function M.reset(cfg)
  local extra = {}
  for k in pairs(cfg) do
    if M.defaults[k] == nil then extra[#extra + 1] = k end
  end
  for _, k in ipairs(extra) do
    cfg[k] = nil
    if reaper then reaper.DeleteExtState(M.EXT_SECTION, k, true) end
  end
  for k, v in pairs(M.defaults) do cfg[k] = v end
  M.save(cfg)
  return cfg
end

function M.fft_size(cfg)
  return M.FFT_SIZES[cfg.fftsel] or 2048
end

-- Latency of the whole chain in samples: the STFT costs one FFT, and NLM's
-- four-hop lookahead costs a second. Matches the JSFX pdc_delay.
function M.latency(cfg)
  local n = M.fft_size(cfg)
  return (cfg.nlm > 0) and (n * 2) or n
end

-- Persistence ----------------------------------------------------------------
-- Values round-trip through ExtState as strings; the type is recovered from
-- the default, so an absent or corrupt key falls back rather than erroring.

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
  end
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  for k, default in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      local s = reaper.GetExtState(M.EXT_SECTION, k)
      if type(default) == "number" then
        cfg[k] = tonumber(s) or default
      elseif type(default) == "boolean" then
        cfg[k] = (s == "true")
      else
        cfg[k] = s
      end
    end
  end
  return cfg
end

return M
