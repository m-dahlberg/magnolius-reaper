-- @noindex
-- AutoTilt -- ReaImGui panel.
--
-- Laid out in the order the algorithm runs: resolve the selection, analyse,
-- place the pivot, read the balance off both clips, solve, render.
--
-- The plot is the reason the cube exists. A single number cannot say WHY the
-- two clips differ -- whether it is a proximity bump under 200 Hz, a dull mic
-- above 4 k, or a genuine broad tilt that one gain figure can actually fix.
-- Two normalised spectra with the pivot drawn on them answer that at a glance,
-- and they redraw as the pivot moves because nothing here re-reads audio.
--
-- Which controls cost what:
--   Analysis (FFT size, hop, target track)  -- another Analyse
--   everything else                          -- redraw only

local Config   = require "at.config"
local Select   = require "at.select"
local Kernel   = require "at.kernel"
local Analyze  = require "at.analyze"
local Spectrum = require "at.spectrum"
local Solve    = require "at.solve"
local Render   = require "at.render"
local Apply    = require "at.apply"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  sel = nil, sel_desc = "", geo = nil, k = nil, ksig = nil,
  ana = nil, cache_key = nil,
  msig = nil, ssig = nil, mt = nil, mr = nil,
  curve_t = nil, curve_r = nil,
  ref_ratio = nil, ref_from = nil,
  solved = nil, clamped = false, solve_err = nil,
  manual = nil,                 -- a dragged gain; nil means "use the solved one"
  job = nil, jobkind = nil, progress = 0, cancel = false,
  apply_after = false,
  status = "Select a reference clip and a target clip, then Analyse.",
  err = nil, note = nil,
}

local COL_BG    = 0x14181CFF
local COL_REF   = 0x50C878FF   -- reference
local COL_TGT   = 0x4A7FB5FF   -- target, as measured
local COL_AFTER = 0xE0A050FF   -- target after the solved tilt
local COL_PIVOT = 0xE0E0E0AA
local COL_AXIS  = 0x40484EFF
local COL_GRID  = 0x2A3138FF
local COL_GREY  = 0x808080FF
local COL_RED   = 0xE05050FF
local COL_WARN  = 0xE0A050FF

--------------------------------------------------------------------------- job

local function step_job()
  if not ST.job then return end
  local t0 = reaper.time_precise()
  while reaper.time_precise() - t0 < 0.03 do
    local send = ST.cancel and "cancel" or nil
    local ok, a, b = coroutine.resume(ST.job, send)
    if not ok then
      ST.err, ST.job, ST.status = tostring(a), nil, "Failed."
      return
    end
    if coroutine.status(ST.job) == "dead" then
      local done = ST.on_done
      ST.job, ST.on_done, ST.cancel = nil, nil, false
      if done then done(a, b) end
      return
    end
    -- A job cannot read its own audio from inside a coroutine (see
    -- analyze.lua); it yields a request and we do the read here, on the main
    -- thread, so the next resume finds the block waiting for it.
    if Analyze.service(a) then
      ST.progress = a.progress or ST.progress
    else
      ST.progress = tonumber(a) or 0
    end
  end
end

local function start_job(kind, body, on_done)
  ST.job = coroutine.create(body)
  ST.jobkind, ST.progress, ST.cancel, ST.err = kind, 0, false, nil
  ST.on_done = on_done
end

local function busy() return ST.job ~= nil end

------------------------------------------------------------ the disabled stack
-- BeginDisabled/EndDisabled through a counted pair, so that an error thrown
-- mid-frame cannot leave the stack unbalanced. Unbalanced, ImGui.End raises
-- its own error over the top of the real one and the panel dies reporting the
-- symptom while hiding the cause.

local dis_depth = 0

local function begin_disabled(cond)
  ImGui.BeginDisabled(ctx, cond)
  dis_depth = dis_depth + 1
end

local function end_disabled()
  if dis_depth < 1 then return end
  ImGui.EndDisabled(ctx)
  dis_depth = dis_depth - 1
