-- @noindex
-- Loudness Envelope -- ReaImGui panel.
--
-- Two columns: the controls on the left in the order the algorithm runs, and
-- the plot on the right. The plot is the reason the panel exists: the only way
-- to tell whether a curve "follows phrases, not syllables" is to see it drawn
-- over the level it came from.
--
-- Only the source -- which track, and whether the time selection limits it --
-- needs another Analyse. Every other control re-derives the curve from frames
-- already in memory, so it moves while you drag. The panel says which is which.

local Config    = require "le.config"
local Kernel    = require "le.kernel"
local Analyze   = require "le.analyze"
local Curve     = require "le.curve"
local Source    = require "le.source"
local Apply     = require "le.apply"
local Trackpick = require "le.trackpick"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  kernels = {},          -- kernel_sig -> kernel
  src = nil,             -- the source as analysed: track, name, clips, t0, t1
  key = nil,             -- the cache key that analysis was made under
  F = nil,               -- merged frame table
  res = nil, res_err = nil, csig = nil,
  rate_guessed = false,
  job = nil, jobkind = nil, progress = 0, cancel = false, on_done = nil,
  status = "Select the source track and press Analyse.",
  err = nil, warn = nil,
  show_controls = true, ctrl_w = 360,
  hover_t = nil,
}

local COL_BG      = 0x14181CFF
local COL_GRID    = 0x2A3036FF
local COL_GREY    = 0x808080FF
local COL_RED     = 0xE05050FF
local COL_AMBER   = 0xE0A050FF
local COL_GREEN   = 0x50C878FF
local COL_ACTIVE  = 0x4A7FB5FF   -- detector level, singing
local COL_QUIET   = 0x3A4248FF   -- detector level, gated out
local COL_OUTLINE = 0xC0C8D080   -- the median, before smoothing
local COL_CURVE   = 0xF0A040FF   -- what will be written
local COL_MID     = 0xF0E080AA
local COL_RANGE   = 0xF0E08040
local COL_THRESH  = 0x7FA8D0AA
local COL_CURSOR  = 0xC0C8D0AA

-- Balancing the ImGui stack across an error ----------------------------------
--
-- A frame that throws between BeginChild and EndChild leaves ImGui's stack
-- unbalanced, which ReaImGui raises on at the next End -- OUTSIDE any pcall
-- around the frame body. In REAPER that is a modal dialog and a main thread
-- that stops answering. So every pair that can straddle a failure is counted
-- and unwound in _frame.
local depth = { child = 0, disabled = 0 }

-- An optional ImGui symbol has to be ASKED for: the ReaImGui shim raises on an
-- unknown field rather than returning nil.
local function opt(name)
  local ok, v = pcall(function() return ImGui[name] end)
  if ok then return v end
  return nil
end

local CHILD_BORDER = 0
local HAVE_SEPTEXT = false

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
    -- The job cannot read audio from inside a coroutine (see analyze.lua); it
    -- yields a request and the read happens here, on the main thread.
    if Analyze.service(a) then
      ST.progress = a.progress or ST.progress
    end
  end
end

local function start_job(kind, body, on_done)
  ST.job = coroutine.create(body)
  ST.jobkind, ST.progress, ST.cancel = kind, 0, false
  ST.err, ST.warn = nil, nil
  ST.on_done = on_done
end

local function busy() return ST.job ~= nil end

------------------------------------------------------------------------ stages

local function drop_kernels()
  for _, k in pairs(ST.kernels) do Kernel.detach(ImGui, ctx, k) end
  ST.kernels = {}
end

local function ensure_kernel(nchan, rate)
  local sig = Config.kernel_sig(nchan, rate)
  local k = ST.kernels[sig]
  if k then return k end
  local new, err = Kernel.new(ImGui, ctx, script_dir, nchan, rate)
  if not new then return nil, err end
  ST.kernels[sig] = new
  return new
end

-- The cheap half: the whole curve from frames in memory. Runs whenever its
-- signature moves, which while a slider is dragged is every frame.
local function recompute()
  ST.csig = Config.curve_sig(cfg)
  if not ST.F then ST.res, ST.res_err = nil, nil return end
  ST.res, ST.res_err = Curve.build(ST.F, cfg)
