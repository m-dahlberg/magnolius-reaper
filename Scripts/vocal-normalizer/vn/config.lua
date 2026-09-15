-- @noindex
-- Vocal Normalizer -- parameter defaults, persistence and parameter classes.
--
-- Pure Lua apart from the load/save helpers, which are guarded, so the
-- measurement stages can be exercised headlessly.
--
-- The parameter classes at the bottom are what make the panel responsive.
-- Only ANALYSIS_KEYS change which samples get read or how they are filtered;
-- the gate, the target and the limits all re-derive from a block table that is
-- already in memory, so dragging the target slider re-prices every selected
-- item without touching the audio again.

local M = {}

M.EXT_SECTION = "vocal_normalizer"

M.defaults = {
  -- The measurement band ------------------------------------------------------
  -- The whole point of the script. Ordinary LUFS is K-weighted: a +4 dB shelf
  -- above ~1.5 kHz on top of a measurement that already counts every joule in
  -- the signal. A bright, close, sibilant vocal therefore MEASURES several dB
  -- hotter than a soft one carrying the same melody at the same perceived
  -- level, and gets normalised down by the difference. Restricting the
  -- measurement to the range the melody's fundamentals occupy removes both
  -- halves of that: the shelf is outside the band, and so is the sibilance.
  --
  -- 100..1000 Hz is the default because it spans the sung fundamental range
  -- of essentially every voice -- G2 (98 Hz) at the bottom of a bass, C6
  -- (1047 Hz) at the top of a soprano -- while excluding both the rumble,
  -- proximity boom and handling noise below it and the consonants, breath and
  -- air above it. Narrow it toward the singer's actual register when you know
  -- it; the presets are a starting point.
  band_lo_hz = 100,
  band_hi_hz = 1000,
  -- Poles per side. 4 is 24 dB/octave, which puts a 5 kHz sibilant 57 dB down
  -- and a 40 Hz rumble 36 dB down -- far enough that neither can move the
  -- answer. 2 (12 dB/oct) leaves audible skirts; 8 (48 dB/oct) is available
  -- for a deliberately narrow band around one singer's range.
  band_order = 4,
  -- K-weighting INSIDE the band. Off by default and it does almost nothing
  -- when on, because the K shelf turns over at 1.5 kHz and the band ends at 1:
  -- the option exists so that opening the band wide and switching this on
  -- reproduces ordinary LUFS exactly, which is both a useful A/B in the panel
  -- and how the whole chain is checked against REAPER's own analysis.
  kweight = false,

  -- Gating and integration ----------------------------------------------------
  -- BS.1770's block grid: 400 ms blocks overlapping by 75%. The overlap is
  -- fixed at 4x (see loudness.lua) because it is what makes the gate behave
  -- the way the standard's does; the block length is open because a vocal
  -- chopped into short phrases wants a shorter one.
  block_ms = 400,
  -- Absolute gate: blocks quieter than this are not part of the programme at
  -- all. -70 is the standard's, and it stays -70 here even though a
  -- band-limited block reads lower than a full-band one, because its job is to
  -- exclude digital silence and it is nowhere near anything else.
  gate_abs_lu = -70,
  -- Relative gate, below the ungated mean. -10 is the standard's. Tighten it
  -- toward -6 to judge a take by its loud syllables only; loosen it toward
  -- -20 to let quiet phrases count.
  gate_rel_lu = -10,
  -- How the surviving blocks become one number.
  --   "gated"      BS.1770's: the mean of the gated blocks' mean squares.
  --   "percentile" the Nth percentile of the absolutely-gated blocks' levels,
  --                which ignores the relative gate entirely. More robust on a
  --                take with one very loud line in it, because a percentile
  --                cannot be dragged by an outlier the way a mean can.
  reduce = "gated",
  percentile = 75,

  -- The target ----------------------------------------------------------------
  -- In the band's own scale, NOT in LUFS. A band-limited measurement discards
  -- energy, so it reads lower than the same take's LUFS -- typically 6..12 dB
  -- lower on a vocal, but by an amount that depends on the voice, which is
  -- exactly the bias being removed and so cannot be calibrated away with a
  -- constant. Set this from a vocal you are happy with: analyse it and press
  -- "Target from this take".
  target_db = -26,
  -- Caps on the move, against the take's own level. Separate per direction
  -- because they are not equally forgiving: pulling a loud take down is safe,
  -- pushing a quiet one up lifts its noise floor and its spill with it.
  max_boost_db = 12,
  max_cut_db = 12,
  -- Headroom. The gain is applied as take or item volume, so nothing clips
  -- inside REAPER's float mixer -- but a vocal boosted to within a hair of
  -- full scale hits the first plugin in the chain with no room to work. The
  -- ceiling is checked against the take's SAMPLE peak; -1.0 dB leaves roughly
  -- the usual margin for inter-sample peaks on top of that.
  limit_peak = true,
  peak_ceiling_db = -1.0,

  -- Scope and output ----------------------------------------------------------
  -- Off: every selected item is measured and normalised on its own -- the
  -- right thing for comparing takes or for a row of one-item-per-song clips.
  -- On: all the selected items are measured as ONE programme and get ONE
  -- common gain, which is what a comped lead vocal split across forty items
  -- wants, since normalising each phrase separately would flatten the
  -- performance.
  link_items = false,
  -- "take" writes take volume, "item" writes item volume. Take volume is the
  -- default because it is per-take, so an A/B against another take of the same
  -- item keeps its own gain.
  apply_to = "take",
  -- Stamp what was done onto the item, readable later in the project file.
  write_note = true,
}