end

local function unwind_disabled()
  while dis_depth > 0 do end_disabled() end
end

----------------------------------------------------------------------- stages

local function gain_now()
  if ST.manual then return ST.manual end
  return ST.solved
end

-- Everything downstream of the cube. Cheap enough to run on every frame, which
-- is the whole point of caching the spectrum rather than the audio: nothing
-- here re-reads a sample. Guarded by the two signatures so a still frame costs
-- two string compares.
local function recompute()
  if not ST.ana or not ST.k then return end
  local rate, fft = ST.ana.geo.rate, ST.k.fft_size

  local msig = Config.measure_sig(cfg)
  if msig ~= ST.msig then
    ST.msig, ST.ssig = msig, nil
    ST.mt = Spectrum.measure(ST.ana.target, cfg, rate, fft)
    ST.mr = ST.ana.ref and Spectrum.measure(ST.ana.ref, cfg, rate, fft) or nil
    ST.curve_t = (ST.mt and ST.mt.spec)
      and Spectrum.octave_curve(ST.mt.spec, ST.mt.band, 6) or nil
    ST.curve_r = (ST.mr and ST.mr.spec)
      and Spectrum.octave_curve(ST.mr.spec, ST.mr.band, 6) or nil
  end

  local ssig = Config.solve_sig(cfg)
  if ssig ~= ST.ssig then
    ST.ssig = ssig
    ST.solved, ST.clamped, ST.solve_err = nil, false, nil

    if ST.mr and ST.mr.ratio then
      ST.ref_ratio, ST.ref_from = ST.mr.ratio, "clip"
    elseif cfg.use_fixed_ref then
      ST.ref_ratio, ST.ref_from = cfg.fixed_ref_ratio, "fixed"
    else
      ST.ref_ratio, ST.ref_from = nil, nil
    end

    if ST.ref_ratio and ST.mt and ST.mt.ratio then
      local r = Solve.solve(ST.mt.spec, cfg, rate, ST.mt.band, ST.ref_ratio)
      ST.solved, ST.clamped, ST.solve_err = r.gain, r.clamped, r.err
    end
  end
end

-- The kernel's memory map is fixed by the channel count and the FFT size, so a
-- change in either means building a new one -- and, since those are analysis
-- parameters, a re-read.
local function ensure_kernel(geo)
  local sig = Config.kernel_sig(cfg, geo.nchan)
  if ST.k and ST.ksig == sig then
    ST.k:set_hop(Config.hop(cfg))
    return ST.k
  end
  if ST.k then pcall(ImGui.Detach, ctx, ST.k.func) end
  ST.k, ST.ksig, ST.ana, ST.msig = nil, nil, nil, nil
  local k, err = Kernel.build(ImGui, ctx, script_dir, geo.nchan, cfg)
  if not k then return nil, err end
  k:set_hop(Config.hop(cfg))
  ST.k, ST.ksig = k, sig
  return k
end

local run_apply   -- forward declaration: analyse can chain into it

local function analyse(then_apply)
  local sel = Select.resolve(cfg)
  ST.sel, ST.err = sel, nil
  if sel.err then ST.status = sel.err return end
  if #sel.refs == 0 and not cfg.use_fixed_ref then
    ST.status = "No reference clip, and the fixed ratio is off."
    return
  end

  -- The first target clip fixes the rate, the channel count and the kernel;
  -- every clip on both sides is then read at those. See analyze.lua.
  local geo = Analyze.geometry(sel.target[1].take)
  ST.geo = geo
  local k, kerr = ensure_kernel(geo)
  if not k then ST.err = kerr ST.status = "Failed." return end

  local key = Analyze.cache_key(sel, cfg)
  if ST.ana and key == ST.cache_key then
    ST.status = string.format("%d ch at %d Hz  (cached)", geo.nchan, geo.rate)
    recompute()
    if then_apply then run_apply() end
    return
  end

  ST.status = "Analysing..."
  ST.apply_after = then_apply and true or false
  start_job("Analysing", function() return Analyze.run(sel, cfg, k, geo) end,
    function(res, err)
      if not res then
        ST.status = (err == "cancelled") and "Cancelled." or "Analysis failed."
        if err ~= "cancelled" then ST.err = err end
        ST.apply_after = false
        return
      end
      ST.ana, ST.cache_key, ST.msig = res, key, nil
      ST.manual = nil
      local rate_note = geo.rate_known and "" or "  (rate guessed)"
      ST.status = string.format("%d ch at %d Hz, %d + %d frames%s",
        geo.nchan, geo.rate,
        res.target.frames, res.ref and res.ref.frames or 0, rate_note)
      recompute()
      if ST.apply_after then
        ST.apply_after = false
        run_apply()
      end
    end)
