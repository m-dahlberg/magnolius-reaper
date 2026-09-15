-- @noindex
-- Defaults, persistence and derived geometry.
--
-- The one fact that shapes this file: a change to `ANALYSIS_KEYS` is the only
-- thing that changes which samples get read. Everything else re-derives from
-- the statistic cube already in memory, in well under a millisecond, which is
-- what lets the panel's sliders be live. That split is expressed once here, as
-- parameter classes, and asserted in `test/headless.lua`.
--
-- Pure Lua apart from the ExtState edges, which are guarded, so the whole file
-- loads headlessly.

local M = {}

M.EXT_SECTION = "deresonate"
M.VERSION     = 1

M.defaults = {
  -- Analysis -- these cost a re-read of the audio ------------------------
  modal_rate     = 4000,   -- accessor rate for the spectral pass. Reading low
                           -- is *better*: 2048 bins at 4 kHz give 1.95 Hz
                           -- spacing, finer than a 16384-point FFT at 48 kHz
                           -- and eight times cheaper. REAPER does the
                           -- anti-aliased decimation in the accessor.
  fft_size       = 2048,   -- 512 ms window at modal_rate
  ana_hop        = 256,    -- 64 ms
  ring_fft       = 512,    -- short window for the ring test, at pitch_rate
  ring_hop       = 64,     -- 8 ms -- must resolve a ~0.3 s decay
  hop_ms         = 10,     -- pitch/level frame grid
  pitch_rate     = 8000,   -- YIN costs window x tau_max; 8 kHz still resolves
                           -- 600 Hz to about +-10 cents
  min_hz         = 70,
  max_hz         = 600,
  yin_threshold  = 0.15,
  voice_gate_db  = -50,

  -- Narrow-resonance detection -------------------------------------------
  -- Edited-in silence is stepped over before any percentile is taken. It is
  -- not a frame of the recording, and a file with more of it than the
  -- percentile being asked for pins EVERY bin to the bottom of the level
  -- axis -- a flat curve, and a detector that finds nothing and says nothing.
  -- See dr/spectrum.lua's `floor_bin`. Off is for diagnosis only.
  skip_silence      = true,
  percentile        = 20,    -- a harmonic occupies a bin in ~20% of frames and
                             -- vanishes from p20; a mode is in nearly every
                             -- frame and survives
  smooth_oct        = 3,     -- 1/3 octave envelope the prominence is measured against
  min_prominence_db = 4.0,
  min_topo_db       = 2.5,
  min_q             = 8.0,   -- the primary false-positive guard: a mode at
                             -- T60 0.4 s is 5.5 Hz wide (Q~18 at 100 Hz); a
                             -- vowel formant is 50-150 Hz wide (Q 5-10)
  max_occupancy     = 0.35,
  mask_cents        = 70,
  search_lo_hz      = 30,
  search_hi_hz      = 1900,
  max_bands         = 8,

  -- Ring test -- a resonance is defined by ringing, not by level ----------
  -- The decay cube's gate: how far under the take's own running level counts
  -- as a pause. The T60 fit is conditioned on the voice having stopped, and
  -- this is what "stopped" means.
  edc_gate_db     = 12.0,
  edc_min_gaps    = 6,     -- fits per band below which the median is not a
                           -- statistic; the ring law is used instead
  ring_win_ms     = 50,    -- slope window
  ring_pct        = 5,     -- percentile of the slope distribution
  ring_head_db    = 12,    -- how far above the band floor a frame must sit
  ring_span_oct   = 1.0,   -- neighbourhood the index is relative to
  min_ring_index  = 1.25,   -- diagnostic threshold only; does NOT gate a
                            -- candidate. See the header of dr/detect.lua.

  -- Broad colouration ----------------------------------------------------
  broad_oct       = 1.0,   -- measurement scale
  broad_base_oct  = 2.0,   -- baseline scale
  min_broad_db    = 2.5,
  broad_q         = 1.0,   -- a broad hump wants a wide bell, not a notch

  -- Correction -----------------------------------------------------------
  suppress_on        = true,   -- apply the peaking cascade at all
  max_cut_db         = 12.0,
  max_q              = 60.0,   -- a measured Q runs to three figures on a
                               -- near-sinusoidal line; a biquad that narrow
                               -- rings audibly, so cap what is built
  q_scale            = 1.0,
  target_headroom_db = 0.0,

  -- Reverb (M4) ----------------------------------------------------------
  dereverb_on   = false,
  rfft_size     = 2048,
  strength      = 100,
  reduction     = 12.0,
  smoothing     = 50,
  delay_frames  = 12,      -- THE parameter that decides whether this works at
                           -- all. The late estimate is |X(n-D)|^2 decayed, so
                           -- D*hop must be comfortably LONGER than the analysis
                           -- window or the two frames overlap and the signal is
                           -- subtracted from a near-copy of itself. Measured:
                           -- at D=2 (21 ms, window 43 ms) the fixture lost
                           -- 7.6 dB of voice and 0.1 dB of reverb -- pure
                           -- thinning. At D=12 (128 ms) it loses 0.3 dB of
                           -- voice and 5.0 dB of reverb.
  -- With `auto_reverb` on, T60 and reduction come from the ring measurement
  -- through the calibrated law in `dr/auto.lua` and these two hold whatever
  -- the user last set by hand, ready for when it is switched off. The scale
  -- stays live either way: the analysis sets the level, the ear trims it.
  auto_reverb   = true,
  t60           = 0.40,    -- the by-ear default, and what auto mode returns to
  t60_scale     = 100,

  -- Multiband gate/expander (M5) ------------------------------------------
  -- The complement to the dereverb rather than a second helping of it. The
  -- spectral stage reduces to `snr = 60*tau/T60` on stationary material and so
  -- does essentially nothing under a held note; a gate can only work where the
  -- level falls, which is the exposed pause the spectral stage is weakest in.
  -- Runs as a band gain inside the SAME STFT -- see `dr/gate.lua`.
  gate_on        = false,
  -- "spectral" runs it as a band gain inside the dereverb's STFT; "filterbank"
  -- as a Linkwitz-Riley tree in the time domain, after it. Same thresholds,
  -- same law, different trade -- see the header of dr/gate.lua.
  gate_domain    = "spectral",
  gate_mode      = "expander",  -- or "gate": the ratio -> infinity limit
  gate_ratio     = 3.0,
  gate_amount    = 60,     -- % of RANGE_MAX, clamped per band by what the
                           -- measurement says is there to remove
  gate_offset_db = 0.0,    -- shifts all eight thresholds at once
  gate_release   = 100,    -- % trim on the derived release; stays live under
                           -- auto, exactly as t60_scale does
  gate_auto      = true,
  -- Eight numbered scalars rather than an array: ExtState persists scalars and
  -- recovers each key's type from its default, and the panel coverage scan in
  -- test/headless.lua greps for `control("label", "key")` pairs. An array
  -- would defeat both.
  gate_thr1 = -60.0,
  gate_thr2 = -62.0,
  gate_thr3 = -64.0,
  gate_thr4 = -66.0,
  gate_thr5 = -68.0,
  gate_thr6 = -70.0,
  gate_thr7 = -72.0,
  gate_thr8 = -74.0,

  -- Output ---------------------------------------------------------------
  residual    = false,   -- render what was REMOVED instead of what is kept:
                         -- the dry signal, delayed to match the chain, minus
                         -- the processed output. The fastest way to hear
                         -- whether a correction is taking the right thing.
  new_take    = true,
  select_take = true,
}

