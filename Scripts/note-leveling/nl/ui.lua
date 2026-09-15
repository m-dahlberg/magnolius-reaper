-- @noindex
-- Note Leveling -- ReaImGui panel.
--
-- Two columns: the controls on the left, in the order the algorithm runs, and
-- the three displays on the right filling everything that is left. The plots
-- are the reason the panel exists -- a note list would not tell you whether
-- the clustering suits this take -- so they get the window and the controls
-- get a fixed, draggable strip. The controls can be hidden outright, which is
-- what "full screen" means here.
--
-- The pitch plot shows the f0 track with the detected notes drawn over it. The
-- level plot shows each note's RMS against the floor/ceiling window and where
-- the correction lands it. The gain plot shows the envelope that will actually
-- be written, ramps and all. Hovering any of them puts a cursor across all
-- three and reports what is under it, which is what makes a dense three minute
-- take readable without a zoom control.
--
-- Two tabs, one layout. "Notes" is part 1 -- the per-note correction that
-- writes Pre-FX. "Rider" is part 2 -- the macro ride against a reference,
-- which writes the fader. They share the splitter, the hover cursor and the
-- job driver; they do not share an Analyse, because the rider has to read the
-- reference clips as well and there is no point paying for that while tuning
-- note clustering.

local Config  = require "nl.config"
local Kernel  = require "nl.kernel"
local Analyze = require "nl.analyze"
local Cluster = require "nl.cluster"
local Level   = require "nl.level"
local Apply   = require "nl.apply"
local Rider   = require "nl.rider"
local Octave  = require "nl.octave"
local Ride    = require "nl.ride"
local Select  = require "nl.select"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  k = nil, ksig = nil,
  -- One analysis for both tabs. `data` is what the reads produced and is
  -- invalidated only by data_key; `nd` and `rd` are the two derivations over
  -- it, each recomputed when its own parameters move. `clip_idx` is shared, so
  -- both tabs are always describing the same clip.
  data = nil, data_key = nil, nd = nil, rd = nil, clip_idx = 1,
  analysed_sig = nil, derived_sig = nil,
  -- The displayed clip's, for the plots and readouts. Views onto nd[clip_idx].
  item = nil, take = nil, geo = nil, F = nil, notes = nil, points = nil,
  job = nil, jobkind = nil, progress = 0, cancel = false, on_done = nil,
  status = "Select the clips and press Analyse.", err = nil, note = nil,
  err_tab = nil,
  ride_status = "Select the reference clips and the target, then Analyse.",
  -- View state. Deliberately not in cfg: it is not a parameter of the
  -- algorithm, and cfg keys are required to belong to a parameter class.
  show_controls = true, ctrl_w = 360,
  hover_t = nil, hover_from = nil,
  tab = "notes", tab_request = nil,
}

local COL_BG     = 0x14181CFF
local COL_PITCH  = 0x4A7FB5FF
local COL_NOTE   = 0x50C878FF
local COL_NOTEF  = 0x50C87855
local COL_BAND   = 0x50C87822
local COL_EDGE   = 0x50C878FF
local COL_RMS    = 0x4A7FB5FF
local COL_GAIN   = 0xE0A050FF
local COL_CLAMP  = 0xE05050FF
local COL_GREY   = 0x808080FF
local COL_RED    = 0xE05050FF
local COL_AXIS   = 0x40484EFF
local COL_GRID   = 0x2A3036FF
local COL_CURSOR = 0xC0C8D0AA
local COL_REF    = 0x7FA8D0FF
local COL_REFF   = 0x7FA8D033
local COL_FALL   = 0xD0A040FF
local COL_HELD   = 0x606A72FF
local COL_WANT   = 0xC080D0FF
local COL_MOVED  = 0x8A5A6EFF

-- Balancing the ImGui stack across an error ----------------------------------
--
-- DeNoise wraps its frame in a pcall so one bad frame does not kill the panel.
-- That works only while the frame opens nothing. This one opens child windows
-- and disabled scopes, and a frame that throws between BeginChild and EndChild
-- leaves ImGui's stack unbalanced -- which ReaImGui raises on at the next End,
-- OUTSIDE the pcall. In REAPER that is a modal error dialog and a main thread
-- that stops answering, including to other scripts. So every Begin/End pair
-- that can straddle the failure is counted here and unwound in _frame.

local depth = { child = 0, disabled = 0 }

-- ChildFlags_Border was renamed ChildFlags_Borders in ReaImGui 0.10. This
-- script pins 0.9, where the plural name does not exist at all.
--
-- And it cannot be feature-detected with `ImGui.A or ImGui.B`: the ReaImGui
-- shim RAISES on an unknown field rather than returning nil, so the `or` never
-- gets a chance to run. Every optional symbol has to be read through pcall.
local function opt(name)
  local ok, v = pcall(function() return ImGui[name] end)
  if ok then return v end
  return nil
end

-- Same value under either name; set in _init, because ImGui is not bound yet.
local CHILD_BORDER = 0
-- Lets ST.tab_request pick a tab. Read through opt for the same reason
-- CHILD_BORDER is: an optional symbol has to be asked for, not assumed.
local TAB_SELECTED = 0

local function begin_child(id, w, h, flags)
  ImGui.BeginChild(ctx, id, w, h, flags)
  depth.child = depth.child + 1
end

-- EndChild is called whatever BeginChild returned: a collapsed or fully
-- clipped child still has to be closed.
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
  ST.jobkind, ST.progress, ST.cancel = kind, 0, false
  ST.err, ST.err_tab = nil, nil
  ST.on_done = on_done
end

local function busy() return ST.job ~= nil end

------------------------------------------------------------------------ stages

-- The kernel's memory map is fixed by the channel count and the tau range, so
-- a change in either means building a new one. The YIN threshold is not part
-- of it: it only picks a winner out of a curve the kernel has already
-- computed, so it rides along as a parameter.
local function ensure_kernel(nchan, src_rate)
  local sig = Config.kernel_sig(cfg, nchan) .. "|" .. src_rate
  if ST.k and ST.ksig == sig then
    ST.k:set_yin_threshold(cfg.yin_threshold)
    return ST.k
  end
  if ST.k then pcall(ImGui.Detach, ctx, ST.k.func) end
  local k, err = Kernel.new(ImGui, ctx, script_dir, nchan, cfg, src_rate)
  if not k then ST.k, ST.ksig = nil, nil return nil, err end
  ST.k, ST.ksig = k, sig
  return k
end