end

function run_apply()
  if not ST.ana or not ST.mt or not ST.mt.spec then
    ST.status = "Nothing analysed yet."
    return
  end
  local gain = gain_now()
  if not gain then
    ST.status = ST.solve_err or "No reference to match against."
    return
  end

  -- Names are claimed for every clip before anything is written, so a target
  -- row sharing one source file cannot have each render overwrite the last,
  -- and a collision fails before the first sample goes to disk.
  local sel, k = ST.sel, ST.k
  local claimed, jobs = {}, {}
  for i, e in ipairs(sel.target) do
    local path = Render.output_path(e.take, cfg, claimed)
    if not path then ST.err = "Could not find a free output filename." return end
    jobs[i] = { item = e.item, take = e.take, path = path }
  end

  local ana_rate, fft = ST.ana.geo.rate, k.fft_size
  local spec = ST.mt.spec
  ST.status, ST.note = "Rendering...", nil
  start_job("Rendering", function()
    local out = {}
    for i, j in ipairs(jobs) do
      -- The file is written at the take's own source rate, which need not be
      -- the rate analysis read at -- so the shelves are designed there.
      local rgeo = Analyze.geometry(j.take)
      local plan = Solve.plan(spec, cfg, ana_rate, gain, fft, rgeo.rate)
      local res, err = Render.run(j.take, cfg, k, plan, j.path,
                                  (i - 1) / #jobs, i / #jobs)
      if not res then return nil, err end
      out[i] = { item = j.item, take = j.take, result = res, peak = res.peak }
    end
    return out
  end, function(res, err)
    if not res then
      ST.status = (err == "cancelled") and "Cancelled." or "Render failed."
      if err ~= "cancelled" then ST.err = err end
      return
    end
    local added, aerr = Apply.run(res, cfg, gain)
    if not added then ST.err = aerr ST.status = "Apply failed." return end
    local peak = 0
    for _, r in ipairs(res) do peak = math.max(peak, r.peak or 0) end
    ST.status = string.format("Applied %+.2f dB to %d take%s  (peak %.1f dBFS)",
      gain, added, added == 1 and "" or "s",
      20 * math.log(math.max(peak, 1e-9), 10))
    ST.note = peak > 1.0 and
      "Peak is over 0 dBFS. The file is float, so nothing clipped." or nil
  end)
end

local function reset_settings()
  Config.reset(cfg)
  ST.msig, ST.ssig, ST.manual = nil, nil, nil
  ST.err, ST.note = nil, nil
end

------------------------------------------------------------------------ draw

local function plot_frame(w, h, id)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, id, w, h)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, COL_BG, 4)
  return dl, x, y
end

-- Each curve is drawn relative to its own mean, because the question the plot
-- answers is about SHAPE. Two takes at different levels would otherwise sit
-- one above the other and say nothing about their tone.
local function normalise(curve)
  if not curve or #curve == 0 then return nil end
  local s = 0
  for _, p in ipairs(curve) do s = s + p.db end
  local mean = s / #curve
  local out = {}
  for i, p in ipairs(curve) do out[i] = { hz = p.hz, db = p.db - mean } end
  return out
