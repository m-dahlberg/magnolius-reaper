-- @noindex
-- Vocal Normalizer -- ReaImGui panel.
--
-- Two columns: the controls on the left in the order the algorithm runs, and
-- the displays on the right. The displays are the reason the panel exists.
-- A normalizer that only printed a gain would be a menu item; what makes this
-- one usable is being able to see WHERE the measurement came from -- which
-- blocks the gate kept, how far the band measurement sits from the take's
-- LUFS, and what the band is actually passing.
--
-- Three displays, each answering a question a number cannot:
--
--   * the block plot -- did the gate keep the singing and drop the breaths, or
--     is half the measurement room tone?
--   * the band plot -- what is being measured, drawn against the K-weighting
--     curve it replaces, so the +4 dB shelf being excluded is visible rather
--     than asserted;
--   * the clip table -- band level against LUFS against peak, per clip, which
--     is where a bright take and a dark one at the same LUFS visibly separate.
--
-- Only the controls under "Band" and the block length force another Analyse.
-- Everything else re-prices every selected clip from frames already in memory,
-- so the gate, the target and the limits move at frame rate. The panel says
-- which is which rather than leaving it to be discovered.

local Config   = require "vn.config"
local Biquad   = require "vn.biquad"
local Kernel   = require "vn.kernel"
local Analyze  = require "vn.analyze"
local Loudness = require "vn.loudness"
local Plan     = require "vn.plan"
local Apply    = require "vn.apply"
local Select   = require "vn.select"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  kernels = {},          -- kernel_sig -> kernel; one per distinct rate/channels
  clips = nil,           -- analysed { item, take, name, geo, F }
  analysed_key = nil,    -- the cache key the analysis in hand was made under
  rows = nil, summary = nil, priced = nil,
  clip_idx = 1,
  job = nil, jobkind = nil, progress = 0, cancel = false, on_done = nil,
  status = "Select one or more audio items and press Analyse.",
  err = nil,
  show_controls = true, ctrl_w = 380,
  hover_t = nil,
}

local COL_BG      = 0x14181CFF
local COL_GRID    = 0x2A3036FF
local COL_AXIS    = 0x40484EFF
local COL_GREY    = 0x808080FF
local COL_RED     = 0xE05050FF
local COL_AMBER   = 0xE0A050FF
local COL_GATED   = 0x50C878FF   -- blocks the gate kept
local COL_ABS     = 0x4A7FB5FF   -- above the absolute gate, below the relative
local COL_OUT     = 0x3A4248FF   -- below the absolute gate
local COL_VALUE   = 0xF0E080FF   -- the integrated result
local COL_TARGET  = 0xE0A050FF
local COL_RELGATE = 0x7FA8D0AA
local COL_BAND    = 0x50C878FF
local COL_K       = 0xB06090FF
local COL_CURSOR  = 0xC0C8D0AA

-- Balancing the ImGui stack across an error ----------------------------------
--
-- A frame that throws between BeginChild and EndChild leaves ImGui's stack
-- unbalanced, which ReaImGui raises on at the next End -- OUTSIDE any pcall
-- around the frame body. In REAPER that is a modal dialog and a main thread
-- that stops answering, including to other scripts. So every pair that can
-- straddle a failure is counted and unwound in _frame.
local depth = { child = 0, disabled = 0, table_ = 0 }

-- An optional ImGui symbol has to be ASKED for, not assumed: the ReaImGui shim
-- raises on an unknown field rather than returning nil, so `ImGui.A or ImGui.B`
-- never gets a chance to run.
local function opt(name)
  local ok, v = pcall(function() return ImGui[name] end)
  if ok then return v end
  return nil
end

local CHILD_BORDER = 0
local TABLE_FLAGS  = 0

local function begin_child(id, w, h, flags)
  ImGui.BeginChild(ctx, id, w, h, flags)
  depth.child = depth.child + 1
end

local function end_child()
  if depth.child > 0 then
    depth.child = depth.child - 1
    ImGui.EndChild(ctx)
  end
end

