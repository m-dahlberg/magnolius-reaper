-- @noindex
-- The panel. Laid out in the order the algorithm runs, so each section is a
-- stage: Source -> Analysis -> Spectrum -> Narrow -> Broad -> Reverb -> Output.
--
-- Only the Analysis controls cost a re-read of the audio. Everything below
-- re-derives from the cubes already in the EEL heap, which is why those
-- sliders are live and the analysis ones are behind a header.
--
-- The plots are not decoration. The spectrum with its envelope and the
-- occupancy overlay is the only way to see WHY a candidate was accepted or
-- rejected, and on real takes the answer is usually "the singer is there".

local Config      = require "dr.config"
local Select      = require "dr.select"
local Analyze     = require "dr.analyze"
local Kernel      = require "dr.kernel"
local PitchKernel = require "dr.pitch_kernel"
local Spectrum    = require "dr.spectrum"
local Mask        = require "dr.mask"
local Ring        = require "dr.ring"
local Auto        = require "dr.auto"
local Edc         = require "dr.edc"
local Gate        = require "dr.gate"
local Broad       = require "dr.broad"
local Detect      = require "dr.detect"
local Solve       = require "dr.solve"
local Render      = require "dr.render"
local Apply       = require "dr.apply"
local Timesel = require "dr.timesel"

local M = {}

local ImGui, ctx, script_dir
local cfg
local ST = {}

local COL_DIM  = 0x9098A0FF
local COL_RED  = 0xE06060FF
local COL_OK   = 0x70C070FF
local COL_LINE = 0x60A0E0FF
local COL_ENV  = 0xE0A050FF
local COL_OCC  = 0x8060C060
local COL_MARK = 0xE06060C0
local COL_THR  = 0xE0D060FF   -- the gate thresholds
local COL_PAUS = 0x60C0A0FF   -- and where the pauses actually sit

------------------------------------------------------------------ disabled
local dis_depth = 0
local function begin_disabled(v)
  ImGui.BeginDisabled(ctx, v); dis_depth = dis_depth + 1
end
local function end_disabled()
  if dis_depth > 0 then ImGui.EndDisabled(ctx); dis_depth = dis_depth - 1 end
end
-- An unbalanced BeginDisabled makes ImGui.End raise its own error over the top
-- of the real one, reporting the symptom and hiding the cause.
local function unwind_disabled()
  while dis_depth > 0 do ImGui.EndDisabled(ctx); dis_depth = dis_depth - 1 end
end
function M._disabled_depth() return dis_depth end

---------------------------------------------------------------------- jobs
local function busy() return ST.job ~= nil end

local function step_job()
  if not ST.job then return end
  local t0 = reaper.time_precise()
  while reaper.time_precise() - t0 < 0.03 do
    local ok, a, b = coroutine.resume(ST.job, ST.cancel and "cancel" or nil)
    if not ok then
      ST.job, ST.err, ST.progress = nil, tostring(a), nil
      return
    end
    if coroutine.status(ST.job) == "dead" then
      ST.job, ST.progress = nil, nil
      if ST.on_done then ST.on_done(a, b) end
      return
    end
    -- the read must happen here, on the main thread; inside the coroutine
    -- GetAudioAccessorSamples returns nil and silently reads nothing
    if Analyze.service(a) then
      if a.progress then ST.progress = a.progress end
    end
  end
end

local function start_job(kind, body, on_done)
  ST.job = coroutine.create(body)
  ST.jobkind, ST.on_done, ST.cancel, ST.err = kind, on_done, false, nil
  ST.progress = 0
end

-------------------------------------------------------------------- stages
local function ensure_kernels(geo)
  local sig = Config.kernel_sig(cfg, geo.nchan)
  if ST.ksig == sig and ST.k and ST.pk then return true end
  if ST.k then pcall(ImGui.Detach, ctx, ST.k.func) end
  if ST.pk then pcall(ImGui.Detach, ctx, ST.pk.func) end
  local pk, perr = PitchKernel.new(ImGui, ctx, script_dir, geo.nchan, cfg, cfg.pitch_rate)
  if not pk then ST.err = tostring(perr); return false end
  local k, kerr = Kernel.new(ImGui, ctx, script_dir, geo.nchan, cfg)
  if not k then ST.err = tostring(kerr); return false end
  ST.pk, ST.k, ST.ksig = pk, k, sig
  return true
end