end

local GRID_HZ = { 100, 200, 500, 1000, 2000, 5000, 10000 }

local function draw_balance(w, h)
  local dl, x, y = plot_frame(w, h, "##balance")
  local b = ST.mt and ST.mt.band
  if not b or b.degenerate then return end

  local u0, u1 = math.log(b.lo_edge), math.log(b.hi_edge)
  local function fx(hz)
    return x + (math.log(hz) - u0) / (u1 - u0) * w
  end

  local ct, cr = normalise(ST.curve_t), normalise(ST.curve_r)

  -- One shared vertical range over everything drawn, so the two clips stay
  -- comparable and the tilt curve is read against the same scale.
  local lo, hi = -1, 1
  for _, c in ipairs({ ct, cr }) do
    if c then
      for _, p in ipairs(c) do
        if p.db < lo then lo = p.db end
        if p.db > hi then hi = p.db end
      end
    end
  end
  lo, hi = lo - 2, hi + 2
  local function fy(db) return y + h - (db - lo) / (hi - lo) * h end

  for _, hz in ipairs(GRID_HZ) do
    if hz > b.lo_edge and hz < b.hi_edge then
      local px = fx(hz)
      ImGui.DrawList_AddLine(dl, px, y, px, y + h, COL_GRID)
    end
  end
  if 0 > lo and 0 < hi then
    ImGui.DrawList_AddLine(dl, x, fy(0), x + w, fy(0), COL_AXIS)
  end

  local function poly(c, col, thick)
    if not c or #c < 2 then return end
    for i = 2, #c do
      ImGui.DrawList_AddLine(dl, fx(c[i - 1].hz), fy(c[i - 1].db),
                                 fx(c[i].hz), fy(c[i].db), col, thick or 1)
    end
  end

  poly(cr, COL_REF, 2)
  poly(ct, COL_TGT, 2)

  -- What the target would look like after the tilt about to be applied. This
  -- is the honest check on the whole idea: if the orange lands on the green,
  -- one number was enough; if it does not, the difference was never a tilt.
  local g = gain_now()
  if g and ct then
    local rate = ST.ana.geo.rate
    local lof, hif = Solve.pair(cfg, rate, g)
    local after, s = {}, 0
    for i, p in ipairs(ct) do
      local d = 10 * math.log(
        math.max(Solve.pair_response_sq(lof, hif, p.hz, rate), 1e-30), 10)
      after[i] = { hz = p.hz, db = p.db + d }
      s = s + after[i].db
    end
    local mean = s / #after
    for _, p in ipairs(after) do p.db = p.db - mean end
    poly(after, COL_AFTER, 2)
  end

  local px = fx(cfg.pivot_hz)
  ImGui.DrawList_AddLine(dl, px, y, px, y + h, COL_PIVOT, 2)
  ImGui.DrawList_AddText(dl, math.min(px + 4, x + w - 60), y + 4, COL_PIVOT,
    string.format("%.0f Hz", cfg.pivot_hz))
end

--------------------------------------------------------------------- controls

-- The changed-callback is bound to a local before being called. Writing
--     cfg[key] = v (on_change or noop)()
-- reads like two statements and is not: Lua treats a `(` following an
-- expression as a call, so that line calls `v` -- a number.
local function changed(key, v, on_change)
  cfg[key] = v
  if on_change then on_change() end
end

local function slider(label, key, lo, hi, fmt, on_change)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, fmt or "%.1f")
  if rv then changed(key, v, on_change) end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

-- Frequencies want a log scale: half the useful travel is under 1 kHz.
local function hz_slider(label, key, lo, hi, on_change)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, "%.0f Hz",
                                   ImGui.SliderFlags_Logarithmic)
  if rv then changed(key, v, on_change) end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

local function islider(label, key, lo, hi, on_change)
  local rv, v = ImGui.SliderInt(ctx, label, math.floor(cfg[key]), lo, hi)
  if rv then changed(key, v, on_change) end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