end

local function track_alive(tr)
  return tr ~= nil and reaper.ValidatePtr2(0, tr, "MediaTrack*")
end

-- Is the analysis in hand still a true picture of its track? Rebuilt every
-- frame rather than flagged, so an item moved, trimmed or re-gained after the
-- Analyse shows as stale without anything having to remember to say so.
local function analysed_is_current()
  if not (ST.src and ST.key and track_alive(ST.src.track)) then return false end
  local now = Source.resolve(cfg, ST.src.track)
  return Source.cache_key(now, cfg) == ST.key
end

local function analyse(src, after)
  local key = Source.cache_key(src, cfg)

  -- Geometry and kernels on the main thread; only reads and Executes inside.
  local clips, guessed = {}, false
  for i, c in ipairs(src.clips) do
    local geo = Analyze.geometry(c)
    local k, err = ensure_kernel(geo.nchan, geo.rate)
    if not k then ST.err, ST.status = err, "Failed." return end
    if not geo.rate_known then guessed = true end
    clips[i] = { clip = c, geo = geo, k = k }
  end

  ST.status = "Analysing " .. src.name .. "..."
  start_job("Analysing", function()
    local n, out = #clips, {}
    for i, c in ipairs(clips) do
      local r, err = Analyze.run(c.clip, c.k, c.geo, (i - 1) / n, i / n)
      if not r then return nil, err end
      out[i] = r
    end
    return out
  end, function(out, jerr)
    if not out then
      ST.status = (jerr == "cancelled") and "Cancelled." or "Failed."
      if jerr ~= "cancelled" then ST.err = jerr end
      return
    end
    ST.src, ST.key, ST.rate_guessed = src, key, guessed
    ST.F = Curve.merge(out, src.t0, src.t1, Config.FRAME_S)
    recompute()
    ST.status = ST.res and string.format("Analysed %s.", src.name)
                        or ("Analysed, but: " .. tostring(ST.res_err))
    if after then after() end
  end)
end

local function dest_track()
  local tracks = Trackpick.tracks()
  local t, err = Trackpick.resolve(tracks, cfg, "dest")
  return t, err, tracks
end

local function write()
  local function go()
    if not ST.res then ST.status = ST.res_err or "Nothing to write." return end
    local d = dest_track()
    if not d then ST.status = "Pick a destination track." return end
    local n, warn = Apply.write(d.track, ST.res.points, ST.res.t0, ST.res.t1)
    if not n then ST.err = warn ST.status = "Not written." return end
    ST.warn = warn
    ST.status = string.format("Wrote %d points to %s's Vocal Rider Target, %.1f - %.1f s.",
                              n, d.name, ST.res.t0, ST.res.t1)
  end
  -- Write against the analysis in hand when it is still current; otherwise
  -- re-read the same track first, so a stale curve is never written.
  if analysed_is_current() then go() return end
  local src = (ST.src and track_alive(ST.src.track))
              and Source.resolve(cfg, ST.src.track) or Source.resolve(cfg)
  if src.err then ST.status = src.err return end
  analyse(src, go)
end

------------------------------------------------------------------- controls

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
  if rv then
    cfg[key] = v
    Config.save(cfg)
  end
  return rv
end

-- Wrapped at the column's edge: the controls column is resizable, and a help
-- line clipped mid-sentence is worse than none.
local function help(text)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, COL_GREY, text)
  ImGui.PopTextWrapPos(ctx)
end