local function begin_disabled(cond)
  ImGui.BeginDisabled(ctx, cond)
  depth.disabled = depth.disabled + 1
end

local function end_disabled()
  if depth.disabled > 0 then
    depth.disabled = depth.disabled - 1
    ImGui.EndDisabled(ctx)
  end
end

--------------------------------------------------------------------------- job

local function step_job()
  if not ST.job then return end
  local t0 = reaper.time_precise()
  while reaper.time_precise() - t0 < 0.03 do
    local ok, a, b = coroutine.resume(ST.job, ST.cancel and "cancel" or nil)
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
    -- analyze.lua); it yields a request and the read happens here, on the main
    -- thread, so the next resume finds the block waiting for it.
    if Analyze.service(a) then
      ST.progress = a.progress or ST.progress
    else
      ST.progress = tonumber(a) or ST.progress
    end
  end
end

local function start_job(kind, body, on_done)
  ST.job = coroutine.create(body)
  ST.jobkind, ST.progress, ST.cancel = kind, 0, false
  ST.err = nil
  ST.on_done = on_done
end

local function busy() return ST.job ~= nil end

------------------------------------------------------------------------ stages

-- One kernel per distinct memory map. Selecting eight clips off one track
-- builds one; selecting a 44.1 kHz mono clip next to a 48 kHz stereo one
-- builds two, because the coefficients and the interleave differ.
local function drop_kernels()
  for _, k in pairs(ST.kernels) do Kernel.detach(ImGui, ctx, k) end
  ST.kernels = {}
end

local function ensure_kernel(nchan, rate)
  -- A band change means every cached kernel is stale, not just the one for
  -- this clip's format. Dropping them here rather than letting them
  -- accumulate is what keeps a slider sweep from compiling a kernel per
  -- position and attaching all of them to the context.
  local asig = Config.analysis_sig(cfg)
  if ST.kernel_asig ~= asig then
    drop_kernels()
    ST.kernel_asig = asig
  end
  local sig = Config.kernel_sig(cfg, nchan, rate)
  local k = ST.kernels[sig]
  if k then return k end
  local new, err = Kernel.new(ImGui, ctx, script_dir, nchan, cfg, rate)
  if not new then return nil, err end
  ST.kernels[sig] = new
  return new
end

-- What the analysis in hand was made under. Rebuilt every frame rather than
-- flagged, so moving an item, changing its length or re-selecting always
-- shows as stale without anything having to remember to say so.
local function selection_key(sel)
  local parts = {}
  for i, c in ipairs(sel.clips) do
    parts[i] = Analyze.cache_key(c.take, cfg)
  end
  return table.concat(parts, "\n")
end

local function priced_sig()
  return Config.measure_sig(cfg) .. "|" .. Config.gain_sig(cfg)
end

local function nclips() return ST.clips and #ST.clips or 0 end

local function clip_index()
  return math.max(1, math.min(ST.clip_idx, math.max(nclips(), 1)))
end

local function current_row()
  return ST.rows and ST.rows[clip_index()] or nil
end

-- The cheap half: everything below the band and the block length re-derives
-- from frames already in memory. This runs whenever its signature moves, which
-- in practice is every frame a slider is being dragged.
local function recompute()
  if not ST.clips then return end
  ST.rows, ST.summary = Plan.run(ST.clips, cfg)
  ST.priced = priced_sig()
end

