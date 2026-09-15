-- @noindex
-- Adaptive De-Click -- ReaImGui panel.
--
-- Laid out in the order the algorithm runs: analyse the file, place the
-- threshold on the overshoot distribution, look at what that caught, repair.
--
-- The three displays are the point of the panel, and each answers a different
-- question that no single number can:
--
--   the histogram   does this file HAVE a gap between clicks and consonants?
--   the waveform    WHERE does it want to cut, and does that look like clicks?
--   the band strip  is detection spread like mouth noise, or piled up in the
--                   top bands, which is what eating sibilance looks like?

local Config     = require "dc.config"
local Kernel     = require "dc.kernel"
local Analyze    = require "dc.analyze"
local AutoThresh = require "dc.autothresh"
local Detect     = require "dc.detect"
local Render     = require "dc.render"
local Apply      = require "dc.apply"
local Log        = require "dc.log"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  item = nil, take = nil, k = nil, ksig = nil, geo = nil,
  analysed = false, cache_key = nil, detect_sig = nil,
  hist = nil, th = nil, wmin = nil, wmax = nil, ck = nil,
  bandcnt = nil, bandsum = nil,
  job = nil, jobkind = nil, progress = 0, cancel = false,
  status = "Select an item and press Analyse.", err = nil, note = nil,
  dirty = false, stale = false,
}

local COL_BG    = 0x14181CFF
local COL_WAVE  = 0x4A7FB5FF
local COL_HIST  = 0x4A7FB5FF
local COL_FIT   = 0x9098A0FF
local COL_TAIL  = 0xE0A050FF
local COL_KNEE  = 0x5AA0E0FF
local COL_FINAL = 0x50C878FF
local COL_GREY  = 0x808080FF
local COL_RED   = 0xE05050FF
local COL_AXIS  = 0x40484EFF
local COL_BAND  = 0x50C87826   -- the active detection span
local COL_DIM   = 0x3A4653FF   -- a band detection is not listening to

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

----------------------------------------------------------------------- stages

-- Detection and everything downstream of it. Cheap enough to run on every
-- slider frame, which is the whole point of caching the envelopes rather than
-- the audio: nothing here re-reads a sample.
local function recompute()
  ST.dirty = false
  if not ST.k or not ST.analysed then return end
  local dsig = Config.detect_sig(cfg)
  if not ST.hist or dsig ~= ST.detect_sig then
    ST.hist = Detect.survey(ST.k, cfg)
    ST.detect_sig = dsig
  end
  ST.th = Detect.commit(ST.k, cfg, ST.hist)
  ST.wmin, ST.wmax, ST.ck = ST.k:waveform()
  ST.bandcnt, ST.bandsum = ST.k:bands()
end

-- The kernel's memory map is fixed by the take's length and the analysis
-- parameters, so a change in any of them means building a new one -- and,
-- since those are exactly the parameters that decide the envelopes, a re-read.
local function ensure_kernel(geo)
  local sig = Kernel.signature(geo, cfg)
  if ST.k and ST.ksig == sig then return ST.k end
  if ST.k then pcall(ImGui.Detach, ctx, ST.k.func) end
  ST.k, ST.ksig, ST.analysed, ST.hist = nil, nil, false, nil
  local k, err = Kernel.new(ImGui, ctx, script_dir, geo, cfg)
  if not k then return nil, err end
  ST.k, ST.ksig = k, sig
  return k
end