-- Band presets. Not config keys -- they only set band_lo_hz and band_hi_hz --
-- so they carry no persistence and belong to no parameter class.
M.PRESETS = {
  { name = "Male lead",    lo = 80,  hi = 700 },
  { name = "Female lead",  lo = 140, hi = 1100 },
  { name = "Vocal (wide)", lo = 100, hi = 1000 },
  { name = "Body only",    lo = 150, hi = 500 },
  { name = "Full band",    lo = 20,  hi = 20000 },
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- In place, because the panel holds one cfg table as an upvalue and hands it
-- to the kernel and to the measurement stage -- swapping the table would leave
-- those pointing at the old one.
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

-- Parameter classes -----------------------------------------------------------
--
-- ANALYSIS changes which samples are read or what they are filtered through,
-- so it throws away the block cache. MEASURE reduces a cached block table to
-- one number. GAIN turns that number into a move. OUTPUT changes only what
-- gets written. Everything below ANALYSIS is free: the panel re-prices every
-- selected item, redraws the plots and updates the table without an accessor.

M.ANALYSIS_KEYS = { "band_lo_hz", "band_hi_hz", "band_order", "kweight",
                    "block_ms" }
M.MEASURE_KEYS  = { "gate_abs_lu", "gate_rel_lu", "reduce", "percentile" }
M.GAIN_KEYS     = { "target_db", "max_boost_db", "max_cut_db",
                    "limit_peak", "peak_ceiling_db", "link_items" }
M.OUTPUT_KEYS   = { "apply_to", "write_note" }

local function signature(cfg, keys)
  local t = {}
  for i, k in ipairs(keys) do t[i] = tostring(cfg[k]) end
  return table.concat(t, "|")
end

function M.analysis_sig(cfg) return signature(cfg, M.ANALYSIS_KEYS) end
function M.measure_sig(cfg)  return signature(cfg, M.MEASURE_KEYS)  end
function M.gain_sig(cfg)     return signature(cfg, M.GAIN_KEYS)     end

-- The kernel's memory map is fixed by the channel count and the number of
-- biquad sections in the band chain, and its coefficients by the source rate,
-- so a change in any of those means building a new kernel rather than
-- reconfiguring the one in hand.
function M.kernel_sig(cfg, nchan, rate)
  return table.concat({ nchan, rate, cfg.band_lo_hz, cfg.band_hi_hz,
                        cfg.band_order, tostring(cfg.kweight) }, "|")
end

-- Persistence -----------------------------------------------------------------
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