-- `after` runs once the reads land, on the main thread. It is how Apply works
-- without an Analyse first: it asks for the analysis and writes from inside
-- its completion.
local function analyse(sel, after)
  local key = selection_key(sel)

  -- Geometry and the kernels are resolved on the main thread, before the job
  -- starts. Only the reads and the Executes go inside the coroutine.
  local clips = {}
  for i, c in ipairs(sel.clips) do
    local geo = Analyze.geometry(c.take)
    local k, err = ensure_kernel(geo.nchan, geo.rate)
    if not k then ST.err, ST.status = err, "Failed." return end
    clips[i] = { item = c.item, take = c.take, name = c.name, geo = geo, k = k }
  end

  ST.status = "Analysing..."
  start_job("Analysing", function()
    local n = #clips
    for i, c in ipairs(clips) do
      local F, err = Analyze.run(c.take, cfg, c.k, c.geo, (i - 1) / n, i / n)
      if not F then return nil, err end
      c.F, c.k = F, nil
    end
    return clips
  end, function(out, jerr)
    if not out then
      ST.status = (jerr == "cancelled") and "Cancelled." or "Failed."
      if jerr ~= "cancelled" then ST.err = jerr end
      return
    end
    ST.clips, ST.analysed_key = out, key
    ST.clip_idx = 1
    recompute()
    ST.status = Plan.describe(ST.rows, ST.summary, cfg)
    if after then after() end
  end)
end

-- Run `after` against a current analysis, reading first only if what is in
-- hand is not for this selection under these band settings.
local function with_analysis(after)
  local sel = Select.resolve()
  if sel.err then ST.status = sel.err return end
  if ST.clips and ST.analysed_key == selection_key(sel) then
    if ST.priced ~= priced_sig() then recompute() end
    after()
    return
  end
  analyse(sel, after)
end

local function apply()
  with_analysis(function()
    if not ST.rows or #ST.rows == 0 then ST.status = "Nothing to write." return end
    local n, skipped, err = Apply.run(ST.rows, cfg)
    if err then ST.err = err end
    ST.status = string.format("Wrote %s volume on %d clip%s.%s",
      cfg.apply_to, n, n == 1 and "" or "s",
      skipped > 0 and string.format("  %d skipped.", skipped) or "")
    -- The clips now put out a different level, so what is on screen describes
    -- the take as it was a moment ago. Re-price against the volumes just
    -- written, which is what makes the gain column read 0.00 afterwards --
    -- the visible proof that the pass landed where it said it would.
    for _, c in ipairs(ST.clips) do c.geo = Analyze.geometry(c.take) end
    recompute()
  end)
end

local function reset_volume()
  local sel = Select.resolve()
  if sel.err then ST.status = sel.err return end
  local rows = {}
  for i, c in ipairs(sel.clips) do rows[i] = { item = c.item, take = c.take } end
  local n = Apply.reset(rows, cfg)
  ST.status = string.format("Reset %s volume to unity on %d clip%s.",
                            cfg.apply_to, n, n == 1 and "" or "s")
  if ST.clips then
    for _, c in ipairs(ST.clips) do c.geo = Analyze.geometry(c.take) end
    recompute()
  end
end

------------------------------------------------------------------- controls

-- SeparatorText arrived after 0.9's earliest builds, and an absent ImGui
-- symbol RAISES rather than reading as nil, so it is asked for in _init and
-- the plain pair stands in when it is not there.
local HAVE_SEPTEXT = false

local function section(title)
  ImGui.Dummy(ctx, 1, 4)
  if HAVE_SEPTEXT then
    ImGui.SeparatorText(ctx, title)
  else
    ImGui.Separator(ctx)
    ImGui.TextColored(ctx, COL_GREY, title)
  end
end

local function slider(label, key, lo, hi, fmt)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, fmt or "%.1f")
  if rv then cfg[key] = v end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

local function checkbox(label, key)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then cfg[key] = v Config.save(cfg) end
  return rv
end

-- `values` is the list the combo picks from; `labels` is what it shows.
local function combo(label, key, values, labels)
  local cur = 0
  for i, v in ipairs(values) do if cfg[key] == v then cur = i - 1 end end
  local rv, sel = ImGui.Combo(ctx, label, cur,
                              table.concat(labels, "\0") .. "\0")
  if rv then cfg[key] = values[sel + 1] Config.save(cfg) end
  return rv
end

local function help(text)
  ImGui.TextColored(ctx, COL_GREY, text)
end