-- Everything below the cube: percentiles, mask, ring, candidates, humps.
-- Re-runs on any DETECT_KEYS change, and costs well under a millisecond.
local function rederive()
  local k, F = ST.k, ST.F
  if not (k and F) then return end
  ST.hz   = Spectrum.hz_axis(k.half, Config.bin_hz(cfg))

  -- The per-bin floors depend on the cube alone, so they are computed once
  -- and not again for every move of the percentile slider -- the whole point
  -- of rederive() being under a millisecond.
  local fsig = tostring(cfg.skip_silence ~= false)
  if ST.floors_sig ~= fsig or not ST.floors then
    ST.floors = Spectrum.floor_bins(ST.cube, cfg.skip_silence ~= false)
    ST.floors_sig = fsig
  end

  ST.p20  = Spectrum.curve(ST.cube, cfg.percentile / 100.0, k.lev0, ST.floors)
  ST.p90  = Spectrum.curve(ST.cube, 0.90, k.lev0, ST.floors)

  -- A curve with no spread carries no information, and every detector below
  -- measures a curve against a smoothed copy of itself -- so a flat one finds
  -- nothing and, without this, says nothing. That is exactly how a file whose
  -- pauses had been stripped to dithered silence read as "no resonances".
  local lo, hi = math.huge, -math.huge
  for i = 1, #ST.p20 do
    local v = ST.p20[i]
    if v then lo = math.min(lo, v) hi = math.max(hi, v) end
  end
  ST.p20_spread = (hi > lo) and (hi - lo) or 0.0
  ST.silence_note = nil
  -- Distinct from the note: the third branch below is a SUCCESS -- silence was
  -- found and stepped over. Only the first two leave the curve resting on it,
  -- and only those two mean the ring gate cannot be trusted either.
  ST.pinned = false
  if ST.p20_spread < 5.0 then
    ST.pinned = true
    ST.silence_note = string.format(
      "The p%d curve has only %.1f dB of spread across the whole spectrum -- "
      .. "there is no statistic here to detect against. This file is mostly "
      .. "silence, or mostly below the level axis.", cfg.percentile,
      ST.p20_spread)
  elseif ST.floors and ST.floors.refused_bins > k.half * 0.05 then
    ST.pinned = true
    ST.silence_note = string.format(
      "Edited-in silence was found in %d of %d bins but not stepped over: it "
      .. "is more than half of the file there, or too little would be left. "
      .. "The curve is still resting on it.",
      ST.floors.refused_bins, k.half)
  elseif ST.floors and ST.floors.skipped_frac > 0.02 then
    ST.silence_note = string.format(
      "Stepped over edited-in silence: up to %.0f%% of the frames in a bin "
      .. "were stripped pauses, a gate, or a 16-bit master's dither, and are "
      .. "not part of the recording.", ST.floors.skipped_frac * 100)
  end
  ST.env  = Spectrum.smooth_power(ST.p20, ST.hz, 1.0 / cfg.smooth_oct)
  ST.occ, ST.nvoiced = Mask.occupancy(F, ST.hz, cfg)

  local hists = k:ring_hist(cfg)
  ST.rhz = k:ring_hz()
  ST.times = {}
  for b = 1, k.nband do
    ST.times[b] = Ring.time_from_hist(hists[b], cfg, Kernel.ring_time_of)
  end
  ST.ridx = Ring.index(ST.times, ST.rhz, cfg)
  local all = {}
  for b = 1, k.nband do if ST.times[b] then all[#all + 1] = ST.times[b] end end
  table.sort(all)
  ST.nring_bands = #all
  ST.ring_p50 = (#all > 0) and all[math.max(1, math.floor(0.5 * #all))] or nil
  if ST.ring_p50 then
    cfg._schroeder_hz = Detect.schroeder_hz(ST.ring_p50, 30.0)
  end

  local function ring_at(f)
    local b = Spectrum.index_of(ST.rhz, f)
    return b and ST.ridx[b] or nil
  end
  ST.cands = Detect.run(ST.p20, ST.hz, ST.occ, ring_at, cfg, Config.bin_hz(cfg))

  -- the broad search starts above the singer's own fundamental: otherwise the
  -- strongest hump on any take is simply where the voice lives
  local vf = {}
  for i = 1, F.n do if Mask.voiced(F, i, cfg) then vf[#vf + 1] = F.f0[i] end end
  table.sort(vf)
  ST.f0_p50 = (#vf > 0) and vf[math.floor(#vf / 2)] or nil
  ST.f0_p95 = (#vf > 0) and vf[math.max(1, math.floor(0.95 * #vf))] or nil
  ST.voiced_frac = (F.n > 0) and (#vf / F.n) or 0
  local blo = math.max(cfg.search_lo_hz, (ST.f0_p95 or 0) * 1.15)
  ST.broad_lo = blo
  ST.humps = Broad.humps(ST.p90, ST.p20, ST.hz, cfg, blo)

  -- T60 as a function of frequency: the shape comes from the measured ring
  -- times, the absolute level from the T60 control. Using the shape but not
  -- the magnitude is deliberate -- the relative figures are far more reliable
  -- than the absolute one, which is understated on a close mic.
  -- The decay cube measures T60 directly, from the pauses. Prefer it; the ring
  -- law is the fallback for takes that do not pause enough to be measured that
  -- way, which is the only reason both are kept.
  local ehists, ngaps = k:edc_hist()
  ST.edc_times, ST.edc_counts = Edc.run(ehists, cfg, Kernel.ring_time_of, k.nband)
  ST.edc_med, ST.edc_bands = Edc.median(ST.edc_times, k.nband)
  ST.edc_gaps = ngaps
  ST.auto, ST.auto_why = Auto.from_decay(ST.edc_med, ST.edc_bands, ST.pinned)
  if not ST.auto then
    ST.auto, ST.auto_why = Auto.estimate(ST.ring_p50, ST.nring_bands, ST.pinned)
  end
  -- What the gate should be set to. It needs a level the ring pass has never
  -- been asked for -- where each band sits once the voice has STOPPED -- which
  -- is the new `plev` cube, filled from the same gate the decay fits use.
  local gp, gv, gf, gn = k:gate_levels(cfg)
  local gt = {}
  for b = 1, k.nband do
    -- the measured decay per band where there is one, the calibrated ring law
    -- where there is not: the same two-estimator discipline as the dereverb
    gt[b] = ST.edc_times[b] or Auto.band_t60(ST.times[b], 1.0)
  end
  ST.gate, ST.gate_why, ST.gate_nmeas =
    Gate.suggest(gp, gv, gf, ST.rhz, gt, k.nband, ST.pinned, gn)

  local med = ST.ring_p50
  ST.t60_of = function(f)
    local trim = cfg.t60_scale / 100.0
    local b = Spectrum.index_of(ST.rhz, f)
    local t = b and ST.times[b]
    if cfg.auto_reverb and ST.auto then
      if ST.auto.measured then
        -- The decay cube gives the LEVEL, measured; the shape stays the ring
        -- times' own tilt. Per-band decay fits exist but each rests on a
        -- handful of pauses, and nothing has been measured that says a band
        -- reading long really is long -- so the level is the part that moves.
        local scale = ST.auto.t60 * trim
        if not (med and med > 0 and t) then return scale end
        return math.max(0.05, math.min(4.0, scale * (t / med)))
      end
      -- The calibrated law is monotone, so applying it band by band yields
      -- exactly the median it yields the median -- and unlike the linear tilt
      -- below it gets the SPREAD right rather than understating it by the
      -- 2.86th power.
      return Auto.band_t60(t, trim) or (ST.auto.t60 * trim)
    end
    local scale = cfg.t60 * trim
    if not (med and med > 0) then return scale end
    if not t then return scale end
    return math.max(0.05, math.min(4.0, scale * (t / med)))
  end

  -- the correction: level and target read from the cached spectrum
  local function level_at(f)
    local i = Spectrum.index_of(ST.hz, f); return i and ST.p20[i]
  end
  local function target_at(f)
    local i = Spectrum.index_of(ST.hz, f); return i and ST.env[i]
  end
  ST.plan = Solve.plan(ST.cands, ST.humps, level_at, target_at, cfg,
                       ST.geo and ST.geo.rate or 48000)
  ST.dsig = Config.detect_sig(cfg)
end

local function analyse()
  local sel = Select.resolve(cfg)
  ST.sel = sel
  if sel.err then ST.err = sel.err; return end
  local clip = sel.clips[1]
  -- Resolve the range ONCE, when the job starts, and keep it: the render and the apply must
  -- agree with the analysis even if the selection is moved while they run.
  local range, rerr = Timesel.for_item(clip.item, cfg.ignore_time_selection)
  if not range then ST.err = rerr return end
  ST.range = range

  local geo = Analyze.geometry(clip.take, range)
  ST.geo = geo
  if not ensure_kernels(geo) then return end
  ST.cache = Analyze.cache_key(clip.take, cfg)
  start_job("Analysing", Analyze.run(clip.take, cfg, ST.pk, ST.k, geo),
    function(F, err)
      if not F then ST.err = tostring(err); return end
      ST.F = F
      ST.cube = ST.k:modal_cube()
      ST.floors, ST.floors_sig = nil, nil   -- they belong to the old cube
      rederive()
    end)
end

local function run_apply()
  local sel = ST.sel
  if not (sel and sel.clips and sel.clips[1] and ST.k) then
    ST.err = "Analyse first."; return
  end
  local clip = sel.clips[1]
  local ecfg = Config.effective(cfg, ST.auto, ST.gate)
  local path = Render.output_path(clip.take, cfg, {})
  ST.applied = nil
  start_job("Rendering",
    Render.run(clip.take, ecfg, ST.k, ST.plan, ST.t60_of, path, nil, nil, ST.range),
    function(res, err)
      if not res then ST.err = tostring(err); return end
      local stamp = string.format("%s%s%s, peak %.2f",
        cfg.suppress_on and (#ST.plan .. " band(s)") or "no suppression",
        -- the EFFECTIVE figure: the trim is part of what ran, and under auto
        -- mode cfg.t60 is merely what the sliders will go back to
        cfg.dereverb_on and string.format(", dereverb T60 %.2f s%s",
          ecfg.t60 * (cfg.t60_scale / 100.0),
          cfg.auto_reverb and ST.auto and " (auto)" or "") or "",
        cfg.residual and ", RESIDUAL" or "", res.peak)
      if cfg.gate_on then
        stamp = stamp .. string.format(", %s %d%%%s", cfg.gate_mode,
          cfg.gate_amount, cfg.gate_auto and ST.gate and " (auto)" or "")
      end
      local n, aerr = Apply.run({ { item = clip.item, take = clip.take,
                                   render = res, stamp = stamp } }, cfg, ST.range)
      if not n then ST.err = tostring(aerr); return end
      ST.applied = string.format("Wrote %s%s (peak %.2f)",
        res.path:match("([^/\\]+)$"),
        cfg.residual and "  -- this is the RESIDUAL, not the corrected take" or "",
        res.peak)
      -- the render changed the item's takes; the old analysis still describes
      -- the source take, so keep it but drop the stale selection
      ST.sel = nil
    end)
end

--------------------------------------------------------------------- plots
local function plot_frame(h, id)
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, id, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, 0x1A1E24FF)
  return dl, x, y, w, h
end

-- Log frequency axis, one vertical segment per pixel column, so 1024 bins do
-- not become 1024 line calls.
local function draw_spectrum(h)
  local dl, x, y, w = plot_frame(h, "spec")
  if not ST.p20 then
    ImGui.DrawList_AddText(dl, x + 8, y + 8, COL_DIM, "no analysis yet")
    return
  end
  local hz, lo, hi = ST.hz, cfg.search_lo_hz, cfg.search_hi_hz
  local llo, lhi = math.log(lo), math.log(hi)
  local dbmin, dbmax = -120, -20
  local function ny(db)
    local t = (db - dbmin) / (dbmax - dbmin)
    return y + h - math.max(0, math.min(1, t)) * h
  end
  local col = {}
  for i = 1, #hz do
    local f = hz[i]
    if f >= lo and f <= hi then
      local px = math.floor((math.log(f) - llo) / (lhi - llo) * (w - 1))
      local c = col[px]
      if not c then c = { lo = 1e9, hi = -1e9, env = 0, occ = 0, n = 0 }; col[px] = c end
      local v = ST.p20[i]
      if v then
        if v < c.lo then c.lo = v end
        if v > c.hi then c.hi = v end
      end
      c.env = c.env + (ST.env[i] or dbmin)
      c.occ = c.occ + (ST.occ[i] or 0)
      c.n = c.n + 1
    end
  end
  for px, c in pairs(col) do
    local X = x + px
    -- occupancy first, behind everything
    if c.n > 0 and c.occ / c.n > 0.02 then
      local oh = math.min(1, c.occ / c.n) * h
      ImGui.DrawList_AddLine(dl, X, y + h - oh, X, y + h, COL_OCC, 1)
    end
    if c.hi > -1e8 then
      ImGui.DrawList_AddLine(dl, X, ny(c.lo), X, ny(c.hi), COL_LINE, 1)
    end
    if c.n > 0 then
      local e = ny(c.env / c.n)
      ImGui.DrawList_AddLine(dl, X, e, X + 1, e, COL_ENV, 1)
    end
  end
  -- The gate, drawn against the curve it has to sit between. A threshold is
  -- only meaningful relative to where the band's pauses actually are, and this
  -- is the only place both are visible at once.
  if ST.gate and cfg.gate_on then
    local thr, pau = {}, {}
    for g = 1, Gate.NBANDS do
      thr[g] = (Gate.effective_band(cfg, ST.gate, g))
      pau[g] = ST.gate[g] and ST.gate[g].pause or nil
    end
    local px = 0
    while px < w do
      local f = math.exp(llo + (px / math.max(1, w - 1)) * (lhi - llo))
      local g, X = Gate.band_of(f), x + px
      if pau[g] then
        local Y = ny(pau[g])
        ImGui.DrawList_AddLine(dl, X, Y, X + 1, Y, COL_PAUS, 1)
      end
      if thr[g] then
        local Y = ny(thr[g])
        ImGui.DrawList_AddLine(dl, X, Y, X + 1, Y, COL_THR, 1)
      end
      px = px + 1
    end
  end

  -- mark accepted candidates
  for _, cd in ipairs(ST.cands or {}) do
    if cd.accepted and cd.hz >= lo and cd.hz <= hi then
      local X = x + math.floor((math.log(cd.hz) - llo) / (lhi - llo) * (w - 1))
      ImGui.DrawList_AddLine(dl, X, y, X, y + h, COL_MARK, 1)
    end
  end
  for _, f in ipairs({ 50, 100, 200, 500, 1000, 2000 }) do
    if f >= lo and f <= hi then
      local X = x + math.floor((math.log(f) - llo) / (lhi - llo) * (w - 1))
      ImGui.DrawList_AddText(dl, X + 2, y + h - 14, COL_DIM, tostring(f))
    end
  end
end

------------------------------------------------------------------ controls
local function mark_detect()
  if ST.F then rederive() end
end
local function mark_analysis()
  ST.F, ST.cube, ST.cands, ST.humps = nil, nil, nil, nil
  ST.floors, ST.floors_sig = nil, nil
end

-- Two statements. Written as one, Lua reads the "(" after `v` as a CALL on a
-- number and every control kills the panel -- while a frame in which nothing
-- was moved renders perfectly happily.
local function changed(key, v, on_change)
  cfg[key] = v
  local fn = on_change or mark_detect
  fn()
end

-- `shown` displays a derived value instead of the config one and makes the
-- control read-only with it: auto mode must not write its own estimate into
-- the key that holds what the user set by hand, or unticking the box gives
-- back the estimate rather than their setting.
local function slider(label, key, lo, hi, fmt, on_change, shown)
  local rv, v = ImGui.SliderDouble(ctx, label, shown or cfg[key], lo, hi, fmt or "%.1f")
  if rv and not shown then changed(key, v, on_change) end
  if not shown and ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

local function islider(label, key, lo, hi, on_change)
  local rv, v = ImGui.SliderInt(ctx, label, cfg[key], lo, hi)
  if rv then changed(key, v, on_change) end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

-- `items` is ReaImGui's item list and `values` the config values it maps to,
-- in the same order -- so the key holds a readable string rather than an index
-- that means nothing in ExtState.
--
-- The list must be NUL-separated AND NUL-terminated. ReaImGui rejects the
-- \31-separated form outright ("items must be null-terminated"), and that
-- raises inside frame(), which unbalances the disabled stack, which makes
-- ImGui.End raise over the top of it -- so the panel dies with no usable
-- message. The stub cannot catch this: it has no opinion about the argument.
local function combo(label, key, items, values, on_change)
  local cur = 0
  for i = 1, #values do if cfg[key] == values[i] then cur = i - 1 end end
  local rv, v = ImGui.Combo(ctx, label, cur, items)
  if rv then changed(key, values[(v or 0) + 1] or values[1], on_change); Config.save(cfg) end
  return rv
end

local function checkbox(label, key, on_change)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then changed(key, v, on_change); Config.save(cfg) end
  return rv
end

local function dim(text) ImGui.TextColored(ctx, COL_DIM, text) end

----------------------------------------------------------------------frame
local function frame()
  step_job()

  ImGui.SeparatorText(ctx, "Source")
  local sel = ST.sel or Select.resolve(cfg)
  ImGui.Text(ctx, Select.describe(sel))
  if ST.geo then
    ImGui.SameLine(ctx)
    dim(string.format("  %.1f s, %d ch, %d Hz%s", ST.geo.item_len, ST.geo.nchan,
        ST.geo.rate, ST.geo.rate_known and "" or "  (RATE GUESSED)"))
  end

  begin_disabled(busy())
  if ImGui.Button(ctx, "Analyse", 120, 0) then analyse() end
  end_disabled()
  if busy() then
    ImGui.SameLine(ctx)
    ImGui.ProgressBar(ctx, ST.progress or 0, -1, 0,
      string.format("%s %.0f%%", ST.jobkind, 100 * (ST.progress or 0)))
    if ImGui.Button(ctx, "Cancel") then ST.cancel = true end
  end
  if ST.err then ImGui.TextColored(ctx, COL_RED, ST.err) end

  if ImGui.CollapsingHeader(ctx, "Analysis settings (these cost a re-read)") then
    dim("Modal pass reads at 4 kHz: 1.95 Hz bins over a 512 ms window --")
    dim("finer than a 16384-point FFT at 48 kHz, and far cheaper.")
    islider("hop (ms)", "hop_ms", 5, 40, mark_analysis)
    islider("min f0 (Hz)", "min_hz", 40, 200, mark_analysis)
    islider("max f0 (Hz)", "max_hz", 300, 1200, mark_analysis)
    slider("YIN threshold", "yin_threshold", 0.05, 0.40, "%.2f", mark_analysis)
  end

  -- everything below re-derives from the cubes; guard it while a job runs,
  -- because rederive would overwrite the buffers the job is filling
  begin_disabled(busy())

  ImGui.SeparatorText(ctx, "Spectrum")
  if ST.F then
    dim(string.format("%d pitch frames, %.0f%% voiced%s   %d modal frames",
      ST.F.n, 100 * (ST.voiced_frac or 0),
      ST.f0_p50 and string.format(", f0 %.0f Hz (%s)", ST.f0_p50,
        ST.f0_p50 < 175 and "low/male" or "high/female") or "",
      ST.F.modal_frames or 0))
  end
  draw_spectrum(150)
  dim("blue: level percentile   orange: 1/3-octave envelope   " ..
      "violet: how often the singer sings there   red: accepted")
  if cfg.gate_on then
    dim("yellow: gate threshold   green: where that band sits in a pause")
  end
  islider("percentile", "percentile", 5, 50)
  islider("envelope width (1/n octave)", "smooth_oct", 1, 12)
  checkbox("ignore edited-in silence", "skip_silence")
  ImGui.SameLine(ctx)
  dim(ST.p20_spread and string.format("(curve spans %.0f dB)", ST.p20_spread)
      or "(recommended)")
  if ST.silence_note then
    ImGui.TextColored(ctx, ST.p20_spread and ST.p20_spread < 5.0
                      and COL_RED or COL_ENV, ST.silence_note)
  end

  ImGui.SeparatorText(ctx, "Narrow resonances")
  slider("min prominence (dB)", "min_prominence_db", 1.0, 15.0)
  slider("min Q", "min_q", 2.0, 40.0)
  slider("max occupancy", "max_occupancy", 0.05, 1.0, "%.2f")
  dim("Q rejects formants (Q 5-10); occupancy rejects the singer's harmonics.")
  if ST.cands then
    local nacc = 0
    for _, c in ipairs(ST.cands) do if c.accepted then nacc = nacc + 1 end end
    if nacc == 0 then
      ImGui.TextColored(ctx, COL_OK, "Nothing worth cutting.")
      dim("On both reference takes this is the correct answer, not a failure.")
    end
    for i = 1, math.min(#ST.cands, 10) do
      local c = ST.cands[i]
      ImGui.TextColored(ctx, c.accepted and COL_OK or COL_DIM, "  " .. Detect.describe(c))
    end
  end

  ImGui.SeparatorText(ctx, "Broad colouration")
  slider("min hump (dB)", "min_broad_db", 1.0, 12.0)
  dim("Measured at 1/1 octave against a 2-octave baseline: a 1/3-octave")
  dim("envelope cancels a hump this wide, so the narrow detector cannot see it.")
  if ST.humps then
    if ST.broad_lo then
      dim(string.format("searching above %.0f Hz (f0 p95 is %.0f Hz)",
          ST.broad_lo, ST.f0_p95 or 0))
    end
    if #ST.humps == 0 then dim("  (none)") end
    for i = 1, math.min(#ST.humps, 5) do
      ImGui.Text(ctx, "  " .. Broad.describe(ST.humps[i]))
    end
  end

  ImGui.SeparatorText(ctx, "Reverb")
  if ST.ring_p50 then
    ImGui.Text(ctx, string.format("band ring figure: %.2f s across %d bands",
      ST.ring_p50, ST.nring_bands or 0))
    dim("This is a RELATIVE figure, not a T60. It is the fastest decay each")
    dim("band achieves, which the analysis window bounds from below -- on the")
    dim("reference takes it reads 0.14-0.18 s where the true T60 is nearer")
    dim("0.44 s. Only its SHAPE across frequency is used, to tilt T60.")
  end
  -- The decay cube: an actual T60, fitted in the pauses, which the figure
  -- above is not and cannot be turned into without a calibration.
  if ST.edc_med then
    ImGui.TextColored(ctx, COL_OK, string.format(
      "measured T60: %.2f s across %d bands, from %d pauses",
      ST.edc_med, ST.edc_bands or 0, ST.edc_gaps or 0))
    dim("Fitted where the voice STOPS, so the singer is out of the statistic.")
    dim("Good to about 7% against combs of known decay -- read this one as a T60.")
  elseif ST.edc_gaps then
    ImGui.TextColored(ctx, COL_DIM, string.format(
      "measured T60: not enough pauses (%d found); using the ring law instead",
      ST.edc_gaps))
  end
  checkbox("set T60 and reduction from the analysis", "auto_reverb")
  local auto_on = cfg.auto_reverb and ST.auto ~= nil
  if cfg.auto_reverb then
    if ST.auto and ST.auto.dry then
      ImGui.TextColored(ctx, COL_OK, string.format(
        "  dry: ring %.3f s is at the measurement floor", ST.auto.ring))
      dim("Nothing here decays slowly enough to measure, so T60 goes to the")
      dim("bottom of its range and the dereverb does almost nothing. That is")
      dim("the right answer for this material, not a failure to measure it.")
    elseif ST.auto and ST.auto.measured then
      ImGui.TextColored(ctx, COL_OK, string.format(
        "  T60 %.2f s, reduction %.0f dB, measured in the pauses",
        ST.auto.t60, ST.auto.reduction))
      dim("Taken straight from the decay cube -- no calibration in between, and")
      dim("no safety factor, because there is no proxy bias left to absorb.")
    elseif ST.auto then
      ImGui.TextColored(ctx, COL_OK, string.format(
        "  T60 %.2f s, reduction %.0f dB, from a ring figure of %.3f s",
        ST.auto.t60, ST.auto.reduction, ST.auto.ring))
      dim(string.format("T60 = %.1f x ring^%.2f, then x%.2f because the error is asymmetric:",
        Auto.RING_A, Auto.RING_B, Auto.SAFETY))
      dim("too low only means the dereverb does less, too high eats the voice.")
      dim("The ring law is the FALLBACK: this take has too few pauses to fit a")
      dim("decay in. Good to about 27% over 0.15-1.6 s. Listen before trusting it.")
      if ST.auto.clamped then
        ImGui.TextColored(ctx, COL_RED, string.format(
          "  the law gave %.2f s, outside the slider range, and it was clamped",
          ST.auto.raw))
      end
    else
      ImGui.TextColored(ctx, COL_RED,
        "  no estimate: " .. (ST.auto_why or "analyse first"))
      dim("The hand-set values below are being used instead.")
    end
  end
  begin_disabled(auto_on)
  slider("T60 (s)", "t60", 0.10, 2.00, "%.2f", nil, auto_on and ST.auto.t60 or nil)
  end_disabled()
  islider("T60 scale (%)", "t60_scale", 25, 300)
  dim("The scale stays live under auto: the analysis sets the level, you trim it.")
  checkbox("reduce reverb", "dereverb_on")
  begin_disabled(auto_on)
  slider("reduction (dB)", "reduction", 0.0, 24.0, nil, nil,
         auto_on and ST.auto.reduction or nil)
  end_disabled()
  islider("strength (%)", "strength", 0, 100)
  islider("lookback (frames)", "delay_frames", 1, 32)
  if cfg.delay_frames * (cfg.rfft_size / 4) <= cfg.rfft_size then
    ImGui.TextColored(ctx, COL_RED,
      "  Lookback is shorter than the analysis window: this will thin the")
    ImGui.TextColored(ctx, COL_RED,
      "  signal without removing reverb. Raise it above " ..
      math.ceil(cfg.rfft_size / (cfg.rfft_size / 4)) .. ".")
  end
  dim("Late reverb is estimated as a decayed copy of what each bin held a few")
  dim("frames ago, then subtracted -- so it works under the notes too, not just")
  dim("in the gaps. At 0 dB reduction the render is transparent.")

  ImGui.SeparatorText(ctx, "Gate")
  dim("The other half of the reverb problem. The stage above works under the")
  dim("singing but reduces to 0.4 dB on material that never stops; a gate can")
  dim("only act where the level FALLS, which is the exposed pause. Neither")
  dim("replaces the other, which is why both are here.")
  checkbox("gate reverb tails", "gate_on")
  combo("filter", "gate_domain", "spectral\0filterbank\0",
        { "spectral", "filterbank" })
  if cfg.gate_domain == "filterbank" then
    dim("Linkwitz-Riley crossovers in the time domain, after the stage above.")
    dim("Sample-accurate and zero latency, with no pre-echo before an onset --")
    dim("but it rotates phase even while inert, so the RESIDUAL RENDER IS NOT")
    dim("A CLEAN NULL in this mode, and the crossover regions move when")
    dim("neighbouring bands gate differently.")
  else
    dim("Band gains inside the same STFT the stage above uses. Phase is")
    dim("untouched, so the residual stays a clean diagnostic and no crossover")
    dim("can interfere -- at the cost of a window of latency, a 43 ms decision")
    dim("grain, and a little room leaking in just before each onset.")
  end
  combo("mode", "gate_mode", "expander\0gate\0", { "expander", "gate" })
  begin_disabled(cfg.gate_mode == "gate")
  slider("ratio", "gate_ratio", 1.0, 20.0, "%.1f")
  end_disabled()
  if cfg.gate_mode == "gate" then
    dim("A gate is the ratio -> infinity limit of the same law, with hysteresis.")
  end
  islider("amount (%)", "gate_amount", 0, 100)
  dim("Amount scales DEPTH only. Thresholds do not move with it, so turning it")
  dim("up gates harder and never sooner -- it cannot start taking the voice.")
  slider("threshold offset (dB)", "gate_offset_db", -24.0, 24.0)
  islider("release scale (%)", "gate_release", 25, 300)

  checkbox("set thresholds from the analysis", "gate_auto")
  if cfg.gate_auto then
    if ST.gate then
      ImGui.TextColored(ctx, COL_OK, string.format(
        "  %d of %d bands measured; release from each band's own T60",
        ST.gate_nmeas or 0, Gate.NBANDS))
      dim("Each threshold is set 12 dB under that band's own working level --")
      dim("the same figure the decay cube uses to mean the voice has stopped.")
      dim("The pause levels below are what REFUSE a band: if its pauses do not")
      dim("separate from its voice there is no threshold that can sit between")
      dim("them, and they also bound how far down the band may be taken.")
    elseif ST.F then
      ImGui.TextColored(ctx, COL_RED,
        "  no suggestion: " .. (ST.gate_why or "analyse first"))
      dim("The hand-set thresholds below are being used instead.")
    end
  end

  local auto_g = cfg.gate_auto and ST.gate ~= nil
  for g = 1, Gate.NBANDS do
    local e = ST.gate and ST.gate[g]
    local show = (auto_g and e and e.thr) or nil
    begin_disabled(show ~= nil)
    slider(Gate.band_label(g), "gate_thr" .. g, -120.0, -20.0, "%.1f", nil, show)
    end_disabled()
    if e and e.measured then
      local _, rng, rel = Gate.effective_band(cfg, ST.gate, g)
      dim(string.format(
        "    pause %.0f  voice %.0f  floor %.0f dB   T60 %.2f s   "
        .. "release %.0f ms   depth %.0f dB",
        e.pause, e.voice, e.floor, e.t60 or 0, rel * 1000, rng))
    elseif e then
      ImGui.TextColored(ctx, COL_DIM, "    " .. (e.why or ""))
    end
  end
  if ST.gate then
    dim(string.format(
      "Bands above %.0f Hz are not measured: the ring pass reads at %d Hz over",
      cfg.search_hi_hz, cfg.pitch_rate))
    dim("the search range, so there is no pause level up there to set one from.")
    dim("They are left to the ear rather than extrapolated -- sibilance and")
    dim("breath live in that region, and gating those is the loudest way to")
    dim("spoil a vocal.")
  end
  dim("No band is pulled below its own measured noise floor: a pause gated to")
  dim("silence sounds like the recording stopping, where stopping at the floor")
  dim("sounds like the room.")

  ImGui.SeparatorText(ctx, "Correction")
  checkbox("suppress resonances", "suppress_on")
  slider("max cut (dB)", "max_cut_db", 1.0, 24.0)
  slider("Q scale", "q_scale", 0.25, 3.0, "%.2f")
  if ST.plan then
    if #ST.plan == 0 then
      dim("  nothing to correct")
    elseif not cfg.suppress_on then
      dim(string.format("  %d filter(s) found but suppression is off", #ST.plan))
    else
      for _, f in ipairs(ST.plan) do
        ImGui.Text(ctx, "  " .. Solve.describe(f))
      end
      dim("Gains are solved against the real filter response, not set to the")
      dim("measured prominence -- overlapping cuts would otherwise double up.")
    end
  end

  ImGui.SeparatorText(ctx, "Range")
  do
    local it, ierr = Timesel.selected_item(cfg.ignore_time_selection)
    if not it and ierr then ImGui.Text(ctx, ierr) end
    if it then
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      local r, rerr = Timesel.for_item(it, cfg.ignore_time_selection)
      if r then
        ImGui.Text(ctx, Timesel.describe(r, pos, len))
        if r.from_selection and not r.whole then
          ImGui.Text(ctx, "The item is split at the edges; the rest keeps its original take.")
        end
      else
        ImGui.Text(ctx, rerr)
      end
    end
  end
  checkbox("Ignore time selection", "ignore_time_selection")


  ImGui.SeparatorText(ctx, "Output")
  checkbox("render the residual (what was removed)", "residual")
  dim("The dry signal, delayed to match the chain, minus the output. With")
  dim("both stages off the residual is digital silence, which is the check")
  dim("that it is aligned. Listen for voice in it: that is what you are losing.")
  checkbox("write a new take", "new_take")
  checkbox("select the new take", "select_take")
  end_disabled()

  begin_disabled(busy() or not ST.plan)
  if ImGui.Button(ctx, "Render and apply", 160, 0) then run_apply() end
  end_disabled()
  if ST.applied then ImGui.TextColored(ctx, COL_OK, ST.applied) end

  ImGui.Dummy(ctx, 1, 6)
  if ImGui.SmallButton(ctx, "Reset all settings") then
    Config.reset(cfg); mark_analysis()
  end
end

------------------------------------------------------------- test hooks
M._frame = frame
function M._cfg() return cfg end
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.new()
  ctx = imgui.CreateContext("DeResonate (test)")
  dis_depth = 0
  ST = {}
  return ST, cfg
end

function M.start(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.load()
  ctx = ImGui.CreateContext("DeResonate")
  ST = {}
  local function loop()
    ImGui.SetNextWindowSize(ctx, 640, 900, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "DeResonate", true)
    if visible then
      -- pcall INSIDE Begin/End: End must be called whenever Begin was visible
      local ok, err = pcall(frame)
      if not ok then
        unwind_disabled()          -- before reporting, or End raises over it
        ST.err = tostring(err)
        ImGui.TextColored(ctx, COL_RED, ST.err)
      end
      ImGui.End(ctx)
    end
    if open then reaper.defer(loop) end
  end
  reaper.defer(loop)
end

return M