-- Parameter classes. Only ANALYSIS_KEYS change which samples would be read.
M.ANALYSIS_KEYS = { "modal_rate", "fft_size", "ana_hop", "ring_fft", "ring_hop",
                    "hop_ms", "pitch_rate", "min_hz", "max_hz", "yin_threshold",
                    "edc_gate_db" }
M.DETECT_KEYS   = { "skip_silence",
                    "percentile", "smooth_oct", "min_prominence_db", "min_topo_db",
                    "min_q", "max_occupancy", "mask_cents", "search_lo_hz",
                    "search_hi_hz", "max_bands", "voice_gate_db",
                    "ring_win_ms", "ring_pct", "ring_head_db", "ring_span_oct",
                    "edc_min_gaps",
                    "min_ring_index", "broad_oct", "broad_base_oct",
                    "min_broad_db", "broad_q" }
M.SOLVE_KEYS    = { "suppress_on", "max_cut_db", "max_q", "q_scale",
                    "target_headroom_db" }
M.REVERB_KEYS   = { "dereverb_on", "rfft_size", "strength", "reduction",
                    "smoothing", "delay_frames", "t60", "t60_scale",
                    "auto_reverb" }
M.GATE_KEYS     = { "gate_on", "gate_domain", "gate_mode", "gate_ratio", "gate_amount",
                    "gate_offset_db", "gate_release", "gate_auto",
                    "gate_thr1", "gate_thr2", "gate_thr3", "gate_thr4",
                    "gate_thr5", "gate_thr6", "gate_thr7", "gate_thr8" }