-- One analysis, both tabs -----------------------------------------------------
--
-- Analyse reads everything the panel can show: every target clip, twice each,
-- and every reference clip once. It does that whichever tab is in front, and
-- it populates both. The two tabs are two views of one take, not two tools
-- that happen to share a window -- and a button whose meaning depended on
-- which tab you happened to be looking at was the source of every selection
-- bug this panel has had.
--
-- The reads are the expensive half and are cached in ST.data. Everything
-- downstream is derived from frames already in memory, which is what lets
-- either tab's sliders redraw without touching a sample:
--
--   ST.data  the reads             invalidated only by data_key
--   ST.nd    part 1's derivation   notes and the Pre-FX envelope, per clip
--   ST.rd    part 2's derivation   segments and the ride, per clip
--
-- ST.clip_idx is shared: with several target clips both tabs show the same
-- one, because they are describing the same audio and disagreeing about which
-- clip that is would be worse than useless.

local function target_clips()
  local sel = Select.resolve(cfg)
  if sel.err then return nil, sel.err end
  if #sel.target == 0 then return nil, "No audio selected." end
  return sel
end

local function nclips() return ST.data and #ST.data.targets or 0 end

local function clip_index()
  return math.max(1, math.min(ST.clip_idx, math.max(nclips(), 1)))
end

-- Part 1's derived half, plus the view fields the plots read. Cheap enough to
-- run whenever a slider in those classes moves, which is the whole point of
-- keeping the frame tables in memory rather than the audio.
local function recompute()
  if not ST.data then return end
  ST.nd = Ride.notes_only(ST.data, cfg)
  local d = ST.nd[clip_index()]
  if d then
    ST.item, ST.take, ST.geo = d.item, d.take, d.geo
    ST.F, ST.notes, ST.points = d.F, d.notes, d.points
  end
  ST.derived_sig = Config.cluster_sig(cfg) .. "|" .. Config.level_sig(cfg)
end

-- Part 2's derived half. Same bargain, its own signature.
local function ride_recompute()
  if not ST.data then return end
  ST.rd = Ride.derive(ST.data, cfg)
end