local function controls()
  section("Band  -- changing these needs another Analyse")
  slider("Low  Hz##lo", "band_lo_hz", 20, 500, "%.0f")
  slider("High Hz##hi", "band_hi_hz", 300, 20000, "%.0f")
  combo("Slope", "band_order", { 2, 4, 6, 8 },
        { "12 dB/oct", "24 dB/oct", "36 dB/oct", "48 dB/oct" })
  checkbox("K-weight inside the band", "kweight")
  help("On + a full band = ordinary LUFS. That is the A/B.")
  for i, p in ipairs(Config.PRESETS) do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.SmallButton(ctx, p.name) then
      cfg.band_lo_hz, cfg.band_hi_hz = p.lo, p.hi
      Config.save(cfg)
    end
  end
  slider("Block ms", "block_ms", 100, 1000, "%.0f")
  help("BS.1770 uses 400. Shorten it for a take chopped into short phrases.")

  section("Gate")
  slider("Absolute gate", "gate_abs_lu", -90, -40, "%.0f dB")
  slider("Relative gate", "gate_rel_lu", -30, -3, "%.0f LU")
  combo("Reduce by", "reduce", { "gated", "percentile" },
        { "BS.1770 gated mean", "percentile" })
  if cfg.reduce == "percentile" then
    slider("Percentile", "percentile", 50, 99, "%.0f")
    help("Over the absolutely-gated blocks; the relative gate is not used.")
  end

  section("Target")
  slider("Target", "target_db", -50, -6, "%.1f dB")
  local r = current_row()
  begin_disabled(not (r and r.band))
  if ImGui.Button(ctx, "Target from this clip") then
    cfg.target_db = r.band.db
    Config.save(cfg)
  end
  end_disabled()
  ImGui.SameLine(ctx)
  help("Sets the target to what this clip already measures.")
  slider("Max boost", "max_boost_db", 0, 30, "%.1f dB")
  slider("Max cut", "max_cut_db", 0, 30, "%.1f dB")
  checkbox("Keep the peak under a ceiling", "limit_peak")
  if cfg.limit_peak then
    slider("Ceiling", "peak_ceiling_db", -12, 0, "%.1f dB")
    help("Against the SAMPLE peak. -1.0 leaves room for inter-sample peaks.")
  end

  section("Output")
  checkbox("All selected clips as one programme", "link_items")
  help(cfg.link_items
       and "One gain for everything, so the performance keeps its dynamics."
       or  "Each clip normalised on its own.")
  combo("Write to", "apply_to", { "take", "item" },
        { "take volume", "item volume" })
  checkbox("Note what was done on the item", "write_note")

  ImGui.Dummy(ctx, 1, 6)
  if ImGui.Button(ctx, "Reset volume to unity") then reset_volume() end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reset settings") then Config.reset(cfg) drop_kernels() end
end

----------------------------------------------------------------------- plots

local function plot(id, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, id, w, math.max(h, 1))
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, COL_BG, 4)
  return dl, x, y, ImGui.IsItemHovered(ctx)
end