local function analyse()
  ST.item = reaper.GetSelectedMediaItem(0, 0)
  if not ST.item then ST.status = "No item selected." return end
  ST.take = reaper.GetActiveTake(ST.item)
  if not ST.take or reaper.TakeIsMIDI(ST.take) then
    ST.status = "Selected item has no audio take." return
  end

  local geo = Analyze.geometry(ST.take)
  ST.geo = geo
  local k, kerr = ensure_kernel(geo)
  if not k then ST.err = kerr ST.status = "Failed." return end

  local key = Analyze.cache_key(ST.take, cfg)
  if ST.analysed and key == ST.cache_key then
    ST.status = string.format("%.1f s, %d ch at %d Hz, %d steps  (cached)",
      geo.acc_len, geo.nchan, geo.rate, k.nsteps)
    ST.stale = false
    recompute()
    return
  end

  ST.status, ST.err = "Analysing...", nil
  start_job("Analysing", function() return Analyze.run(ST.take, cfg, k) end,
    function(res, err)
      if not res then
        ST.status = (err == "cancelled") and "Cancelled." or "Analysis failed."
        if err ~= "cancelled" then ST.err = err end
        return
      end
      ST.cache_key, ST.analysed, ST.stale = key, true, false
      ST.hist, ST.detect_sig = nil, nil
      ST.status = string.format(
        "%.1f s, %d ch at %d Hz, %d steps, %.0f MB cached",
        geo.acc_len, geo.nchan, geo.rate, res.steps, k.heap_mb)
      recompute()
    end)
end

local function reset_settings()
  Config.reset(cfg)
  ST.stale, ST.hist, ST.detect_sig = true, nil, nil
  ST.dirty, ST.err, ST.note = true, nil, nil
end

local function log_record(mode, elapsed, note)
  local src = reaper.GetMediaItemTake_Source(ST.take)
  local _, name = reaper.GetSetMediaItemTakeInfo_String(ST.take, "P_NAME", "", false)
  return {
    time = os.date("%Y-%m-%d %H:%M:%S"),
    name = (name ~= "" and name) or
           (reaper.GetMediaSourceFileName(src, ""):match("([^/\\]+)$") or ""),
    rate = ST.geo.rate, seconds = ST.geo.acc_len, channels = ST.geo.nchan,
    th = ST.th, cfg = cfg, mode = mode, elapsed = elapsed, note = note,
  }
end

local function write_log(dir, rec)
  if not cfg.write_log then return end
  local sep = package.config:sub(1, 1)
  local ok, err = Log.append(dir .. sep .. "declick-log.csv", rec)
  if not ok then ST.note = "Could not write the log: " .. tostring(err) end
end

local function run_output()
  if not ST.take or not ST.th or not ST.k then return end
  local t0 = reaper.time_precise()
  local events = ST.k:events(ST.th.stats and ST.th.stats.kept or 0)

  if cfg.dry_run then
    local nt, marked = Apply.run(ST.item, ST.take, nil, cfg, events, ST.th)
    if not nt then ST.err = marked ST.status = "Dry run failed." return end
    ST.status = string.format(
      "Dry run: %d events, %d marked, %.3f%% of the file would be repaired.",
      ST.th.stats.events, marked or 0, ST.th.stats.repaired * 100)
    local dir = reaper.GetProjectPath("")
    if dir ~= "" then
      write_log(dir, log_record("dry_run", reaper.time_precise() - t0))
    end
    return
  end

  local path = Render.output_path(ST.take, cfg)
  if not path then ST.err = "Could not find a free output filename." return end
  ST.status, ST.note = "Rendering...", nil
  local item, take, th = ST.item, ST.take, ST.th
  start_job("Rendering", function() return Render.run(take, cfg, ST.k, path) end,
    function(res, err)
      if not res then
        ST.status = (err == "cancelled") and "Cancelled." or "Render failed."
        if err ~= "cancelled" then ST.err = err end
        return
      end
      local nt, marked = Apply.run(item, take, res, cfg, events, th)
      if not nt then ST.err = marked ST.status = "Render failed." return end
      ST.status = string.format("Wrote %s  (%d events, %d marked, peak %.1f dB)",
        res.path:match("([^/\\]+)$"), th.stats.events, marked or 0,
        20 * math.log(math.max(res.peak, 1e-9), 10))
      ST.note = res.peak > 1.0 and
        "Peak is over 0 dBFS. The file is float, so nothing clipped." or nil
      write_log(res.path:match("^(.*)[/\\][^/\\]*$") or ".",
                log_record(cfg.isolate and "isolate" or "repair",
                           reaper.time_precise() - t0))
    end)