local function controls()
  section("Source  -- changing this needs another Analyse")
  checkbox("Limit to time selection", "use_timesel")
  help("The source is the first selected track.")

  section("Measurement  -- the rider's own detector")
  slider("Detector window", "detector_ms", 5, 500, "%.0f ms")
  slider("Gate", "gate_abs_db", -80, -20, "%.1f dB")
  slider("Relative gate", "gate_rel_db", 6, 40, "%.0f dB below")
  help("Gate: below this is not singing. Relative gate: nor is anything this far under the take's sung level.")
  local d = dest_track()
  local rider = d and Apply.find_rider(d.track)
  begin_disabled(not rider)
  if ImGui.Button(ctx, "Match the destination rider") then
    -- slider6 is the rider's vocal loudness window, slider4 its noise floor.
    cfg.detector_ms = reaper.TrackFX_GetParam(d.track, rider.fx, 5)
    cfg.gate_abs_db = reaper.TrackFX_GetParam(d.track, rider.fx, 3)
    Config.save(cfg)
  end
  end_disabled()
  help("Copies its loudness window and noise floor.")

  section("Outline  -- what makes it follow phrases, not syllables")
  slider("Outline window", "outline_s", 0.5, 8, "%.1f s")
  help("A median over this much singing. Raise it if syllables show through.")
  slider("Smoothing", "smooth_s", 0, 5, "%.2f s")

  section("Range")
  slider("Depth", "depth_pct", 0, 100, "%.0f%%")
  slider("Range", "range_db", 0, 20, "+/- %.1f dB")
  slider("Offset", "offset_db", -12, 12, "%+.1f dB")
  help("Depth scales the movement around the median; Range caps it.")

  section("Output")
  local dt, derr, tracks = dest_track()
  Trackpick.widget(ImGui, ctx, "Destination", cfg, "dest", tracks, dt, derr,
                   function() Config.save(cfg) end)
  if dt then
    local r, rerr = Apply.find_rider(dt.track)
    if r then
      ImGui.TextColored(ctx, COL_GREEN, string.format("FX %d: %s", r.fx + 1, r.name))
    else
      ImGui.TextColored(ctx, COL_RED, rerr)
    end
    if ST.src and track_alive(ST.src.track) and dt.track == ST.src.track then
      ImGui.TextColored(ctx, COL_AMBER, "Destination is the source track.")
    end
  end
  slider("Point tolerance", "tolerance_db", 0.02, 1, "%.2f dB")

  ImGui.Dummy(ctx, 1, 6)
  if ImGui.Button(ctx, "Reset settings") then Config.reset(cfg) end
end

------------------------------------------------------------------------ plot

local function fmt_time(t)
  local m = math.floor(t / 60)
  return string.format("%d:%04.1f", m, t - m * 60)
end