-- The block plot. One vertical bar per gating block, at 100 ms resolution by
-- default, coloured by what the gate did with it -- which is the one thing a
-- single loudness number cannot tell you and the thing that decides whether
-- the number is any good.
local function block_plot(w, h)
  local r = current_row()
  local dl, x, y, hovered = plot("##blocks", w, h)
  if not (r and r.blocks and #r.blocks > 0) then
    ImGui.DrawList_AddText(dl, x + 8, y + 8, COL_GREY,
      r and (r.err or "nothing measurable here") or "nothing analysed")
    return
  end

  local span = (r.F and r.F.span) or r.blocks[#r.blocks].t1
  if span <= 0 then return end

  local top = math.max(r.band and r.band.db or -20, cfg.target_db) + 4
  local bot = top - 48
  local function py(v)
    return y + h - (math.max(bot, math.min(top, v)) - bot) / (top - bot) * h
  end
  local function px(t) return x + t / span * w end

  for db = math.ceil(bot / 6) * 6, top, 6 do
    local gy = py(db)
    ImGui.DrawList_AddLine(dl, x + 30, gy, x + w, gy, COL_GRID, 1)
    ImGui.DrawList_AddText(dl, x + 3, gy - 7, COL_GREY, string.format("%.0f", db))
  end

  local step = span > 120 and 30 or (span > 60 and 10 or (span > 20 and 5 or 1))
  local t = step
  while t < span do
    ImGui.DrawList_AddLine(dl, px(t), y, px(t), y + h, COL_GRID, 1)
    ImGui.DrawList_AddText(dl, px(t) + 3, y + h - 15, COL_GREY,
      string.format("%.0fs", t))
    t = t + step
  end

  local bw = math.max(1, w / math.max(#r.blocks, 1))
  for _, b in ipairs(r.blocks) do
    local cx = px((b.t0 + b.t1) / 2)
    local col = b.gated and COL_GATED or (b.abs and COL_ABS or COL_OUT)
    ImGui.DrawList_AddLine(dl, cx, y + h, cx, py(b.db), col, math.min(bw, 3))
  end

  if r.band then
    ImGui.DrawList_AddLine(dl, x + 30, py(r.band.rel_gate_db),
                           x + w, py(r.band.rel_gate_db), COL_RELGATE, 1)
    ImGui.DrawList_AddLine(dl, x + 30, py(r.band.db),
                           x + w, py(r.band.db), COL_VALUE, 2)
  end
  ImGui.DrawList_AddLine(dl, x + 30, py(cfg.target_db),
                         x + w, py(cfg.target_db), COL_TARGET, 1)

  if hovered then
    local mx = ImGui.GetMousePos(ctx)
    ST.hover_t = math.max(0, math.min(span, (mx - x) / w * span))
  end
  if ST.hover_t and ST.hover_t <= span then
    ImGui.DrawList_AddLine(dl, px(ST.hover_t), y, px(ST.hover_t), y + h,
                           COL_CURSOR, 1)
  end

  ImGui.DrawList_AddText(dl, x + 34, y + 3, COL_GATED, "in the measurement")
  ImGui.DrawList_AddText(dl, x + 160, y + 3, COL_ABS, "gated out")
  ImGui.DrawList_AddText(dl, x + 240, y + 3, COL_VALUE, "result")
  ImGui.DrawList_AddText(dl, x + 300, y + 3, COL_TARGET, "target")
end

-- The band plot: what is being measured, drawn over the K-weighting curve it
-- replaces. The whole argument for this script is visible here -- K rises
-- 4 dB across exactly the region the band excludes, which is why a sibilant
-- take measures hotter than it sounds.
local function band_plot(w, h)
  local dl, x, y = plot("##band", w, h)
  local rate = 48000
  local r = current_row()
  if r and r.F and r.F.rate then rate = r.F.rate end

  local sections = Biquad.band(cfg, rate)
  local kw = Biquad.kweight(rate)
  local F0, F1 = 20, math.min(20000, rate * 0.49)
  local top, bot = 8, -60
  local l0, l1 = math.log(F0, 10), math.log(F1, 10)
  local function px(f) return x + (math.log(f, 10) - l0) / (l1 - l0) * w end
  local function py(v)
    return y + h - (math.max(bot, math.min(top, v)) - bot) / (top - bot) * h
  end

  for _, f in ipairs({ 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 }) do
    if f <= F1 then
      ImGui.DrawList_AddLine(dl, px(f), y, px(f), y + h, COL_GRID, 1)
      ImGui.DrawList_AddText(dl, px(f) + 3, y + h - 15, COL_GREY,
        f >= 1000 and string.format("%.0fk", f / 1000) or string.format("%d", f))
    end
  end
  ImGui.DrawList_AddLine(dl, x, py(0), x + w, py(0), COL_AXIS, 1)

  local function curve(secs, col, thick)
    local lx, ly
    local steps = 220
    for i = 0, steps do
      local f = 10 ^ (l0 + (l1 - l0) * i / steps)
      local cx, cy = px(f), py(Biquad.response_db(secs, f, rate))
      if lx then ImGui.DrawList_AddLine(dl, lx, ly, cx, cy, col, thick) end
      lx, ly = cx, cy
    end
  end
  curve(kw, COL_K, 1)
  curve(sections, COL_BAND, 2)

  ImGui.DrawList_AddText(dl, x + 6, y + 3, COL_BAND, "measurement band")
  ImGui.DrawList_AddText(dl, x + 150, y + 3, COL_K, "K-weighting (what LUFS uses)")
end

local function fmt_db(v)
  if not v or v <= Loudness.FLOOR_DB + 1 then return "--" end
  return string.format("%.2f", v)
end

-- The bias, per clip: how far this take's band level sits from its LUFS. A
-- bright, sibilant take shows a bigger gap than a dark one at the same LUFS,
-- and that difference is exactly what plain LUFS normalisation would have
-- charged the bright take for. It is a column rather than a footnote because
-- comparing it ACROSS clips is the whole diagnosis.
local function gap_text(r)
  if not (r.own and r.kw) then return "--" end
  return string.format("%.2f", r.own.db - r.kw.db)
end

local function clip_table()
  if not ST.rows or #ST.rows == 0 then
    help("Nothing analysed yet.")
    return
  end
  if not ImGui.BeginTable(ctx, "##clips", 8, TABLE_FLAGS) then return end
  depth.table_ = depth.table_ + 1

  for _, c in ipairs({ "clip", "band", "LUFS", "band-LUFS", "LRA", "peak",
                       "gain", "" }) do
    ImGui.TableSetupColumn(ctx, c)
  end
  ImGui.TableHeadersRow(ctx)

  for i, r in ipairs(ST.rows) do
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    if ImGui.Selectable(ctx, string.format("%s##row%d", r.name, i),
                        i == clip_index()) then
      ST.clip_idx = i
    end
    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, r.own and fmt_db(r.own.db) or "--")
    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, r.kw and fmt_db(r.kw.db) or "--")
    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, gap_text(r))
    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, r.lra and string.format("%.1f", r.lra) or "--")
    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, fmt_db(r.peak_db))
    ImGui.TableNextColumn(ctx)
    if r.gain_db then
      ImGui.TextColored(ctx, r.limit and COL_AMBER or COL_GATED,
                        string.format("%+.2f", r.gain_db))
    else
      ImGui.TextColored(ctx, COL_RED, "--")
    end
    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, r.limit and (r.limit .. " limit") or (r.err or ""))
  end

  depth.table_ = depth.table_ - 1
  ImGui.EndTable(ctx)
