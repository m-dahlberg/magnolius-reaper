-- @noindex
-- Spectral DeNoise -- ReaImGui panel.
--
-- Laid out in the order the algorithm runs: analyse the file, place the noise
-- band on the histogram, shape the reduction, gate, render.
--
-- The two displays are the point of the panel. The histogram shows the level
-- distribution of the whole file with the noise band drawn on it, so it is
-- visible at a glance whether the band is sitting on the room-tone lobe or has
-- wandered into programme material. The spectrum shows what came out of that
-- band -- the noise profile -- against the file's mean spectrum and the gain
-- curve the current settings produce.

local Config  = require "dn.config"
local Kernel  = require "dn.kernel"
local Analyze = require "dn.analyze"
local Profile = require "dn.profile"
local Gains   = require "dn.gains"
local Render  = require "dn.render"
local Apply   = require "dn.apply"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  item = nil, take = nil, k = nil, ksig = nil,
  hist = nil, th = nil, geo = nil, cache_key = nil,
  mean = nil, prof = nil, gain = nil, floor = nil,
  job = nil, jobkind = nil, progress = 0, cancel = false,
  status = "Select an item and press Analyse.", err = nil, note = nil,
  dirty = false,
}

local COL_BG     = 0x14181CFF
local COL_HIST   = 0x4A7FB5FF
local COL_BAND   = 0x50C87833
local COL_BANDE  = 0x50C878FF
local COL_LOBE   = 0xE0A050FF
local COL_GREY   = 0x808080FF
local COL_RED    = 0xE05050FF
local COL_SPEC   = 0x4A7FB5FF
local COL_NOISE  = 0xE0A050FF
local COL_GAIN   = 0x50C878FF
local COL_AXIS   = 0x40484EFF

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

----------------------------------------------------------------------- stages

-- Band placement and everything downstream of it. Cheap enough to run on every
-- slider frame, which is the whole point of caching the histogram in the
-- kernel rather than the frames themselves.
local function recompute()
  if not ST.hist or not ST.k then return end
  local th = Profile.band(ST.hist, cfg)
  ST.th = th
  th.frames = ST.k:build_profile(th.lo_bin, th.hi_bin, cfg.prof_offset_db)
  ST.prof = ST.k:profile_spectrum()
  ST.mean = ST.k:mean_spectrum()
  ST.gain, ST.floor = Gains.curve(ST.mean, ST.prof, ST.k.nbins, cfg)
  ST.dirty = false
end

-- The kernel's memory map is fixed by channel count and FFT size, so a change
-- in either means building a new one. Everything else, NLM included, is a
-- parameter the existing kernel takes in its stride.
local function ensure_kernel(nchan, srate)
  local sig = table.concat({ nchan, Config.fft_size(cfg), srate }, "|")
  if ST.k and ST.ksig == sig then return ST.k end
  if ST.k then pcall(ImGui.Detach, ctx, ST.k.func) end
  local k, err = Kernel.new(ImGui, ctx, script_dir, nchan,
                            Config.fft_size(cfg), cfg.nlm, srate)
  if not k then ST.k, ST.ksig = nil, nil return nil, err end
  ST.k, ST.ksig = k, sig
  ST.hist, ST.th = nil, nil     -- the histogram belonged to the old bin layout
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
  local k, kerr = ensure_kernel(geo.nchan, geo.rate)
  if not k then ST.err = kerr ST.status = "Failed." return end

  local key = Analyze.cache_key(ST.take, cfg)
  if ST.hist and key == ST.cache_key then
    ST.status = string.format("%d frames, %.1f s, %d ch at %d Hz  (cached)",
      k:frames(), geo.acc_len, geo.nchan, geo.rate)
    recompute()
    return
  end

  ST.geo = geo
  ST.status = "Analysing..."
  start_job("Analysing", function() return Analyze.run(ST.take, cfg, k) end,
    function(res, err)
      if not res then
        ST.status = (err == "cancelled") and "Cancelled." or "Analysis failed."
        if err ~= "cancelled" then ST.err = err end
        return
      end
      ST.cache_key = key
      ST.hist = Profile.histogram(k:counts(), k.nlev, k.lev0)
      ST.status = string.format("%d frames, %.1f s, %d ch at %d Hz",
        res.frames, geo.acc_len, geo.nchan, geo.rate)
      recompute()
    end)
end

-- Back to the defaults, including the FFT size -- which owns the bin layout, so
-- the histogram has to go with it if it changed.
local function reset_settings()
  local fftsel = cfg.fftsel
  Config.reset(cfg)
  if cfg.fftsel ~= fftsel then
    ST.hist, ST.th, ST.cache_key = nil, nil, nil
  end
  ST.dirty, ST.err, ST.note = true, nil, nil
end