end

------------------------------------------------------------------------ draw

local function plot_frame(w, h, id)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, id, w, h)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, COL_BG, 4)
  return dl, x, y
end

-- Severity colour and thickness, shared by the waveform markers and the take
-- markers so the two agree: thin yellow at the threshold, thick red at +30 dB.
local function severity(over_db, floor_db)
  local s = math.max(0, math.min(1, (over_db - floor_db) / 30))
  local g = math.floor(217 - 191 * s)
  return (0xFF << 24) | (g << 16) | (0x26 << 8) | 0xE6, 1 + math.floor(s * 4 + 0.5), s
end

-- The overshoot distribution: how far each candidate stood above its own local
-- background. Musical transients taper smoothly; clicks sit past where the
-- taper ends. Log counts, because the tail is the whole subject.
local function draw_histogram(w, h)
  local dl, x, y = plot_frame(w, h, "##hist")
  if not ST.hist or not ST.th then return end
  local hist, th = ST.hist, ST.th

  local lo, hi = hist.n - 1, 0
  for b = 0, hist.n - 1 do
    if (hist.counts[b] or 0) > 0 then
      if b < lo then lo = b end
      if b > hi then hi = b end
    end
  end
  if hi <= lo then
    ImGui.DrawList_AddText(dl, x + 6, y + 6, COL_GREY, "no candidate events")
    return
  end
  lo, hi = math.max(0, lo - 4), math.min(hist.n - 1, hi + 4)
  local db0, db1 = AutoThresh.db_of(hist, lo), AutoThresh.db_of(hist, hi)
  local function px(db) return x + (db - db0) / (db1 - db0) * w end

  local peak = 1
  for b = lo, hi do peak = math.max(peak, hist.counts[b] or 0) end
  local lpk = math.log(1 + peak)
  local function py(c) return y + h - math.log(1 + math.max(c, 0)) / lpk * (h - 6) end

  local bw = w / (hi - lo)
  for b = lo, hi do
    local c = hist.counts[b] or 0
    if c > 0 then
      local bx = px(AutoThresh.db_of(hist, b) - hist.bin * 0.5)
      ImGui.DrawList_AddRectFilled(dl, bx, py(c), bx + math.max(bw - 1, 1),
                                   y + h, COL_HIST)
    end
  end

  -- The fitted taper, extrapolated past the bulk it was fitted to. Where the
  -- bars climb clear of this line is where the click population begins.
  if th.fit and th.fit.slope then
    local lastx, lasty
    for cx = 0, math.floor(w) do
      local db = db0 + (db1 - db0) * cx / w
      local v = math.exp(th.fit.slope * db + th.fit.icept)
      if v >= 0.02 then
        local cy = py(v)
        if lastx and cx % 6 < 4 then
          ImGui.DrawList_AddLine(dl, lastx, lasty, x + cx, cy, COL_FIT, 1)
        end
        lastx, lasty = x + cx, cy
      else
        lastx = nil
      end
    end
  end

  local function vline(db, col, label, row)
    if not db then return end
    local vx = px(db)
    if vx < x or vx > x + w then return end
    ImGui.DrawList_AddLine(dl, vx, y, vx, y + h, col, label == "used" and 2 or 1.5)
    ImGui.DrawList_AddText(dl, vx + 3, y + 2 + row * 13, col, label)
  end
  vline(th.tail_db, COL_TAIL, "tail", 0)
  vline(th.knee_db, COL_KNEE, "knee", 1)
  vline(th.sens_used, COL_FINAL, "used", 2)

  ImGui.DrawList_AddText(dl, x + 4, y + h - 15, COL_GREY,
    string.format("%.0f dB", db0))
  local r = string.format("%.0f dB", db1)
  ImGui.DrawList_AddText(dl, x + w - 8 * #r, y + h - 15, COL_GREY, r)
end

-- The item's waveform with a mark at every committed detection. Whole item,
-- because the question this answers is "is detection clustered somewhere it
-- should not be" -- take markers and the arrange view are the zoom.
local function draw_waveform(w, h)
  local dl, x, y = plot_frame(w, h, "##wave")
  if ST.wmin and ImGui.IsItemClicked(ctx) and ST.geo then
    local mx = ImGui.GetMousePos(ctx)
    local frac = math.max(0, math.min(1, (mx - x) / w))
    local pos = reaper.GetMediaItemInfo_Value(ST.geo.item, "D_POSITION")
    reaper.SetEditCurPos(pos + frac * ST.geo.item_len, true, false)
  end
  if not ST.wmin then return end

  local mid, half = y + h * 0.5, (h - 6) * 0.5
  ImGui.DrawList_AddLine(dl, x, mid, x + w, mid, COL_AXIS, 1)

  local nb = #ST.wmin
  local npx = math.floor(w)
  local bpp = nb / npx
  for i = 0, npx - 1 do
    local b0 = math.floor(i * bpp) + 1
    local b1 = math.min(nb, math.floor((i + 1) * bpp) + 1)
    local mn, mx = 0, 0
    for b = b0, b1 do
      local a, c = ST.wmin[b] or 0, ST.wmax[b] or 0
      if a < mn then mn = a end
      if c > mx then mx = c end
    end
    ImGui.DrawList_AddLine(dl, x + i, mid - mx * half, x + i, mid - mn * half,
                           COL_WAVE, 1)
  end

  -- Markers over the top, so a dense cluster is visible against the audio it
  -- sits on rather than hidden behind it.
  local floor_db = ST.th and ST.th.sens_used or 0
  for b = 1, nb do
    local o = ST.ck and ST.ck[b] or 0
    if o > 0 then
      local col, th_px = severity(o, floor_db)
      local mxp = x + (b - 1) / nb * w
      ImGui.DrawList_AddRectFilled(dl, mxp - th_px * 0.5, y,
                                   mxp + th_px * 0.5, y + h, col)
    end
  end
end

-- Where in the spectrum detection is happening, and which part of it detection
-- is listening to. Mouth noise spreads across the middle and upper bands;
-- plosives and vowel onsets put real energy low down, so a pile-up in the
-- bottom bands is what "it is eating my consonants" looks like from here --
-- and the span drawn over the bars is the control for exactly that.
local function draw_bands(w, h)
  local dl, x, y = plot_frame(w, h, "##bands")
  if not ST.bandcnt then return end
  local n = #ST.bandcnt
  if n < 1 then return end
  local blo, bhi = Config.band_range(cfg)

  local peak = 1
  for b = 1, n do peak = math.max(peak, ST.bandcnt[b] or 0) end
  local bw = w / n
  local top, bot = y + 4, y + h - 26

  -- Under the bars, so it reads as a region rather than a mask.
  ImGui.DrawList_AddRectFilled(dl, x + blo * bw, y, x + (bhi + 1) * bw, y + h,
                               COL_BAND)

  local every = math.max(1, math.ceil(44 / math.max(bw, 1)))
  for b = 1, n do
    local active = (b - 1) >= blo and (b - 1) <= bhi
    local c = ST.bandcnt[b] or 0
    local bx = x + (b - 1) * bw
    if c > 0 then
      local bh = math.sqrt(c / peak) * (bot - top)
      ImGui.DrawList_AddRectFilled(dl, bx + 1, bot - bh,
                                   bx + math.max(bw - 2, 1), bot,
                                   active and COL_WAVE or COL_DIM)
      if bw > 30 then
        ImGui.DrawList_AddText(dl, bx + 2, bot - bh - 12, COL_GREY,
                               string.format("%.0f", (ST.bandsum[b] or 0) / c))
      end
    end
    if (b - 1) % every == 0 then
      local fc = Config.band_center(cfg, b - 1)
      ImGui.DrawList_AddText(dl, bx + 1, bot + 6,
        active and COL_GREY or COL_AXIS,
        fc >= 1000 and string.format("%.1fk", fc / 1000)
                    or string.format("%.0f", fc))
    end
  end
end

--------------------------------------------------------------------- controls

-- BeginDisabled/EndDisabled through a counted pair, so that an error thrown
-- mid-frame cannot leave the stack unbalanced. It did: the pcall around
-- frame() swallowed the real error, ImGui.End then raised "Missing
-- EndDisabled()", and THAT error escaped the defer loop and killed the script
-- -- reporting the symptom while hiding the cause.
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

local function mark_dirty() ST.dirty = true end

-- An analysis parameter cannot take effect without re-reading the file, so
-- moving one marks the cache stale rather than pretending it applied.
local function mark_stale() ST.stale = true ST.dirty = true end

-- The changed-callback is bound to a local before being called. Writing
--     cfg[key] = v (on_change or mark_dirty)()
-- reads like two statements and is not: Lua treats a `(` following an
-- expression as a call, so that line calls `v` -- a number -- and every
-- control on the panel raised "attempt to call a number value" the moment it
-- was touched.
local function changed(key, v, on_change)
  cfg[key] = v
  local fn = on_change or mark_dirty
  fn()
end

local function slider(label, key, lo, hi, fmt, on_change)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, fmt or "%.1f")
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