end

local function readout()
  local r = current_row()
  if not r then help("Nothing analysed yet.") return end
  if r.err and not r.band then
    ImGui.TextColored(ctx, COL_RED, r.err)
    return
  end
  local b = r.band
  ImGui.Text(ctx, string.format(
    "band %.2f dB   LUFS %.2f   gap %s dB   peak %.2f dBFS   %s",
    b.db, r.kw and r.kw.db or 0, gap_text(r), r.peak_db,
    r.lra and string.format("LRA %.1f LU", r.lra) or "LRA --"))
  ImGui.Text(ctx, string.format(
    "%d blocks, %d kept by the gate (relative gate %.2f dB)%s",
    b.nblocks, b.ngated, b.rel_gate_db,
    b.short and "  -- shorter than one block, measured over what there is" or ""))
  if not r.geo.rate_known then
    ImGui.TextColored(ctx, COL_AMBER, string.format(
      "This take's source reports no sample rate; %d Hz was assumed.",
      r.F.rate))
  end
end

------------------------------------------------------------------------ frame

local function header()
  local sel = Select.resolve()
  local stale = (not ST.clips) or
                (not sel.err and ST.analysed_key ~= selection_key(sel))

  begin_disabled(busy() or sel.err ~= nil)
  if ImGui.Button(ctx, stale and "Analyse" or "Re-analyse", 110, 0) then
    analyse(sel)
  end
  end_disabled()

  ImGui.SameLine(ctx)
  begin_disabled(busy() or sel.err ~= nil)
  if ImGui.Button(ctx, "Apply", 90, 0) then apply() end
  end_disabled()

  ImGui.SameLine(ctx)
  begin_disabled(not busy())
  if ImGui.Button(ctx, "Cancel", 80, 0) then ST.cancel = true end
  end_disabled()

  ImGui.SameLine(ctx)
  if busy() then
    ImGui.ProgressBar(ctx, ST.progress, 200, 0,
                      string.format("%s %.0f%%", ST.jobkind, ST.progress * 100))
  elseif stale and not sel.err then
    ImGui.TextColored(ctx, COL_AMBER, "Band settings or selection changed.")
  end

  ImGui.Text(ctx, Select.describe(sel))
  ImGui.Text(ctx, ST.status)
  if ST.err then ImGui.TextColored(ctx, COL_RED, ST.err) end