local function render()
  if not ST.take or not ST.th or not ST.k then return end
  local path = Render.output_path(ST.take, cfg)
  if not path then ST.err = "Could not find a free output filename." return end

  cfg._band_lo, cfg._band_hi = ST.th.lo_db, ST.th.hi_db
  cfg._band_frames = ST.th.frames
  ST.status, ST.note = "Rendering...", nil
  local item, take = ST.item, ST.take
  start_job("Rendering", function() return Render.run(take, cfg, ST.k, path) end,
    function(res, err)
      if not res then
        ST.status = (err == "cancelled") and "Cancelled." or "Render failed."
        if err ~= "cancelled" then ST.err = err end
        return
      end
      local nt, aerr = Apply.run(item, take, res, cfg)
      if not nt then ST.err = aerr ST.status = "Render failed." return end
      ST.status = string.format("Wrote %s  (peak %.1f dB)",
        res.path:match("([^/\\]+)$"), 20 * math.log(math.max(res.peak, 1e-9), 10))
      ST.note = res.peak > 1.0 and
        "Peak is over 0 dBFS. The file is float, so nothing clipped." or nil
      -- The item now carries a new take; the old analysis still describes the
      -- source we read, so it stays valid.
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

-- Level histogram of the whole file with the noise band on it. Material with
-- pauses is bimodal; the band belongs on the lower lobe.
local function draw_histogram(w, h)
  local dl, x, y = plot_frame(w, h, "##hist")
  if not ST.hist or not ST.th then return end
  local hist, th = ST.hist, ST.th

  -- Trim the empty tails so the occupied range fills the width.
  local lo, hi = hist.nlev - 1, 0
  for b = 0, hist.nlev - 1 do
    if hist.counts[b] > 0 then
      if b < lo then lo = b end
      if b > hi then hi = b end
    end
  end
  if hi <= lo then return end
  lo, hi = math.max(0, lo - 2), math.min(hist.nlev - 1, hi + 2)
  local span = hi - lo
  local function px(db) return x + (db - Profile.db_of(hist, lo)) / span * w end

  local peak = 1
  for b = lo, hi do peak = math.max(peak, hist.counts[b]) end

  -- The band, drawn under the bars so it reads as a region, not a mask.
  ImGui.DrawList_AddRectFilled(dl, px(th.lo_db - 0.5), y,
                               px(th.hi_db + 0.5), y + h, COL_BAND)

  local bw = w / span
  for b = lo, hi do
    -- sqrt so the noise lobe stays visible next to a tall signal lobe
    local bh = math.sqrt(hist.counts[b] / peak) * (h - 4)
    local bx = px(Profile.db_of(hist, b) - 0.5)
    if bh > 0 then
      ImGui.DrawList_AddRectFilled(dl, bx, y + h - bh,
                                   bx + math.max(bw - 1, 1), y + h, COL_HIST)
    end
  end

  local function vline(db, col, label, above)
    local vx = px(db)
    if vx < x or vx > x + w then return end
    ImGui.DrawList_AddLine(dl, vx, y, vx, y + h, col, 1.5)
    ImGui.DrawList_AddText(dl, vx + 3, y + (above and 2 or 14), col, label)
  end
  vline(th.lo_db - 0.5, COL_BANDE, "", true)
  vline(th.hi_db + 0.5, COL_BANDE, "band", true)
  if th.lobe_db then vline(th.lobe_db, COL_LOBE, "lobe", false) end
  vline(th.signal_ref, COL_GREY, "p85", false)
  -- A lobe the analysis walked past. Worth drawing: it is usually the tallest
  -- thing on the plot, and without a mark it looks like the band missed it.
  if th.skipped_db then vline(th.skipped_db, COL_GREY, "silence", true) end

  ImGui.DrawList_AddText(dl, x + 4, y + h - 16, COL_GREY,
    string.format("%.0f dB", Profile.db_of(hist, lo)))
  local rlab = string.format("%.0f dB", Profile.db_of(hist, hi))
  ImGui.DrawList_AddText(dl, x + w - 8 * #rlab, y + h - 16, COL_GREY, rlab)
end

-- Input spectrum, noise profile and gain curve on a log-frequency axis, in the
-- same three colours the JSFX display uses.
local function draw_spectrum(w, h)
  local dl, x, y = plot_frame(w, h, "##spec")
  if not ST.prof or not ST.k then return end
  local n = ST.k.nbins
  local nyq = ST.geo.rate * 0.5
  local f0, f1 = 20, nyq
  local lg0, lg1 = math.log(f0, 10), math.log(f1, 10)
  local norm = (ST.k.fft_size * 0.25) ^ 2   -- 0 dB = a full-scale sine
  local range = 110

  local function fx(f)
    return x + (math.log(math.max(f, f0), 10) - lg0) / (lg1 - lg0) * w
  end
  local function py(db)
    local t = (db + range) / range
    return y + h - math.max(0, math.min(1, t)) * (h - 2) - 1
  end

  for _, f in ipairs({ 100, 1000, 10000 }) do
    if f < nyq then
      local gx = fx(f)
      ImGui.DrawList_AddLine(dl, gx, y, gx, y + h, COL_AXIS, 1)
      ImGui.DrawList_AddText(dl, gx + 2, y + h - 15, COL_GREY,
        f >= 1000 and (f / 1000 .. "k") or tostring(f))
    end
  end

  -- One vertical segment per pixel column, so 2049 bins do not have to become
  -- 2049 line calls.
  local function curve(vals, col, to_db)
    local px_lo, mn, mx = nil, nil, nil
    local lastx, lasty
    for i = 2, n do
      local f = (i - 1) * ST.geo.rate / ST.k.fft_size
      if f >= f0 then
        local cx = math.floor(fx(f))
        local db = to_db(vals[i])
        if cx ~= px_lo then
          if px_lo then
            local ytop, ybot = py(mx), py(mn)
            ImGui.DrawList_AddLine(dl, px_lo, ytop, px_lo, ybot, col, 1)
            if lastx then ImGui.DrawList_AddLine(dl, lastx, lasty, px_lo, ytop, col, 1) end
            lastx, lasty = px_lo, ybot
          end
          px_lo, mn, mx = cx, db, db
        else
          if db < mn then mn = db end
          if db > mx then mx = db end
        end
      end
    end
  end

  local function powdb(p) return 10 * math.log(math.max(p, 1e-30) / norm, 10) end
  curve(ST.mean, COL_SPEC, powdb)
  curve(ST.prof, COL_NOISE, powdb)
  -- gain is drawn as attenuation from the top of the panel
  curve(ST.gain, COL_GAIN, function(g)
    return 20 * math.log(math.max(g, 1e-6), 10)
  end)

  ImGui.DrawList_AddText(dl, x + 4, y + 2, COL_SPEC, "input")
  ImGui.DrawList_AddText(dl, x + 44, y + 2, COL_NOISE, "noise")
  ImGui.DrawList_AddText(dl, x + 88, y + 2, COL_GAIN, "gain")
end

--------------------------------------------------------------------- controls

local function mark_dirty() ST.dirty = true end

local function slider(label, key, lo, hi, fmt)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, fmt or "%.1f")
  if rv then cfg[key] = v mark_dirty() end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

local function checkbox(label, key)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then cfg[key] = v mark_dirty() Config.save(cfg) end
  return rv
end

local function busy() return ST.job ~= nil end

------------------------------------------------------------------------ frame

local function frame()
  step_job()

  ImGui.SeparatorText(ctx, "Source")
  ImGui.BeginDisabled(ctx, busy())
  if ImGui.Button(ctx, "Analyse selected item", 200, 0) then analyse() end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(ctx, ST.status)

  if busy() then
    ImGui.ProgressBar(ctx, ST.progress, -1, 0,
      string.format("%s  %.0f%%", ST.jobkind, ST.progress * 100))
    if ImGui.Button(ctx, "Cancel", 100, 0) then ST.cancel = true end
  end
  if ST.err then ImGui.TextColored(ctx, COL_RED, ST.err) end

  -- Nothing below may be touched while a job owns the kernel: rebuilding the
  -- profile would overwrite the very buffer the render is reading from.
  ImGui.BeginDisabled(ctx, busy())
  if ST.dirty and not busy() then recompute() end

  ImGui.SeparatorText(ctx, "Analysis")
  -- fftsel indexes Config.FFT_SIZES and so is 1-based; the combo is 0-based.
  -- Changing it changes the bin layout, which invalidates the histogram.
  do
    local ch, nv = ImGui.Combo(ctx, "FFT size", math.floor(cfg.fftsel) - 1,
                               "1024\0002048\0004096\0")
    if ch then
      cfg.fftsel = nv + 1
      ST.hist, ST.th, ST.cache_key = nil, nil, nil
      Config.save(cfg)
    end
  end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, ST.geo and string.format("%.0f ms window",
    Config.fft_size(cfg) / ST.geo.rate * 1000) or "")

  if ImGui.Button(ctx, "Reset all settings to default", 220, 0) then
    reset_settings()
  end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(every control on this panel)")

  if not ST.hist or not ST.th then
    ImGui.TextDisabled(ctx,
      "Analyse an item to derive its noise profile from the whole file.")
    ImGui.EndDisabled(ctx)
    return
  end
  local th = ST.th
  local availw = ImGui.GetContentRegionAvail(ctx)

  ImGui.SeparatorText(ctx, "Noise band")
  draw_histogram(availw, 110)
  ImGui.Text(ctx, string.format(
    "%.0f .. %.0f dB   %.0f frames (%.1f%% of the file)%s",
    th.lo_db, th.hi_db, th.frames, th.fraction * 100,
    th.lobe_db and string.format("   lobe at %.0f dB", th.lobe_db) or ""))
  if th.warning then ImGui.TextColored(ctx, COL_RED, th.warning) end
  if th.fallback then
    ImGui.TextColored(ctx, COL_LOBE,
      "No room-tone lobe found; using the quietest tenth of the file.")
  end
  if th.skipped_db then
    ImGui.TextColored(ctx, COL_LOBE, string.format(
      "Stepped over edited-in silence at %.0f dB (stripped pauses or a "
      .. "16-bit master's dither). That lobe is not room tone.", th.skipped_db))
  end

  checkbox("Auto", "band_auto")
  if cfg.band_auto then
    slider("Below the lobe (dB)", "band_below_db", 0, 24, "%.0f")
    slider("Above the lobe (dB)", "band_above_db", 0, 24, "%.0f")
  else
    slider("Band low (dB)", "band_lo_db", -110, 0, "%.0f")
    slider("Band high (dB)", "band_hi_db", -110, 0, "%.0f")
  end
  slider("Ignore below (dB)", "silence_db", -120, -40, "%.0f")
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(edited-in digital silence)")
  checkbox("Ignore quiet lobes with nothing between them and the material",
           "skip_silence")
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(recommended)")
  slider("Profile trim (dB)", "prof_offset_db", -12, 12, "%.1f")

  ImGui.SeparatorText(ctx, "Spectrum")
  draw_spectrum(availw, 150)

  ImGui.SeparatorText(ctx, "Denoise")
  do
    local ch, nv = ImGui.Combo(ctx, "Noise estimate", math.floor(cfg.mode),
      "Whole-file profile\0Adaptive (SPP-MMSE)\0")
    if ch then cfg.mode = nv mark_dirty() Config.save(cfg) end
  end
  slider("Reduction (dB)", "reduction", 0, 40)
  slider("Strength", "strength", 0, 100, "%.0f")
  slider("Smoothing", "smoothing", 0, 100, "%.0f")
  slider("Residual whitening (%)", "whitening", 0, 100, "%.0f")
  do
    -- NLM does not touch the histogram, so switching it costs nothing.
    local ch, nv = ImGui.Combo(ctx, "Musical noise smoothing (NLM)",
      math.floor(cfg.nlm), "Off\0Eco\0Full (slow)\0")
    if ch then cfg.nlm = nv mark_dirty() Config.save(cfg) end
  end
  checkbox("Render the residual instead (what is being removed)", "residual")

  ImGui.SeparatorText(ctx, "Output gate")
  checkbox("Enable", "gate_on")
  if cfg.gate_on then
    slider("Threshold (dB)##g", "gthresh", -80, 0, "%.1f")
    do
      local ch, nv = ImGui.Combo(ctx, "Mode##g", math.floor(cfg.gmode),
                                 "Gate\0Expander\0")
      if ch then cfg.gmode = nv mark_dirty() Config.save(cfg) end
    end
    if cfg.gmode == 1 then slider("Expander ratio", "gratio", 1, 20, "%.1f") end
    checkbox("Auto vocal timing", "gauto")
    if not cfg.gauto then
      slider("Attack (ms)", "gattack", 0.1, 300, "%.1f")
      slider("Release (ms)", "grelease", 5, 3000, "%.0f")
    else
      ImGui.TextDisabled(ctx,
        "1 ms attack, program-dependent release (60-400 ms). Hold stays manual.")
    end
    slider("Hold (ms)", "ghold", 0, 1000, "%.0f")
  end

  ImGui.SeparatorText(ctx, "Output")
  checkbox("Add as a new take (keeps the original)", "new_take")
  if cfg.new_take then checkbox("Make it the active take", "select_take") end
  ImGui.BeginDisabled(ctx, th.frames < 1)
  if ImGui.Button(ctx, cfg.residual and "Render residual" or "Render denoised",
                  190, 0) then
    render()
  end
  ImGui.EndDisabled(ctx)
  if ST.note then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, COL_LOBE, ST.note)
  end

  ImGui.EndDisabled(ctx)
end

function M.start(imgui, dir)
  ImGui, script_dir = imgui, dir
  cfg = Config.load()
  ctx = ImGui.CreateContext("Spectral DeNoise")

  local function loop()
    ImGui.SetNextWindowSize(ctx, 560, 860, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Spectral DeNoise", true)
    if visible then
      local ok, err = pcall(frame)
      if not ok then ImGui.TextColored(ctx, COL_RED, tostring(err)) end
      ImGui.End(ctx)
    end
    if open then reaper.defer(loop) end
  end
  reaper.defer(loop)
end

return M