local function checkbox(label, key, on_change)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then changed(key, v, on_change) Config.save(cfg) end
  return rv
end

local function input_double(label, key, fmt)
  local rv, v = ImGui.InputDouble(ctx, label, cfg[key], 0.1, 1.0, fmt or "%.2f")
  if rv then changed(key, v) Config.save(cfg) end
  return rv
end

local function input_int(label, key, lo)
  local rv, v = ImGui.InputInt(ctx, label, math.floor(cfg[key]), 1, 1)
  if rv then
    cfg[key] = math.max(lo or 0, math.floor(v))
    Config.save(cfg)
  end
  return rv
end

-- An analysis parameter: changing it invalidates the cube, so say so rather
-- than letting the next Analyse quietly cost a re-read.
local function stale_analysis()
  ST.ana, ST.cache_key, ST.msig = nil, nil, nil
end

local function fmt_db(v)
  if not v then return "--" end
  return string.format("%+.2f dB", v)
end

------------------------------------------------------------------------ frame

local function frame()
  step_job()
  recompute()

  -- The selection is re-read every frame so the panel says what it WOULD do,
  -- not what it did the last time a button was pressed.
  if not busy() then
    local sel = Select.resolve(cfg)
    ST.sel_desc = Select.describe(sel, cfg)
  end

  ImGui.SeparatorText(ctx, "Source")
  begin_disabled(busy())
  if ImGui.Button(ctx, "Analyse", 110, 0) then analyse(false) end
  end_disabled()
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(ctx, ST.sel_desc)
  ImGui.TextColored(ctx, COL_GREY, ST.status)

  if busy() then
    ImGui.ProgressBar(ctx, ST.progress, -1, 0,
      string.format("%s  %.0f%%", ST.jobkind, ST.progress * 100))
    if ImGui.Button(ctx, "Cancel", 100, 0) then ST.cancel = true end
  end
  if ST.err then ImGui.TextColored(ctx, COL_RED, ST.err) end

  ImGui.SeparatorText(ctx, "Pivot and band")
  hz_slider("Pivot", "pivot_hz", 100, 8000)
  hz_slider("Band low", "band_lo_hz", 20, 500)
  hz_slider("Band high", "band_hi_hz", 4000, 20000)
  ImGui.TextColored(ctx, COL_GREY,
    "The band the balance is measured over. It does not limit the tilt.")

  ImGui.SeparatorText(ctx, "Balance")
  local function report(name, m, col)
    if not m then
      ImGui.TextColored(ctx, COL_GREY, name .. "   --")
      return
    end
    if m.err then
      ImGui.TextColored(ctx, COL_WARN, name .. "   " .. m.err)
      return
    end
    ImGui.TextColored(ctx, col, string.format(
      "%-11s %+7.2f dB      %d of %d frames above %.0f dBFS",
      name, m.ratio, m.kept, m.total, m.gate_db_abs))
  end
  report("reference", ST.mr, COL_REF)
  if not ST.mr and ST.ref_from == "fixed" and ST.ana then
    ImGui.TextColored(ctx, COL_REF, string.format(
      "%-11s %+7.2f dB      fixed", "reference", cfg.fixed_ref_ratio))
  end
  report("target", ST.mt, COL_TGT)
  if ST.ref_ratio and ST.mt and ST.mt.ratio then
    ImGui.Text(ctx, string.format("%-11s %+7.2f dB",
      "difference", ST.ref_ratio - ST.mt.ratio))
  end

  local avail = ImGui.GetContentRegionAvail(ctx)
  draw_balance(math.max(avail, 120), 190)
  ImGui.TextColored(ctx, COL_GREY,
    "reference / target / target after the tilt -- each normalised to its own mean")

  ImGui.SeparatorText(ctx, "Reference")
  checkbox("Use a fixed ratio when nothing is selected to measure against",
           "use_fixed_ref")
  begin_disabled(not cfg.use_fixed_ref)
  ImGui.SetNextItemWidth(ctx, 140)
  input_double("Fixed ratio (dB)", "fixed_ref_ratio")
  ImGui.SameLine(ctx)
  begin_disabled(not (ST.mr and ST.mr.ratio))
  if ImGui.Button(ctx, "Capture from reference", 190, 0) then
    cfg.fixed_ref_ratio = ST.mr.ratio
    Config.save(cfg)
  end
  end_disabled()
  end_disabled()

  ImGui.SeparatorText(ctx, "Tilt")
  local g = gain_now()
  local lim = math.abs(cfg.max_gain)
  local rv, v = ImGui.SliderDouble(ctx, "Gain", g or 0, -lim, lim, "%+.2f dB")
  if rv then ST.manual = v end
  if ST.manual then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "reset to solved") then ST.manual = nil end
  end
  if ST.clamped then
    ImGui.TextColored(ctx, COL_WARN, string.format(
      "The match wants more than %+.0f dB. Clamped -- raise the limit, or the " ..
      "difference is not a tilt.", lim))
  end
  if ST.solve_err then ImGui.TextColored(ctx, COL_WARN, ST.solve_err) end
  slider("Shelf slope", "shelf_slope", 0.3, 1.0, "%.2f")
  slider("Gain limit", "max_gain", 3, 24, "%.0f dB")
  checkbox("Compensate level", "compensate_level")

  ImGui.SeparatorText(ctx, "Gate")
  slider("Gate depth", "gate_db", 6, 60, "%.0f dB below loud")
  slider("Loud percentile", "gate_pct", 50, 100, "%.0f%%")

  if ImGui.CollapsingHeader(ctx, "Analysis (re-reads the audio)") then
    islider("FFT size", "fft_size", 1024, 8192, stale_analysis)
    islider("Hop", "ana_hop", 256, 4096, stale_analysis)
    input_int("Target track (0 = highest selected)", "target_track", 0)
    ImGui.TextColored(ctx, COL_GREY,
      "Changing these throws the cached spectrum away.")
  end

  ImGui.SeparatorText(ctx, "Output")
  checkbox("Add as a new take", "new_take")
  ImGui.SameLine(ctx)
  checkbox("Select it", "select_take")

  begin_disabled(busy())
  if ImGui.Button(ctx, "Apply", 110, 0) then
    if ST.ana then run_apply() else analyse(true) end
  end
  end_disabled()
  ImGui.SameLine(ctx)
  if not ST.ana then
    ImGui.TextColored(ctx, COL_GREY, "Apply will analyse first.")
  else
    ImGui.Text(ctx, string.format("tilt %s at %.0f Hz", fmt_db(g), cfg.pivot_hz))
  end
  if ST.note then ImGui.TextColored(ctx, COL_WARN, ST.note) end

  ImGui.Separator(ctx)
  if ImGui.SmallButton(ctx, "Reset all settings") then reset_settings() end
end

------------------------------------------------------------------ test hooks
-- Wire the panel up without starting the defer loop, so a suite can render one
-- frame against a stub ImGui. The panel needs a real context and a defer loop
-- to run for real, but every way it has broken has been a Lua error inside
-- frame(), and those raise against a stub just as well.

M._frame = frame

function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.new()
  ctx = imgui.CreateContext("AutoTilt (test)")
  dis_depth = 0
  return ST, cfg
end

function M._disabled_depth() return dis_depth end
function M._cfg() return cfg end

--------------------------------------------------------------------------- run

function M.start(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.load()
  ctx = ImGui.CreateContext("AutoTilt")

  local function loop()
    ImGui.SetNextWindowSize(ctx, 620, 860, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "AutoTilt", true)
    if visible then
      local ok, err = pcall(frame)
      if not ok then
        -- Unwind before reporting, or ImGui.End raises its own error over the
        -- top of this one and the panel dies instead of showing what happened.
        unwind_disabled()
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