local function ride_current()
  if not ST.rd then return nil end
  return ST.rd[math.min(clip_index(), #ST.rd)]
end

local function notes_summary()
  if not ST.F then return "Nothing analysed." end
  return string.format("%d frames, %d notes.", ST.F.n, ST.notes and #ST.notes or 0)
end

local function ride_summary()
  local d = ride_current()
  return d and Ride.describe(d, cfg) or "Nothing to ride."
end

-- `after` runs once the reads land, on the main thread. It is how the two
-- write buttons work without an Analyse first: they ask for the analysis and
-- write from inside its completion.
local function analyse(after)
  local sel, err = target_clips()
  if not sel then ST.status, ST.ride_status = err, err return end

  local key = Ride.cache_key(sel, cfg)
  ST.status, ST.ride_status = "Analysing...", "Analysing..."

  start_job("Analysing", Ride.analyse(sel, cfg, ensure_kernel, nil),
    function(data, jerr)
      if not data then
        local msg = (jerr == "cancelled") and "Cancelled." or "Failed."
        ST.status, ST.ride_status = msg, msg
        if jerr ~= "cancelled" then ST.err, ST.err_tab = jerr, ST.tab end
        return
      end
      ST.data, ST.data_key, ST.clip_idx = data, key, 1
      ST.analysed_sig = Config.analysis_sig(cfg)
      -- Both, eagerly. Deriving only the visible tab would leave the other one
      -- blank until it was looked at, which is exactly the "did the analysis
      -- happen?" question this button exists to answer.
      recompute()
      ride_recompute()
      ST.status, ST.ride_status = notes_summary(), ride_summary()
      if after then after() end
    end)
end

-- Run `after` against a current analysis, reading first only if what is in
-- hand is not for this selection under these detection settings.
local function with_analysis(after)
  local sel, err = target_clips()
  if not sel then ST.status, ST.ride_status = err, err return end
  if ST.data and ST.data_key == Ride.cache_key(sel, cfg) then after() return end
  analyse(after)
end

-- Writing --------------------------------------------------------------------

local function apply()
  with_analysis(function()
    local results = ST.nd
    if not results or #results == 0 then ST.status = "Nothing to write." return end
    local npoints, second = Apply.run(results, cfg)
    if not npoints then
      ST.err, ST.err_tab, ST.status = second, "notes", "Failed."
      return
    end
    local nnotes = 0
    for _, r in ipairs(results) do nnotes = nnotes + #r.notes end
    ST.status = string.format(
      "Wrote %d points for %d notes across %d clip%s.%s",
      npoints, nnotes, #results, #results == 1 and "" or "s",
      cfg.write_markers and string.format("  %d take markers.", second) or "")
  end)
end

local function ride_apply()
  with_analysis(function()
    if not ST.rd or #ST.rd == 0 then ST.ride_status = "Nothing to ride." return end
    local results = {}
    for _, d in ipairs(ST.rd) do
      results[#results + 1] = {
        item = d.item, take = d.take, geo = d.geo,
        points = d.points, prefx_points = d.prefx_points, segs = d.segs,
      }
    end
    local nride, npre = Apply.ride(results, cfg)
    if not nride then
      ST.err, ST.err_tab, ST.ride_status = npre, "rider", "Failed."
      return
    end
    ST.ride_status = string.format(
      "Wrote %d ride points on the fader%s.", nride,
      cfg.rider_after_notes
        and string.format(" and %d Pre-FX points", npre) or "")
  end)
end

------------------------------------------------------------------------- draw

-- Every plot shares one time axis, so hovering any of them reports the same
-- instant on all three. The hovered time is collected during the draw and
-- consumed by the next frame, which is a frame behind and invisible at 60 Hz.
local function plot(id, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, id, w, math.max(h, 1))
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, COL_BG, 4)
  return dl, x, y, ImGui.IsItemHovered(ctx)
end

-- The time axis both tabs' plots share. On the rider tab it belongs to the
-- target clip on display, which is not necessarily the item the notes tab
-- analysed.
local function span_of()
  local F = ST.F
  if ST.tab == "rider" then
    local d = ride_current()
    F = d and d.F
  end
  return (F and F.span and F.span > 0) and F.span or nil
end

-- Vertical grid with second labels, and the shared hover cursor.
local function time_grid(dl, x, y, w, h, span, hovered)
  local step = span > 120 and 30 or (span > 60 and 10 or (span > 20 and 5 or 1))
  local t = step
  while t < span do
    local gx = x + t / span * w
    ImGui.DrawList_AddLine(dl, gx, y, gx, y + h, COL_GRID, 1)
    ImGui.DrawList_AddText(dl, gx + 3, y + h - 15, COL_GREY,
      string.format("%.0fs", t))
    t = t + step
  end

  if hovered then
    local mx = ImGui.GetMousePos(ctx)
    ST.hover_t = math.max(0, math.min(span, (mx - x) / w * span))
  end
  if ST.hover_t then
    local cx = x + ST.hover_t / span * w
    ImGui.DrawList_AddLine(dl, cx, y, cx, y + h, COL_CURSOR, 1)
  end
end

local function note_at(t)
  if not ST.notes then return nil end
  for _, n in ipairs(ST.notes) do
    if t >= n.t0 and t <= n.t1 then return n end
  end
  return nil
end

-- f0 in blue with the detected notes over it as green bars at their semitone
-- centres. Unvoiced frames are simply absent, which is what makes a too-strict
-- voice gate obvious at a glance.
local function draw_pitch(w, h)
  local dl, x, y, hov = plot("##pitch", w, h)
  local span = span_of()
  if not span or not ST.notes then return end
  local F = ST.F

  local lo, hi = 84, 48
  for _, n in ipairs(ST.notes) do
    if n.midi < lo then lo = n.midi end
    if n.midi > hi then hi = n.midi end
  end
  if hi < lo then lo, hi = 48, 72 end
  lo, hi = lo - 2, hi + 2

  local function px(t) return x + t / span * w end
  local function py(m)
    local v = (m - lo) / (hi - lo)
    return y + h - math.max(0, math.min(1, v)) * (h - 2) - 1
  end

  -- With room, every semitone gets a line and every note a name. Without, only
  -- the octaves -- a grid too dense to resolve is worse than none.
  local semi_px = (h - 2) / (hi - lo)
  local step = semi_px >= 9 and 1 or 12
  for m = math.ceil(lo / step) * step, hi, step do
    local gy = py(m)
    local is_c = (m % 12 == 0)
    ImGui.DrawList_AddLine(dl, x + 28, gy, x + w, gy,
                           is_c and COL_AXIS or COL_GRID, 1)
    if is_c or step == 1 then
      ImGui.DrawList_AddText(dl, x + 3, gy - 7, COL_GREY, Cluster.note_name(m))
    end
  end

  time_grid(dl, x, y, w, h, span, hov)

  -- One vertical segment per pixel column, so 36000 frames do not become
  -- 36000 line calls.
  local function track(series, colour)
    local col, mn, mx = nil, nil, nil
    local function flush()
      if col and mn then
        ImGui.DrawList_AddLine(dl, col, py(mx), col, py(mn) + 1, colour, 1)
      end
    end
    for i = 1, F.n do
      local f = series[i]
      if f and f > 0 and Octave.voiced(F, i, cfg) then
        local m = Octave.midi(f)
        local cx = math.floor(px((i - 1) * F.hop_s))
        if cx ~= col then flush() col, mn, mx = cx, m, m
        else
          if m < mn then mn = m end
          if m > mx then mx = m end
        end
      end
    end
    flush()
  end

  -- The blue track is the one the notes were built from, so it is the repaired
  -- one. Where a frame was moved, its original reading is drawn faintly in the
  -- octave it came from -- otherwise a repair is invisible, and an octave
  -- setting that is doing something wrong looks exactly like one that is doing
  -- nothing at all.
  local f0, nmoved, moved = Octave.repair(F, cfg)
  if nmoved > 0 then
    local was = {}
    for i in pairs(moved) do was[i] = F.f0[i] end
    track(was, COL_MOVED)
  end
  track(f0, COL_PITCH)

  local bar = math.max(3, math.min(semi_px * 0.7, 14))
  for _, n in ipairs(ST.notes) do
    local gy, x0, x1 = py(n.midi), px(n.t0), px(n.t1)
    if x1 - x0 < 1 then x1 = x0 + 1 end
    ImGui.DrawList_AddRectFilled(dl, x0, gy - bar / 2, x1, gy + bar / 2,
                                 COL_NOTEF, 2)
    ImGui.DrawList_AddRect(dl, x0, gy - bar / 2, x1, gy + bar / 2,
                           COL_NOTE, 2)
    if x1 - x0 > 8 * #n.name + 6 and bar >= 11 then
      ImGui.DrawList_AddText(dl, x0 + 3, gy - 7, COL_NOTE, n.name)
    end
  end

  ImGui.DrawList_AddText(dl, x + 32, y + 3, COL_PITCH, "pitch")
  if nmoved > 0 then
    ImGui.DrawList_AddText(dl, x + 70, y + 3, COL_MOVED, "octave repaired")
  end
end

-- dB grid every 6 dB, labelled down the left gutter.
local function db_grid(dl, x, y, w, h, py, lo, hi)
  for db = math.ceil(lo / 6) * 6, hi, 6 do
    local gy = py(db)
    ImGui.DrawList_AddLine(dl, x + 34, gy, x + w, gy, COL_GRID, 1)
    ImGui.DrawList_AddText(dl, x + 3, gy - 7, COL_GREY,
                           string.format("%+.0f", db))
  end
end

-- Every note's RMS against the floor/ceiling window, with where the correction
-- lands it. A note inside the band is untouched and has no orange mark; a note
-- whose move hit the limits is marked in red.
local function draw_levels(w, h)
  local dl, x, y, hov = plot("##levels", w, h)
  local span = span_of()
  if not span or not ST.notes then return end

  local lo, hi = -60, 0
  for _, n in ipairs(ST.notes) do
    if n.rms_db < lo then lo = math.floor(n.rms_db / 6) * 6 end
    local corrected = n.rms_db + n.gain_db
    if corrected > hi then hi = math.ceil(corrected / 6) * 6 end
  end
  if cfg.floor_db < lo then lo = math.floor(cfg.floor_db / 6) * 6 - 6 end
  if cfg.ceiling_db > hi then hi = math.ceil(cfg.ceiling_db / 6) * 6 end

  local function px(t) return x + t / span * w end
  local function py(db)
    local v = (db - lo) / (hi - lo)
    return y + h - math.max(0, math.min(1, v)) * (h - 2) - 1
  end

  db_grid(dl, x, y, w, h, py, lo, hi)

  ImGui.DrawList_AddRectFilled(dl, x + 34, py(cfg.ceiling_db), x + w,
                               py(cfg.floor_db), COL_BAND)
  for _, edge in ipairs({ cfg.ceiling_db, cfg.floor_db }) do
    ImGui.DrawList_AddLine(dl, x + 34, py(edge), x + w, py(edge), COL_EDGE, 1)
  end

  time_grid(dl, x, y, w, h, span, hov)

  for _, n in ipairs(ST.notes) do
    local x0, x1 = px(n.t0), math.max(px(n.t1), px(n.t0) + 1)
    local ry = py(n.rms_db)
    if math.abs(n.gain_db) > 0.01 then
      local cy = py(n.rms_db + n.gain_db)
      local col = Level.is_clamped(n) and COL_CLAMP or COL_GAIN
      -- A connector, so the size of the move reads as a distance rather than
      -- as two unrelated marks.
      ImGui.DrawList_AddLine(dl, (x0 + x1) / 2, ry, (x0 + x1) / 2, cy, col, 1)
      ImGui.DrawList_AddLine(dl, x0, cy, x1, cy, col, 2)
    end
    ImGui.DrawList_AddLine(dl, x0, ry, x1, ry, COL_RMS, 2)
  end

  ImGui.DrawList_AddText(dl, x + 38, y + 3, COL_RMS, "note RMS")
  ImGui.DrawList_AddText(dl, x + 108, y + 3, COL_GAIN, "corrected")
  ImGui.DrawList_AddText(dl, x + 184, y + 3, COL_CLAMP, "at the limit")
end

-- The envelope exactly as it will be written, so the ramp settings can be
-- judged here rather than in the arrange view.
local function draw_gain(w, h)
  local dl, x, y, hov = plot("##gain", w, h)
  local span = span_of()
  if not span or not ST.points or #ST.points == 0 then return end

  local rng = 3
  for _, p in ipairs(ST.points) do
    if math.abs(p.db) > rng then rng = math.abs(p.db) end
  end
  rng = math.ceil(rng / 3) * 3

  local function px(t) return x + t / span * w end
  local function py(db)
    local v = (db + rng) / (2 * rng)
    return y + h - math.max(0, math.min(1, v)) * (h - 2) - 1
  end

  db_grid(dl, x, y, w, h, py, -rng, rng)
  ImGui.DrawList_AddLine(dl, x + 34, py(0), x + w, py(0), COL_AXIS, 1)
  time_grid(dl, x, y, w, h, span, hov)

  local lastx, lasty
  for _, p in ipairs(ST.points) do
    local cx, cy = px(p.t), py(p.db)
    if lastx then ImGui.DrawList_AddLine(dl, lastx, lasty, cx, cy, COL_GAIN, 2) end
    lastx, lasty = cx, cy
  end

  ImGui.DrawList_AddText(dl, x + 38, y + 3, COL_GAIN, "gain envelope")
end


--------------------------------------------------------------------- rider plots

-- One vertical segment per pixel column over a per-frame dB series, so a three
-- minute take is a few hundred line calls rather than 36000. Shared by the two
-- level lanes below.
local function draw_track(dl, series, n, x, w, px, py, col, hop)
  local cx, mn, mx = nil, nil, nil
  local function flush()
    if cx and mn then
      ImGui.DrawList_AddLine(dl, cx, py(mx), cx, py(mn) + 1, col, 1)
    end
  end
  for i = 1, n do
    local v = series[i]
    if v and v > -119 then
      local c = math.floor(px((i - 1) * hop))
      if c ~= cx then flush() cx, mn, mx = c, v, v
      else
        if v < mn then mn = v end
        if v > mx then mx = v end
      end
    end
  end
  flush()
end

local function seg_colour(s)
  if not s.gain_db then return COL_HELD end
  return s.kind == "note" and COL_NOTE or COL_FALL
end

-- What the ride was decided from: the target through the vocal band, with the
-- segmentation drawn over it. This is the lane that says whether the fallback
-- segmenter is earning its keep -- amber bars are stretches the note detector
-- had nothing to say about, and a take that is all amber is a take whose pitch
-- settings are wrong rather than one the rider cannot handle.
local function draw_ride_segments(w, h)
  local dl, x, y, hov = plot("##ridesegs", w, h)
  local span = span_of()
  local d = ride_current()
  if not span or not d then return end
  local F = d.F

  local lo, hi = -72, -6
  for _, sg in ipairs(d.segs) do
    if sg.raw_db and sg.raw_db > hi then hi = math.ceil(sg.raw_db / 6) * 6 end
  end
  if cfg.rider_gate_db < lo then lo = math.floor(cfg.rider_gate_db / 6) * 6 - 6 end

  local function px(t) return x + t / span * w end
  local function py(db)
    local v = (db - lo) / (hi - lo)
    return y + h - math.max(0, math.min(1, v)) * (h - 2) - 1
  end

  db_grid(dl, x, y, w, h, py, lo, hi)
  -- Below the gate nothing is ridden at all, so the gate is drawn as a floor
  -- rather than as a line: the shaded band is the part of the take the curve
  -- holds through.
  ImGui.DrawList_AddRectFilled(dl, x + 34, py(cfg.rider_gate_db), x + w,
                               y + h - 1, 0x30363C55)
  ImGui.DrawList_AddLine(dl, x + 34, py(cfg.rider_gate_db), x + w,
                         py(cfg.rider_gate_db), COL_HELD, 1)

  time_grid(dl, x, y, w, h, span, hov)
  draw_track(dl, F.bp_db, F.n, x, w, px, py, COL_RMS, F.hop_s)

  for _, sg in ipairs(d.segs) do
    local x0, x1 = px(sg.t0), math.max(px(sg.t1), px(sg.t0) + 1)
    local col = seg_colour(sg)
    local ty = py(sg.raw_db or lo)
    ImGui.DrawList_AddRectFilled(dl, x0, ty - 3, x1, ty + 3,
                                 sg.gain_db and COL_NOTEF or 0x60606A55, 1)
    ImGui.DrawList_AddLine(dl, x0, ty, x1, ty, col, 2)
    -- A tick at the onset, because the onset is the instant the whole design
    -- is about and a bar alone does not show which end is which.
    ImGui.DrawList_AddLine(dl, x0, ty - 5, x0, ty + 5, col, 1)
  end

  ImGui.DrawList_AddText(dl, x + 38, y + 3, COL_RMS, "target, vocal band")
  ImGui.DrawList_AddText(dl, x + 168, y + 3, COL_NOTE, "note")
  ImGui.DrawList_AddText(dl, x + 208, y + 3, COL_FALL, "fallback")
  ImGui.DrawList_AddText(dl, x + 268, y + 3, COL_HELD, "held")
end

-- The comparison the gain law is made of: the arrangement against the voice,
-- both through the same band, both reduced the same way. The two medians are
-- drawn as horizontal lines, and the distance between them IS the static term
-- the offset control sets.
local function draw_ride_levels(w, h)
  local dl, x, y, hov = plot("##ridelevels", w, h)
  local span = span_of()
  local d = ride_current()
  if not span or not d then return end
  local R, st = d.R, d.stats or {}

  local lo, hi = -66, -6
  for _, sg in ipairs(d.segs) do
    for _, v in ipairs({ sg.ref_db, sg.tgt_db }) do
      if v and v > hi then hi = math.ceil(v / 6) * 6 end
      if v and v < lo then lo = math.floor(v / 6) * 6 end
    end
  end

  local function px(t) return x + t / span * w end
  local function py(db)
    local v = (db - lo) / (hi - lo)
    return y + h - math.max(0, math.min(1, v)) * (h - 2) - 1
  end

  db_grid(dl, x, y, w, h, py, lo, hi)
  time_grid(dl, x, y, w, h, span, hov)

  if R and R.nrefs > 0 then
    draw_track(dl, R.db, R.n, x, w, px, py, COL_REFF, R.hop_s)
  end

  for _, sg in ipairs(d.segs) do
    local x0, x1 = px(sg.t0), math.max(px(sg.t1), px(sg.t0) + 1)
    if sg.ref_db then
      ImGui.DrawList_AddLine(dl, x0, py(sg.ref_db), x1, py(sg.ref_db), COL_REF, 2)
    end
    if sg.tgt_db then
      local col = sg.gain_db and COL_NOTE or COL_HELD
      ImGui.DrawList_AddLine(dl, x0, py(sg.tgt_db), x1, py(sg.tgt_db), col, 2)
    end
  end

  for _, e in ipairs({ { st.R_med, COL_REF }, { st.T_med, COL_NOTE } }) do
    if e[1] then
      ImGui.DrawList_AddLine(dl, x + 34, py(e[1]), x + w, py(e[1]), e[2], 1)
    end
  end
  if st.R_med then
    local wl = st.R_med + cfg.rider_offset_db
    ImGui.DrawList_AddLine(dl, x + 34, py(wl), x + w, py(wl), COL_WANT, 1)
  end

  ImGui.DrawList_AddText(dl, x + 38, y + 3, COL_REF, "reference")
  ImGui.DrawList_AddText(dl, x + 108, y + 3, COL_NOTE, "target")
  ImGui.DrawList_AddText(dl, x + 164, y + 3, COL_WANT, "where the vocal should sit")
end

-- The curve exactly as it will be written to the fader, with the caps drawn so
-- a ride that is pinned against one is obvious rather than merely flat.
local function draw_ride_curve(w, h)
  local dl, x, y, hov = plot("##ridecurve", w, h)
  local span = span_of()
  local d = ride_current()
  if not span or not d or #d.points == 0 then return end

  local rng = math.max(3, cfg.rider_max_boost_db, cfg.rider_max_cut_db)
  for _, p in ipairs(d.points) do
    if math.abs(p.db) > rng then rng = math.abs(p.db) end
  end
  rng = math.ceil(rng / 3) * 3

  local function px(t) return x + t / span * w end
  local function py(db)
    local v = (db + rng) / (2 * rng)
    return y + h - math.max(0, math.min(1, v)) * (h - 2) - 1
  end

  db_grid(dl, x, y, w, h, py, -rng, rng)
  ImGui.DrawList_AddLine(dl, x + 34, py(0), x + w, py(0), COL_AXIS, 1)
  for _, cap in ipairs({ cfg.rider_max_boost_db + cfg.rider_trim_db,
                         -cfg.rider_max_cut_db + cfg.rider_trim_db }) do
    ImGui.DrawList_AddLine(dl, x + 34, py(cap), x + w, py(cap), COL_CLAMP, 1)
  end
  time_grid(dl, x, y, w, h, span, hov)

  local lastx, lasty
  for _, p in ipairs(d.points) do
    local cx, cy = px(p.t), py(p.db)
    if lastx then ImGui.DrawList_AddLine(dl, lastx, lasty, cx, cy, COL_GAIN, 2) end
    lastx, lasty = cx, cy
  end

  -- A mark at every onset the curve was aimed at. Seeing the curve already
  -- flat when the mark arrives is the whole claim this feature makes, and it
  -- is the one thing a gain plot alone will not tell you.
  for _, sg in ipairs(d.segs) do
    if sg.gain_db then
      local cx = px(sg.t0)
      ImGui.DrawList_AddLine(dl, cx, y + h - 8, cx, y + h - 1, seg_colour(sg), 1)
    end
  end

  ImGui.DrawList_AddText(dl, x + 38, y + 3, COL_GAIN, "ride, post-FX")
  ImGui.DrawList_AddText(dl, x + 132, y + 3, COL_CLAMP, "caps")
end

local function seg_at(t)
  local d = ride_current()
  if not d then return nil end
  for _, sg in ipairs(d.segs) do
    if t >= sg.t0 and t <= sg.t1 then return sg end
  end
  return nil
end

local function ride_plots()
  local w, h = ImGui.GetContentRegionAvail(ctx)
  if w < 40 or h < 60 then return end
  local gap = 6
  local usable = h - 2 * gap
  draw_ride_segments(w, usable * 0.36)
  ImGui.Dummy(ctx, 1, gap)
  draw_ride_levels(w, usable * 0.34)
  ImGui.Dummy(ctx, 1, gap)
  draw_ride_curve(w, usable * 0.30)

  if ST.hover_t then
    local sg = seg_at(ST.hover_t)
    local txt = string.format("%.3f s", ST.hover_t)
    if sg then
      txt = txt .. string.format("   %s  target %.1f", sg.kind, sg.tgt_db or 0)
      if sg.pre_db and math.abs(sg.pre_db) > 0.01 then
        txt = txt .. string.format(" (%.1f %+.1f pre)", sg.raw_db, sg.pre_db)
      end
      if sg.ref_db then txt = txt .. string.format("   reference %.1f", sg.ref_db) end
      txt = txt .. (sg.gain_db
        and string.format("   ride %+.2f dB%s", sg.gain_db,
                          sg.clamped and "  (at a cap)" or "")
        or (sg.no_ref and "   held -- no reference here" or "   held -- below the gate"))
    else
      txt = txt .. "   -- holding --"
    end
    local d = ride_current()
    if d and #d.points > 0 then
      txt = txt .. string.format("   curve %+.2f dB",
        Rider.value_at(d.points, ST.hover_t))
    end
    ImGui.TextDisabled(ctx, txt)
  end
end

local function plots()
  local w, h = ImGui.GetContentRegionAvail(ctx)
  if w < 40 or h < 60 then return end
  local gap = 6
  local usable = h - 2 * gap
  draw_pitch(w, usable * 0.42)
  ImGui.Dummy(ctx, 1, gap)
  draw_levels(w, usable * 0.34)
  ImGui.Dummy(ctx, 1, gap)
  draw_gain(w, usable * 0.24)

  -- The readout for whatever the cursor is on, shared by all three plots.
  if ST.hover_t then
    local n = note_at(ST.hover_t)
    local txt = string.format("%.3f s", ST.hover_t)
    if n then
      txt = txt .. string.format("   %s  %+.0f cents   RMS %.1f dB   gain %+.2f dB%s",
        n.name, n.cents, n.rms_db, n.gain_db,
        Level.is_clamped(n) and "  (at the limit)" or "")
    else
      txt = txt .. "   -- no note --"
    end
    if ST.points then
      txt = txt .. string.format("   envelope %+.2f dB",
        Level.value_at(ST.points, ST.hover_t))
    end
    ImGui.TextDisabled(ctx, txt)
  end
end

--------------------------------------------------------------------- controls

local function slider(label, key, lo, hi, fmt)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, fmt or "%.1f")
  if rv then cfg[key] = v end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
  return rv
end

-- Same contract as slider: the key is named once, as a string, so the panel
-- coverage scan in headless.lua can see it.
local function input_int(label, key, lo)
  local rv, v = ImGui.InputInt(ctx, label, cfg[key], 1, 1)
  if rv then
    cfg[key] = math.max(lo or 0, math.floor(v))
    Config.save(cfg)
  end
  return rv
end

local function checkbox(label, key)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then cfg[key] = v Config.save(cfg) end
  return rv
end

local function controls()
  ImGui.PushItemWidth(ctx, -120)

  ImGui.SeparatorText(ctx, "Pitch detection")
  ImGui.TextDisabled(ctx, "Changing these re-reads the audio.")
  slider("Sampling distance", "hop_ms", 1, 20, "%.1f ms")
  slider("Lowest pitch", "min_hz", 40, 200, "%.0f Hz")
  slider("Highest pitch", "max_hz", 300, 1200, "%.0f Hz")
  slider("Analysis rate", "pitch_rate", 6000, 16000, "%.0f Hz")
  slider("Voiced threshold", "yin_threshold", 0.02, 0.60, "%.2f")
  if ST.F and ST.analysed_sig ~= Config.analysis_sig(cfg) then
    ImGui.TextColored(ctx, COL_GAIN, "Changed -- press Analyse.")
  end

  ImGui.SeparatorText(ctx, "Notes")
  slider("Voice gate", "voice_gate_db", -90, -20, "%.0f dB")
  checkbox("Repair octave jumps", "octave_fix")
  if cfg.octave_fix then
    slider("Believe an octave after", "octave_hold_ms", 100, 5000, "%.0f ms")
    slider("Link across gaps up to", "octave_link_ms", 0, 1000, "%.0f ms")
    ImGui.TextDisabled(ctx, "A shorter octave change is a detection")
    ImGui.TextDisabled(ctx, "error; a longer one is the melody.")
    slider("Trust pitches within", "octave_range", 6, 36, "%.0f semitones")
    ImGui.TextDisabled(ctx, "...of the take's own median. Further out,")
    ImGui.TextDisabled(ctx, "the octave is doubted however long it")
    ImGui.TextDisabled(ctx, "lasts. 36 turns that off.")
    if ST.F then
      local _, nmoved = Octave.repair(ST.F, cfg)
      if nmoved > 0 then
        ImGui.Text(ctx, string.format("-> %d frame%s moved an octave",
          nmoved, nmoved == 1 and "" or "s"))
      else
        ImGui.TextDisabled(ctx, "-> nothing needed moving")
      end
    end
  end
  slider("Pitch tolerance", "tolerance_cents", 10, 100, "%.0f cents")
  slider("Minimum note", "min_note_ms", 20, 500, "%.0f ms")
  slider("Bridge gaps up to", "max_gap_ms", 0, 1000, "%.0f ms")
  slider("Gap silence below", "silence_db", -60, -10, "%.0f dB")
  slider("Absorb wobble under", "wobble_ms", 0, 400, "%.0f ms")
  if ST.notes then ImGui.Text(ctx, string.format("-> %d notes", #ST.notes)) end

  ImGui.SeparatorText(ctx, "Leveling")
  slider("Floor", "floor_db", -60, 0, "%.1f dB")
  slider("Ceiling", "ceiling_db", -60, 0, "%.1f dB")
  slider("Amount", "amount", 0, 100, "%.0f %%")
  slider("Max boost", "max_boost_db", 0, 24, "%.1f dB")
  slider("Max cut", "max_cut_db", 0, 24, "%.1f dB")
  if cfg.floor_db > cfg.ceiling_db then
    ImGui.TextColored(ctx, COL_GAIN, "Floor is above the ceiling.")
  end
  if ST.notes then
    local up, down, worst, capped = 0, 0, 0, 0
    for _, n in ipairs(ST.notes) do
      if n.gain_db > 0.01 then up = up + 1
      elseif n.gain_db < -0.01 then down = down + 1 end
      if math.abs(n.gain_db) > math.abs(worst) then worst = n.gain_db end
      if Level.is_clamped(n) then capped = capped + 1 end
    end
    ImGui.Text(ctx, string.format("-> %d raised, %d lowered, largest %+.1f dB",
      up, down, worst))
    if capped > 0 then
      ImGui.TextColored(ctx, COL_CLAMP,
        string.format("%d note%s held at the limit", capped,
                      capped == 1 and "" or "s"))
    end
  end

  ImGui.SeparatorText(ctx, "Envelope")
  checkbox("Glide between notes", "glide_notes")
  if cfg.glide_notes then
    ImGui.TextDisabled(ctx, "The gain never returns to unity: it runs")
    ImGui.TextDisabled(ctx, "straight from one note to the next, and the")
    ImGui.TextDisabled(ctx, "outer notes hold to the clip edges. Use it")
    ImGui.TextDisabled(ctx, "when cutting two notes has left the breath")
    ImGui.TextDisabled(ctx, "between them the loudest thing in the phrase.")
  end
  begin_disabled(cfg.glide_notes)
  slider("Ramp in", "ramp_in_ms", 0, 500, "%.0f ms")
  slider("Ramp out", "ramp_out_ms", 0, 500, "%.0f ms")
  end_disabled()
  slider("Point spacing", "ramp_res_ms", 1, 50, "%.0f ms")
  if not cfg.glide_notes then
    ImGui.TextDisabled(ctx, "A gap shorter than ramp in + ramp out")
    ImGui.TextDisabled(ctx, "becomes a direct note-to-note transition.")
  end

  ImGui.SeparatorText(ctx, "Output")
  checkbox("Write take markers per note", "write_markers")
  if cfg.write_markers then
    ImGui.TextDisabled(ctx, "Replaces any take markers already on the take.")
  end
  ImGui.TextColored(ctx, COL_GAIN, "Apply clears the whole")
  ImGui.TextColored(ctx, COL_GAIN, "Pre-FX volume envelope.")

  -- Say which clips this will touch, in the same words the Rider tab uses.
  -- With a rider-shaped selection -- backing tracks selected alongside the
  -- vocal -- "3 items selected" was actively misleading: it was true, and it
  -- was not what the button was about to do.
  local sel = Select.resolve(cfg)
  if sel.err then
    ImGui.TextDisabled(ctx, sel.err)
  else
    local _, tname = reaper.GetSetMediaTrackInfo_String(sel.track, "P_NAME", "", false)
    if tname == "" then tname = "track " .. sel.track_num end
    ImGui.TextDisabled(ctx, string.format("%d clip%s on %s",
      #sel.target, #sel.target == 1 and "" or "s", tname))
    if #sel.refs > 0 then
      ImGui.TextDisabled(ctx, string.format(
        "%d other selected clip%s ignored here.",
        #sel.refs, #sel.refs == 1 and " is" or "s are"))
    end
  end

  begin_disabled(sel.err ~= nil or busy())
  if ImGui.Button(ctx, "Write Pre-FX automation", -1, 0) then apply() end
  end_disabled()

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Reset settings", -1, 0) then
    Config.reset(cfg)
    recompute()
  end

  ImGui.PopItemWidth(ctx)
end


---------------------------------------------------------------- rider controls

local function ride_controls()
  ImGui.PushItemWidth(ctx, -120)

  ImGui.SeparatorText(ctx, "Clips")
  -- Re-read every frame, not cached. The panel is a window the user clicks
  -- past, and a rider whose idea of "the target" was whatever happened to be
  -- selected when it opened would be a trap.
  ImGui.TextWrapped(ctx, Select.describe(Select.resolve(cfg)))
  ImGui.TextDisabled(ctx, "Analyse reads all of them and fills in both tabs.")
  ImGui.TextDisabled(ctx, "The target is the selected audio on the")
  ImGui.TextDisabled(ctx, "highest-numbered track; the rest is reference.")
  input_int("Target track", "rider_target_track", 0)
  ImGui.TextDisabled(ctx, "0 = auto. Set it for a headless run.")

  ImGui.SeparatorText(ctx, "Balance")
  slider("Offset", "rider_offset_db", -24, 24, "%.1f dB")
  local d = ride_current()
  begin_disabled(not d)
  if ImGui.Button(ctx, "Match the balance the mix already has", -1, 0) and d then
    local off = Rider.match_offset(d.segs)
    if off then cfg.rider_offset_db = off Config.save(cfg) ride_recompute() end
  end
  end_disabled()
  if d and d.stats and d.stats.T_med then
    ImGui.Text(ctx, string.format("vocal %.1f   reference %s",
      d.stats.T_med, d.stats.R_med and string.format("%.1f dB", d.stats.R_med)
                     or "--"))
    ImGui.TextColored(ctx,
      math.abs(d.stats.static_db) > math.max(cfg.rider_max_boost_db,
                                             cfg.rider_max_cut_db)
        and COL_CLAMP or COL_GREY,
      string.format("static term %+.1f dB", d.stats.static_db))
  end

  ImGui.SeparatorText(ctx, "Ride")
  slider("Follow the reference", "rider_ref_follow", 0, 100, "%.0f %%")
  slider("Level the vocal", "rider_tgt_level", 0, 100, "%.0f %%")
  ImGui.TextDisabled(ctx, "Follow tracks the arrangement. Level is what")
  ImGui.TextDisabled(ctx, "lifts a soft phrase further than a loud one.")
  slider("Max boost", "rider_max_boost_db", 0, 24, "%.1f dB")
  slider("Max cut", "rider_max_cut_db", 0, 24, "%.1f dB")

  ImGui.SeparatorText(ctx, "Measurement")
  slider("Reference window", "rider_ref_window_ms", 50, 2000, "%.0f ms")
  slider("Target window", "rider_tgt_window_ms", 50, 2000, "%.0f ms")
  slider("Longest held level", "rider_seg_max_ms", 0, 3000, "%.0f ms")
  slider("Ride only above", "rider_gate_db", -90, -20, "%.0f dB")
  ImGui.TextDisabled(ctx, "Both windows start at the onset. Below the")
  ImGui.TextDisabled(ctx, "gate the curve holds instead of lifting.")

  ImGui.SeparatorText(ctx, "Motion")
  slider("Smoothing", "rider_smooth_ms", 0, 5000, "%.0f ms")
  slider("Speed", "rider_speed_db_s", 1, 60, "%.0f dB/s")
  slider("Look ahead", "rider_lookahead_ms", 0, 300, "%.0f ms")
  slider("Transition", "rider_trans_ms", 5, 500, "%.0f ms")
  slider("Point spacing", "rider_point_ms", 5, 50, "%.0f ms")
  ImGui.TextDisabled(ctx, "Look ahead is how long before a word the")
  ImGui.TextDisabled(ctx, "move is already finished.")

  ImGui.SeparatorText(ctx, "Output")
  slider("Trim", "rider_trim_db", -12, 12, "%.1f dB")
  checkbox("Also write the Pre-FX note leveling", "rider_after_notes")
  ImGui.TextDisabled(ctx, cfg.rider_after_notes
    and "The ride was planned for the note-leveled"
     or "The ride is planned for the raw take.")
  if cfg.rider_after_notes then
    ImGui.TextDisabled(ctx, "vocal, so both are written together.")
  end
  ImGui.TextColored(ctx, COL_GAIN, "Clears the fader envelope over these")
  ImGui.TextColored(ctx, COL_GAIN, "clips only, not the whole track.")

  -- Gated on the selection, not on having analysed: the write asks for an
  -- analysis and does its work from inside the completion, so pressing it
  -- first is a longer wait rather than an error.
  local sel = Select.resolve(cfg)
  begin_disabled(sel.err ~= nil or busy())
  if ImGui.Button(ctx, "Write the ride", -1, 0) then ride_apply() end
  end_disabled()

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Reset settings", -1, 0) then
    Config.reset(cfg)
    recompute()
    ride_recompute()
  end

  ImGui.PopItemWidth(ctx)
end

------------------------------------------------------------------------ frame

local function frame()
  step_job()

  -- Cluster and level parameters only re-derive from frames already in hand,
  -- so they never need a button: notice the signature moved and redo the
  -- cheap half.
  if ST.data and ST.derived_sig
     and ST.derived_sig ~= Config.cluster_sig(cfg) .. "|" .. Config.level_sig(cfg) then
    recompute()
  end
  -- The rider's derived half depends on the note leveling as well as on its
  -- own controls, because the Pre-FX gains are part of what it plans against.
  -- Only while the rider is actually showing, though: Ride.sig includes the
  -- LEVEL keys, so without the tab check every drag of the floor or ceiling
  -- slider on the Notes tab re-derived the whole ride -- clustering, segments,
  -- smoothing and curve for every target clip -- once per frame, to redraw
  -- something nobody was looking at.
  if ST.tab == "rider" and ST.data and ST.rd
     and ST.rd.sig ~= Ride.sig(cfg) then
    ride_recompute()
  end

  -- One button, one meaning, whichever tab is in front: read everything that
  -- is selected and fill in both tabs.
  begin_disabled(busy())
  if ImGui.Button(ctx, "Analyse", 110, 0) then analyse() end
  end_disabled()
  ImGui.SameLine(ctx)

  local rv, v = ImGui.Checkbox(ctx, "Controls", ST.show_controls)
  if rv then ST.show_controls = v end
  ImGui.SameLine(ctx)

  -- With several target clips, an arrow pair picks which one both tabs show.
  -- Shared rather than per tab: they are two views of one clip, and letting
  -- them drift onto different clips would make every cross-tab reading wrong.
  if nclips() > 1 then
    local i = clip_index()
    begin_disabled(i <= 1)
    if ImGui.Button(ctx, "<##clip", 24, 0) then
      ST.clip_idx = i - 1 recompute() ride_recompute()
    end
    end_disabled()
    ImGui.SameLine(ctx)
    begin_disabled(i >= nclips())
    if ImGui.Button(ctx, ">##clip", 24, 0) then
      ST.clip_idx = i + 1 recompute() ride_recompute()
    end
    end_disabled()
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, string.format("clip %d of %d", i, nclips()))
    ImGui.SameLine(ctx)
  end

  if ST.take then
    local _, name = reaper.GetSetMediaItemTakeInfo_String(ST.take, "P_NAME", "", false)
    ImGui.Text(ctx, string.format("%s   %.2f s   %d ch   %d Hz   playrate %.3f   %s",
      name, ST.geo.item_len, ST.geo.nchan, ST.geo.rate, ST.geo.playrate,
      ST.tab == "rider" and ST.ride_status or ST.status))
  else
    ImGui.Text(ctx, ST.tab == "rider" and ST.ride_status or ST.status)
  end

  if busy() then
    -- One bar across all the clips, not one per clip. Ride.analyse scales each
    -- clip's progress into its own slice of 0..1, so a three clip run counts
    -- up once instead of three times -- which is what the old per-item loop
    -- looked like, and read as the panel having hung.
    ImGui.ProgressBar(ctx, ST.progress, -1, 0,
      string.format("%s  %.0f%%", ST.jobkind, ST.progress * 100))
    if ImGui.Button(ctx, "Cancel", 100, 0) then ST.cancel = true end
  end
  -- Errors belong to the tab whose job raised them. Showing the rider's
  -- failure in red at the top of the Notes tab reads as "the note leveling is
  -- broken", which is how a panel teaches you the wrong thing.
  if ST.err and ST.err_tab == ST.tab then
    ImGui.TextColored(ctx, COL_RED, ST.err)
  end

  -- The tab bar selects which stage the columns below are showing. The columns
  -- themselves stay out here: the splitter, the hover cursor and the job
  -- driver are shared, and nesting them per tab would fork all three.
  -- ImGui owns which tab is active, and it reports that by returning true from
  -- exactly one BeginTabItem -- so ST.tab is written FROM the tab bar every
  -- frame, never to it. Setting ST.tab from outside looks like it works and is
  -- silently undone on the next frame, which is why selecting a tab has to be
  -- a request the bar honours rather than an assignment.
  if ImGui.BeginTabBar(ctx, "##tabs") then
    for _, t in ipairs({ { "Notes", "notes" }, { "Rider", "rider" } }) do
      local flags = (ST.tab_request == t[2]) and TAB_SELECTED or 0
      if ImGui.BeginTabItem(ctx, t[1], nil, flags) then
        ST.tab = t[2]
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
    -- Held until it is honoured, not cleared on sight. ImGui applies
    -- SetSelected when it next lays the bar out, which is generally the
    -- following frame, so a request dropped after one pass is a request that
    -- usually does nothing.
    if ST.tab_request == ST.tab then ST.tab_request = nil end
  end

  -- The hovered instant is recollected every frame; clear it before the plots
  -- run so letting go of the mouse drops the cursor rather than freezing it.
  ST.hover_t = nil

  local _, bodyh = ImGui.GetContentRegionAvail(ctx)
  begin_disabled(busy())
  if ST.show_controls then
    -- ResizeX puts a drag handle on the splitter.
    begin_child("##controls", ST.ctrl_w, bodyh,
                CHILD_BORDER | ImGui.ChildFlags_ResizeX)
    if ST.tab == "rider" then ride_controls() else controls() end
    end_child()
    ImGui.SameLine(ctx)
  end
  end_disabled()

  begin_child("##plots", 0, bodyh, CHILD_BORDER)
  if ST.tab == "rider" then ride_plots() else plots() end
  end_child()
end

-- Everything start() does except enter the defer loop. Split out so a test can
-- drive one frame against a stub: the panel is otherwise the only file the
-- suites cannot execute, and it is where a renamed config key lands -- as a
-- nil read that errors the frame and takes the whole panel below it with it.
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  CHILD_BORDER = opt("ChildFlags_Borders") or opt("ChildFlags_Border") or 0
  TAB_SELECTED = opt("TabItemFlags_SetSelected") or 0
  cfg = Config.load()
  ctx = ImGui.CreateContext("Note Leveling")
  -- cfg goes back with it so a test can render a layout that only exists under
  -- a particular setting -- the glide branch of the Envelope section hides two
  -- sliders and shows five lines of help, and _init loads from ExtState, so
  -- there is otherwise no way for a suite to reach that arrangement.
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

function M.start(imgui, dir)
  M._init(imgui, dir)

  local function loop()
    ImGui.SetNextWindowSize(ctx, 1280, 820, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Note Leveling", true)
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