local function plot(w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##plot", w, math.max(h, 1))
  local hovered = ImGui.IsItemHovered(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, COL_BG, 4)

  local r = ST.res
  if not r then
    ImGui.DrawList_AddText(dl, x + 8, y + 8, COL_GREY,
      ST.res_err or "nothing analysed")
    return
  end
  local n = #r.curve
  local t0, t1 = r.t0, math.max(r.t1, r.t0 + 1e-3)
  local span = t1 - t0

  local top = math.ceil((math.max(r.hi, r.med_active + 8) + 3) / 6) * 6
  local bot = top - 54
  local function py(v)
    return y + h - (math.max(bot, math.min(top, v)) - bot) / (top - bot) * h
  end
  local function px(t) return x + (t - t0) / span * w end

  for db = math.ceil(bot / 6) * 6, top, 6 do
    local gy = py(db)
    ImGui.DrawList_AddLine(dl, x + 30, gy, x + w, gy, COL_GRID, 1)
    ImGui.DrawList_AddText(dl, x + 3, gy - 7, COL_GREY, string.format("%.0f", db))
  end
  local step = span > 240 and 30 or (span > 90 and 10 or (span > 20 and 5 or 1))
  local tt = math.ceil(t0 / step) * step
  while tt < t1 do
    ImGui.DrawList_AddLine(dl, px(tt), y, px(tt), y + h, COL_GRID, 1)
    ImGui.DrawList_AddText(dl, px(tt) + 3, y + h - 15, COL_GREY, fmt_time(tt))
    tt = tt + step
  end

  -- The detector level, one column per pixel: its min..max over the column,
  -- blue where any of it was singing. Drawing every grid point would be
  -- thousands of lines a frame for no more information than this. Each
  -- column also reaches back to where the previous one ended, so a short
  -- take -- fewer grid points than pixels -- draws a trace, not dashes.
  local cols = math.max(1, math.floor(w))
  local per = n / cols
  local prev
  for c = 0, cols - 1 do
    local a = math.floor(c * per) + 1
    local b = math.min(n, math.max(a, math.floor((c + 1) * per)))
    local lo, hi, act = math.huge, -math.huge, false
    if prev then lo, hi = prev, prev end
    for j = a, b do
      local v = r.level[j]
      if v < lo then lo = v end
      if v > hi then hi = v end
      if r.active[j] then act = true end
    end
    prev = r.level[b]
    if hi > bot then
      local cx = x + c + 0.5
      ImGui.DrawList_AddLine(dl, cx, py(lo), cx, py(hi) - 1,
                             act and COL_ACTIVE or COL_QUIET, 1)
    end
  end

  ImGui.DrawList_AddLine(dl, x + 30, py(r.thresh), x + w, py(r.thresh), COL_THRESH, 1)
  local mid = r.mid + cfg.offset_db
  ImGui.DrawList_AddLine(dl, x + 30, py(mid), x + w, py(mid), COL_MID, 1)
  if cfg.range_db > 0 then
    ImGui.DrawList_AddLine(dl, x + 30, py(mid + cfg.range_db), x + w,
                           py(mid + cfg.range_db), COL_RANGE, 1)
    ImGui.DrawList_AddLine(dl, x + 30, py(mid - cfg.range_db), x + w,
                           py(mid - cfg.range_db), COL_RANGE, 1)
  end

  -- The outline before smoothing, where it had something to say. Drawn as
  -- measured -- no depth, no offset -- because it belongs with the level.
  local lx, ly
  for j = 1, n do
    local v = r.outline[j]
    if v then
      local cx, cy = px(r.t[j]), py(v)
      if lx then ImGui.DrawList_AddLine(dl, lx, ly, cx, cy, COL_OUTLINE, 1) end
      lx, ly = cx, cy
    else
      lx = nil
    end
  end

  -- The curve as it will be written: through the simplified points, which is
  -- what REAPER will interpolate between.
  local pts = r.points
  for i = 2, #pts do
    ImGui.DrawList_AddLine(dl, px(pts[i - 1].t), py(pts[i - 1].v),
                           px(pts[i].t), py(pts[i].v), COL_CURVE, 2)
  end
  if #pts <= 300 then
    for _, p in ipairs(pts) do
      ImGui.DrawList_AddCircleFilled(dl, px(p.t), py(p.v), 2, COL_CURVE)
    end
  end

  if hovered then
    local mx = ImGui.GetMousePos(ctx)
    ST.hover_t = t0 + math.max(0, math.min(span, (mx - x) / w * span))
  end
  if ST.hover_t and ST.hover_t >= t0 and ST.hover_t <= t1 then
    ImGui.DrawList_AddLine(dl, px(ST.hover_t), y, px(ST.hover_t), y + h, COL_CURSOR, 1)
  end

  ImGui.DrawList_AddText(dl, x + 34, y + 3, COL_ACTIVE, "level (singing)")
  ImGui.DrawList_AddText(dl, x + 150, y + 3, COL_OUTLINE, "outline")
  ImGui.DrawList_AddText(dl, x + 215, y + 3, COL_CURVE, "target curve")
  ImGui.DrawList_AddText(dl, x + 320, y + 3, COL_MID, "median +/- range")
  ImGui.DrawList_AddText(dl, x + 455, y + 3, COL_THRESH, "gate")
end

local function readout()
  local r = ST.res
  if not r then
    if ST.res_err then ImGui.TextColored(ctx, COL_RED, ST.res_err) end
    return
  end
  ImGui.Text(ctx, string.format(
    "Sung level %.1f dB, gate at %.1f dB.  Curve median %.1f dB, spans %.1f .. %.1f dB.",
    r.med_active, r.thresh, r.mid + cfg.offset_db, r.lo, r.hi))
  ImGui.Text(ctx, string.format("%d points over %s - %s.", #r.points,
                                fmt_time(r.t0), fmt_time(r.t1)))
  if ST.hover_t then
    local j = math.floor((ST.hover_t - r.t0) / r.grid + 0.5) + 1
    if j >= 1 and j <= #r.curve then
      ImGui.Text(ctx, string.format("At %s: level %.1f dB%s, target %.1f dB",
        fmt_time(ST.hover_t), r.level[j], r.active[j] and "" or " (gated)",
        Curve.eval_points(r.points, ST.hover_t)))
    end
  end
  if ST.rate_guessed then
    ImGui.TextColored(ctx, COL_AMBER,
      "A source reported no sample rate; the project rate was assumed.")
  end
end

------------------------------------------------------------------------ frame

local function header()
  local sel = Source.resolve(cfg)
  local current = analysed_is_current()
  local same = ST.src and not sel.err and sel.track == ST.src.track

  begin_disabled(busy() or sel.err ~= nil)
  if ImGui.Button(ctx, (current and same) and "Re-analyse" or "Analyse", 110, 0) then
    analyse(sel)
  end
  end_disabled()

  ImGui.SameLine(ctx)
  begin_disabled(busy() or not (ST.res or ST.src))
  if ImGui.Button(ctx, "Write", 90, 0) then write() end
  end_disabled()

  ImGui.SameLine(ctx)
  begin_disabled(not busy())
  if ImGui.Button(ctx, "Cancel", 80, 0) then ST.cancel = true end
  end_disabled()

  ImGui.SameLine(ctx)
  if busy() then
    ImGui.ProgressBar(ctx, ST.progress, 200, 0,
                      string.format("%s %.0f%%", ST.jobkind, ST.progress * 100))
  elseif ST.src and not current then
    ImGui.TextColored(ctx, COL_AMBER, "The source changed since it was analysed.")
  end

  if ST.src then
    ImGui.Text(ctx, "Analysed: " .. ST.src.name
      .. ((sel.err or same) and "" or ("    Selected: " .. sel.name)))
  else
    ImGui.Text(ctx, Source.describe(sel))
  end
  ImGui.Text(ctx, ST.status)
  if ST.warn then ImGui.TextColored(ctx, COL_AMBER, ST.warn) end
  if ST.err then ImGui.TextColored(ctx, COL_RED, ST.err) end
end

local function frame()
  step_job()
  if ST.csig ~= Config.curve_sig(cfg) then recompute() end

  header()
  ImGui.Separator(ctx)

  local _, availh = ImGui.GetContentRegionAvail(ctx)
  local bodyh = math.max(availh, 80)

  if ST.show_controls then
    begin_child("##controls", ST.ctrl_w, bodyh,
                CHILD_BORDER | (opt("ChildFlags_ResizeX") or 0))
    controls()
    end_child()
    ImGui.SameLine(ctx)
  end

  begin_child("##display", 0, bodyh, CHILD_BORDER)
  local w = select(1, ImGui.GetContentRegionAvail(ctx))
  local rv, v = ImGui.Checkbox(ctx, "Controls", ST.show_controls)
  if rv then ST.show_controls = v end
  readout()
  local _, h = ImGui.GetContentRegionAvail(ctx)
  plot(w, math.max(160, h - 8))
  end_child()
end

-- Everything start() does except enter the defer loop, so a test can drive
-- one frame against a stub ImGui.
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  CHILD_BORDER = opt("ChildFlags_Borders") or opt("ChildFlags_Border") or 0
  HAVE_SEPTEXT = opt("SeparatorText") ~= nil
  cfg = Config.load()
  ctx = ImGui.CreateContext("Loudness Envelope")
  depth.child, depth.disabled = 0, 0
  ST.kernels, ST.src, ST.key, ST.F, ST.res, ST.res_err, ST.csig =
    {}, nil, nil, nil, nil, nil, nil
  ST.job, ST.err, ST.warn, ST.hover_t = nil, nil, nil, nil
  return ST, ctx, cfg
end

-- Renders one frame and closes anything it left open. Returns ok, err rather
-- than throwing, so no caller has to remember the unwind.
function M._frame()
  depth.child, depth.disabled = 0, 0
  local ok, err = pcall(frame)
  if not ok then
    while depth.child > 0 do end_child() end
    while depth.disabled > 0 do end_disabled() end
  end
  return ok, err
end

M._cfg = function() return cfg end
M._depth = function() return depth.child + depth.disabled end

function M.start(imgui, dir)
  M._init(imgui, dir)

  local function loop()
    ImGui.SetNextWindowSize(ctx, 1180, 720, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Loudness Envelope", true)
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