-- Frequencies want a log scale: half the useful travel is under 1 kHz.
local function hz_slider(label, key, lo, hi, on_change)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, "%.0f Hz",
                                   ImGui.SliderFlags_Logarithmic)
  if rv then changed(key, v, on_change) end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

local function checkbox(label, key, on_change)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then changed(key, v, on_change) Config.save(cfg) end
  return rv
end

------------------------------------------------------------------------ frame

local function frame()
  step_job()

  ImGui.SeparatorText(ctx, "Source")
  begin_disabled(busy())
  if ImGui.Button(ctx, "Analyse selected item", 200, 0) then analyse() end
  end_disabled()
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(ctx, ST.status)

  if busy() then
    ImGui.ProgressBar(ctx, ST.progress, -1, 0,
      string.format("%s  %.0f%%", ST.jobkind, ST.progress * 100))
    if ImGui.Button(ctx, "Cancel", 100, 0) then ST.cancel = true end
  end
  if ST.err then ImGui.TextColored(ctx, COL_RED, ST.err) end

  -- Nothing below may be touched while a job owns the kernel: re-detecting
  -- would overwrite the very envelopes the render is reading from.
  begin_disabled(busy())
  if ST.dirty and not busy() then recompute() end

  if ImGui.Button(ctx, "Reset all settings to default", 220, 0) then
    reset_settings()
  end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(every control on this panel)")

  -- A settings migration is silent otherwise: the stored value is gone and the
  -- new default is simply what the sliders read. Saying which keys moved is the
  -- difference between "the script changed" and "my settings were wrong".
  if ST.migrated_note then
    ImGui.TextColored(ctx, COL_TAIL, ST.migrated_note)
  end

  if not ST.analysed or not ST.th then
    ImGui.TextDisabled(ctx,
      "Analyse an item to derive its threshold from its own click distribution.")
    end_disabled()
    return
  end
  local th, stats = ST.th, ST.th.stats or {}
  local availw = ImGui.GetContentRegionAvail(ctx)

  if ST.stale then
    ImGui.TextColored(ctx, COL_TAIL,
      "Analysis parameters changed -- press Analyse for them to take effect.")
  end

  ImGui.SeparatorText(ctx, "Threshold")
  draw_histogram(availw, 130)
  ImGui.Text(ctx, string.format(
    "%d candidates surveyed at %.1f dB    tail %s    knee %s    using %.1f dB",
    ST.hist.events or 0, cfg.sens_floor_db,
    th.tail_db and string.format("%.1f", th.tail_db) or "--",
    th.knee_db and string.format("%.1f", th.knee_db) or "--",
    th.sens_used or 0))
  if th.warning then ImGui.TextColored(ctx, COL_RED, th.warning) end
  if th.fallback then
    ImGui.TextColored(ctx, COL_TAIL, "No gap found; see the note above.")
  end
  if th.budget_note then ImGui.TextColored(ctx, COL_TAIL, th.budget_note) end

  -- What came out of passages that hold no audio. These never survive a
  -- threshold, so they change nothing about the repair -- but they dilute the
  -- distribution the threshold is READ off, and always towards a more
  -- aggressive setting. Worth showing: without it, the only visible symptom is
  -- a number that is quietly a few dB low. See dc/silence.lua.
  local sil = ST.hist.silence
  if sil and sil.floor_db then
    ImGui.TextColored(ctx, COL_TAIL, string.format(
      "Ignoring everything under %.0f dBFS: %.0f%% of this file holds no audio "
      .. "(stripped pauses, a gate, or a 16-bit master's dither).",
      sil.floor_db, 100 * sil.skipped / math.max(sil.total, 1)))
  elseif sil and sil.refused then
    ImGui.TextColored(ctx, COL_RED, string.format(
      "%.0f%% of this file holds no audio, which is too much to ignore safely. "
      .. "The derived threshold is resting on it and will read low.",
      100 * sil.skipped / math.max(sil.total, 1)))
  end

  checkbox("Derive the threshold from the file", "thresh_auto")
  if cfg.thresh_auto then
    slider("Sensitivity offset (dB)", "sens_offset_db", -12, 12, "%.1f")
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, "(the tuning knob)")
  else
    slider("Sensitivity threshold (dB)", "sens_db", 0.5, 42, "%.1f")
  end

  ImGui.SeparatorText(ctx, "Detections")
  draw_waveform(availw, 120)
  ImGui.TextDisabled(ctx, "click to move the edit cursor")
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, string.format(
    "%d clicks, %.3f%% of the file repaired%s",
    stats.events or 0, (stats.repaired or 0) * 100,
    (th.retries or 0) > 0 and string.format(", after %d retries", th.retries) or ""))

  ImGui.SeparatorText(ctx, "Detection band")
  draw_bands(availw, 92)
  do
    local flo, fhi = Config.band_edges(cfg)
    local blo, bhi = Config.band_range(cfg)
    hz_slider("Listen from", "det_lo_hz", flo, fhi)
    hz_slider("Listen to", "det_hi_hz", flo, fhi)
    slider("Residual must reach (Hz)", "min_reach_hz", 0, 20000, "%.0f")
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, "(0 = off)")
    ImGui.Text(ctx, string.format("bands %d-%d of %d  (%.0f - %.0f Hz)",
      blo + 1, bhi + 1, cfg.nbands,
      Config.band_center(cfg, blo), Config.band_center(cfg, bhi)))
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Full") then
      cfg.det_lo_hz, cfg.det_hi_hz = flo, fhi
      mark_dirty() Config.save(cfg)
    end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Mouth clicks") then
      -- Above the fundamental and the first formants, where plosives and vowel
      -- onsets live, and where a smack still has most of its energy.
      cfg.det_lo_hz = math.min(math.max(2000, flo), fhi)
      cfg.det_hi_hz = fhi
      mark_dirty() Config.save(cfg)
    end
    ImGui.TextDisabled(ctx,
      "Raising the low edge is what stops plosives and vowel onsets being")
    ImGui.TextDisabled(ctx,
      "detected. It will not separate clicks from sibilance -- an /s/ lives in")
    ImGui.TextDisabled(ctx,
      "the same bands; shorten Max click length for that.")
    if fhi <= flo * 1.001 then
      ImGui.TextColored(ctx, COL_RED,
        "The analysed span is empty -- widen Low/High frequency under Analysis.")
    end
  end

  ImGui.SeparatorText(ctx, "Detection")
  islider("Max click length (steps)", "max_steps", 1, 10)
  islider("Min time between clicks (steps)", "sep", 1, 10)
  slider("Max event length (ms)", "max_event_ms", 0, 200, "%.0f")
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(0 = off)")
  slider("Dense click threshold (dB)", "crackle_db", -90, 0, "%.0f")

  if ImGui.CollapsingHeader(ctx, "Analysis (re-reads the file)") then
    slider("Step size (ms)", "step_ms", 1, 20, "%.1f", mark_stale)
    islider("Bands", "nbands", 1, 30, mark_stale)
    slider("Low frequency (Hz)", "flo", 20, 20000, "%.0f", mark_stale)
    slider("High frequency (Hz)", "fhi", 20, 20000, "%.0f", mark_stale)
    islider("Step grid phases", "nphases", 1, 4, mark_stale)
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, "(the plugin's Passes)")
    ImGui.Separator(ctx)
    slider("Analysis floor (dB)", "sens_floor_db", 0.5, 12, "%.1f")
    checkbox("Ignore passages that hold no audio", "skip_silence")
    slider("Tail departure factor", "tail_factor", 1.5, 10, "%.1f")
    slider("Knee sweep low (dB)", "sweep_min_db", 0.5, 20, "%.1f")
    slider("Knee sweep high (dB)", "sweep_max_db", 10, 60, "%.0f")
  end

  ImGui.SeparatorText(ctx, "Repair")
  slider("Crossfade widen (ms)", "xfade_ms", 0, 20, "%.1f")
  slider("Max cut depth (dB)", "max_cut_db", 3, 48, "%.0f")
  checkbox("Repair budget", "use_budget")
  if cfg.use_budget then
    slider("Budget (% of steps cut)", "repair_budget_pct", 0.1, 50, "%.1f")
    islider("Max retries", "max_retries", 0, 10)
    slider("Threshold step per retry (dB)", "db_step_on_retry", 0.5, 10, "%.1f")
  end

  ImGui.SeparatorText(ctx, "Output")
  checkbox("Isolate changes (render what is removed)", "isolate")
  checkbox("Dry run (mark only, write no audio)", "dry_run")
  checkbox("Place take markers", "place_take_markers")
  checkbox("Write a CSV log", "write_log")
  if not cfg.dry_run then
    checkbox("Add as a new take (keeps the original)", "new_take")
    if cfg.new_take then checkbox("Make it the active take", "select_take") end
  end

  begin_disabled(ST.stale)
  local label = cfg.dry_run and "Mark detections"
             or (cfg.isolate and "Render isolated clicks" or "Render de-clicked")
  if ImGui.Button(ctx, label, 210, 0) then run_output() end
  end_disabled()
  if ST.note then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, COL_TAIL, ST.note)
  end

  end_disabled()
end

-- Test hooks: wire the panel up without starting the defer loop, so a suite can
-- render one frame against a stub ImGui. The panel needs a real context and a
-- defer loop to run for real, but every way it has broken has been a Lua error
-- inside frame(), and those raise against a stub just as well.
M._frame = frame

function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.new()
  ctx = imgui.CreateContext("Adaptive De-Click (test)")
  dis_depth = 0
  return ST, cfg
end

function M._disabled_depth() return dis_depth end

function M.start(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.load()
  if Config.migrated and #Config.migrated > 0 then
    ST.migrated_note = string.format(
      "Settings updated: %s reset to the new defaults (%d bands, %.0f Hz). " ..
      "The analysed span used to stop at 9.6 kHz, below where most mouth " ..
      "clicks carry their energy. If you were running a negative Sensitivity " ..
      "offset to compensate, take it back to 0.",
      table.concat(Config.migrated, ", "), cfg.nbands, cfg.fhi)
  end
  ctx = ImGui.CreateContext("Adaptive De-Click")

  local function loop()
    ImGui.SetNextWindowSize(ctx, 580, 900, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Adaptive De-Click", true)
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