M.OUTPUT_KEYS   = { "residual", "new_take", "select_take" }

local function signature(cfg, keys)
  local t = {}
  for i = 1, #keys do t[i] = tostring(cfg[keys[i]]) end
  return table.concat(t, "|")
end

function M.analysis_sig(cfg) return signature(cfg, M.ANALYSIS_KEYS) end
function M.detect_sig(cfg)   return signature(cfg, M.DETECT_KEYS)   end
function M.solve_sig(cfg)    return signature(cfg, M.SOLVE_KEYS)    end
function M.reverb_sig(cfg)   return signature(cfg, M.REVERB_KEYS)   end
function M.gate_sig(cfg)     return signature(cfg, M.GATE_KEYS)     end
function M.output_sig(cfg)   return signature(cfg, M.OUTPUT_KEYS)   end

-- Channel count and the two FFT sizes are baked into the kernel's memory map,
-- so a change to any of them means a new kernel, not a reconfigure.
function M.kernel_sig(cfg, nchan)
  return table.concat({ nchan, cfg.fft_size, cfg.ring_fft, cfg.modal_rate,
                        cfg.pitch_rate }, "|")
end

-- Derived geometry, defined once so the kernel, the pure stages and the panel
-- cannot disagree about it.
function M.nbins(cfg)   return cfg.fft_size / 2 end
function M.bin_hz(cfg)  return cfg.modal_rate / cfg.fft_size end
function M.window_ms(cfg) return 1000.0 * cfg.fft_size / cfg.modal_rate end
function M.ring_bin_hz(cfg) return cfg.pitch_rate / cfg.ring_fft end
function M.ring_dt(cfg) return cfg.ring_hop / cfg.pitch_rate end

-- Latency of the render chain. The peaking biquads are transposed direct form
-- II and add none; only the dereverb STFT does. `render.lua` compensates by
-- pushing this many extra samples through and dropping them from the head, so
-- this figure must match the kernel exactly or the whole take slides.
-- The config the render actually runs with. `cfg` always means what the user
-- set; when auto mode has an estimate, this is the only thing that overrides
-- it. Returning a copy rather than writing into cfg is what lets the checkbox
-- be unticked and give the hand-set values straight back.
function M.effective(cfg, auto, gate)
  local want_auto = cfg.auto_reverb and auto
  -- The gate's suggestion rides the same way and for the same reason: the
  -- per-band thresholds the render uses are derived, and `gate_thr1..8` must
  -- keep holding whatever the user last set by hand.
  local want_gate = cfg.gate_on and gate
  if not (want_auto or want_gate) then return cfg end
  local c = {}
  for k, v in pairs(cfg) do c[k] = v end
  if want_auto then
    c.t60 = auto.t60
    c.reduction = auto.reduction
  end
  if want_gate then c._gate = gate end
  return c
end

-- The STFT is shared: the dereverb's per-bin gain and the SPECTRAL gate's band
-- gain are two factors on the same frame, so either alone still costs exactly
-- one window. The FILTERBANK gate adds none -- it is IIR, in the time domain,
-- after the STFT -- so with it selected and the dereverb off the chain is
-- zero-latency again. Off by one against the kernel and the whole take slides.
function M.spectral_gate(cfg)
  return cfg.gate_on and cfg.gate_domain ~= "filterbank"
end

function M.latency(cfg)
  return (cfg.dereverb_on or M.spectral_gate(cfg)) and cfg.rfft_size or 0
end

function M.new()
  local c = {}
  for k, v in pairs(M.defaults) do c[k] = v end
  return c
end

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
  end
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  for k, d in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      local s = reaper.GetExtState(M.EXT_SECTION, k)
      -- type is recovered from the default, so a corrupt key falls back
      -- rather than erroring
      if type(d) == "number" then      cfg[k] = tonumber(s) or d
      elseif type(d) == "boolean" then cfg[k] = (s == "true")
      else                             cfg[k] = s end
    end
  end
  return cfg
end

-- In place: the panel holds one cfg as an upvalue and hands it to the kernel,
-- the detector and the render.
function M.reset(cfg)
  for k in pairs(cfg) do
    if M.defaults[k] == nil then
      cfg[k] = nil
      if reaper then reaper.DeleteExtState(M.EXT_SECTION, k, true) end
    end
  end
  for k, v in pairs(M.defaults) do cfg[k] = v end
  M.save(cfg)
  return cfg
end

return M