end

local function frame()
  step_job()
  if ST.clips and ST.priced ~= priced_sig() then
    recompute()
    ST.status = Plan.describe(ST.rows, ST.summary, cfg)
  end

  header()
  ImGui.Separator(ctx)

  local availw, availh = ImGui.GetContentRegionAvail(ctx)
  local bodyh = math.max(availh, 80)

  if ST.show_controls then
    begin_child("##controls", ST.ctrl_w, bodyh,
                CHILD_BORDER | (opt("ChildFlags_ResizeX") or 0))
    controls()
    end_child()
    ImGui.SameLine(ctx)
  end

  begin_child("##displays", 0, bodyh, CHILD_BORDER)
  local w = select(1, ImGui.GetContentRegionAvail(ctx))
  if nclips() > 1 then
    local names = {}
    for i, c in ipairs(ST.clips) do names[i] = c.name end
    local rv, s = ImGui.Combo(ctx, "Showing", clip_index() - 1,
                              table.concat(names, "\0") .. "\0")
    if rv then ST.clip_idx = s + 1 end
  end
  readout()
  block_plot(w, math.max(120, bodyh * 0.38))
  ImGui.Dummy(ctx, 1, 4)
  band_plot(w, math.max(100, bodyh * 0.24))
  ImGui.Dummy(ctx, 1, 4)
  clip_table()
  end_child()
end

-- Everything start() does except enter the defer loop. Split out so a test can
-- drive one frame against a stub: the panel is otherwise the only file the
-- suites cannot execute, and it is where a renamed config key lands -- as a
-- nil read that errors the frame and takes the whole panel below it with it.
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  CHILD_BORDER = opt("ChildFlags_Borders") or opt("ChildFlags_Border") or 0
  HAVE_SEPTEXT = opt("SeparatorText") ~= nil
  TABLE_FLAGS = (opt("TableFlags_Borders") or 0)
              | (opt("TableFlags_RowBg") or 0)
              | (opt("TableFlags_SizingStretchProp") or 0)
  cfg = Config.load()
  ctx = ImGui.CreateContext("Vocal Normalizer")
  depth.child, depth.disabled, depth.table_ = 0, 0, 0
  ST.kernels, ST.clips, ST.rows, ST.priced = {}, nil, nil, nil
  return ST, ctx, cfg
end

-- Renders one frame and closes anything it left open. Returns ok, err rather
-- than throwing, so no caller has to remember the unwind.
function M._frame()
  depth.child, depth.disabled, depth.table_ = 0, 0, 0
  local ok, err = pcall(frame)
  if not ok then
    while depth.table_ > 0 do depth.table_ = depth.table_ - 1 ImGui.EndTable(ctx) end
    while depth.child > 0 do end_child() end
    while depth.disabled > 0 do end_disabled() end
  end
  return ok, err
end

M._cfg = function() return cfg end

function M.start(imgui, dir)
  M._init(imgui, dir)

  local function loop()
    ImGui.SetNextWindowSize(ctx, 1180, 820, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Vocal Normalizer", true)
    if visible then
      local ok, err = M._frame()
      if not ok then ImGui.TextColored(ctx, COL_RED, tostring(err)) end
      ImGui.End(ctx)
    end
    if open then reaper.defer(loop) end
  end
  reaper.defer(loop)
end

return M
