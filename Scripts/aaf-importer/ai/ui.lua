-- @noindex
-- AAF Importer -- ReaImGui panel.
--
-- Laid out in the order you use it: open a file, pick a track from the list,
-- check its curve in the preview, tick what to import, then apply it to the
-- selected REAPER track or insert it as a new one.
--
-- Nothing here is slow -- a file is read in tens of milliseconds -- so there
-- is no job, no cache key and no Analyse button: opening a file reads it, and
-- every control acts at once.

local Config = require "ai.config"
local Model  = require "ai.model"
local Apply  = require "ai.apply"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  model = nil,       -- what Model.load returned
  sel = nil,         -- index into model.tracks
  status = "Open a Pro Tools AAF export to list its tracks.",
  err = nil, warn = nil,
  span = nil,        -- {first, last} project times of the last import's points
}

local COL_BG     = 0x14181CFF
local COL_GRID   = 0x2A3036FF
local COL_GREY   = 0x808080FF
local COL_RED    = 0xE05050FF
local COL_AMBER  = 0xE0A050FF
local COL_GREEN  = 0x50C878FF
local COL_VOL    = 0xF0A040FF
local COL_PAN    = 0x4A9FD5FF
local COL_ZERO   = 0xC0C8D060

-- Balancing the ImGui stack across an error: a frame that throws between a
-- Begin* and its End* leaves the stack open, and ReaImGui raises on that at
-- the next End -- outside any pcall, as a modal dialog. So every pair that can
-- straddle a failure is counted and unwound in _frame.
local depth = { child = 0, disabled = 0, table_ = 0 }

local function opt(name)
  local ok, v = pcall(function() return ImGui[name] end)
  if ok then return v end
  return nil
end

local HAVE_SEPTEXT = false

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

local function begin_table(id, ncol, flags, w, h)
  if ImGui.BeginTable(ctx, id, ncol, flags, w, h) then
    depth.table_ = depth.table_ + 1
    return true
  end
  return false
end

local function end_table()
  if depth.table_ > 0 then
    depth.table_ = depth.table_ - 1
    ImGui.EndTable(ctx)
  end
end

local function section(title)
  ImGui.Dummy(ctx, 1, 4)
  if HAVE_SEPTEXT then
    ImGui.SeparatorText(ctx, title)
  else
    ImGui.Separator(ctx)
    ImGui.TextColored(ctx, COL_GREY, title)
  end
end

local function help(text)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, COL_GREY, text)
  ImGui.PopTextWrapPos(ctx)
end

local function checkbox(label, key)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then
    cfg[key] = v
    Config.save(cfg)
  end
  return rv
end

------------------------------------------------------------------------ file

local function basename(p) return (p:match("[^/\\]+$") or p) end

-- Reads `path` into ST. Keeps the previous file if this one fails.
function M.load(path)
  local res, err = Model.load(path)
  ST.err, ST.warn, ST.span = nil, nil, nil
  if not res then
    ST.err = err
    ST.status = "Could not open " .. basename(path) .. "."
    return false
  end
  ST.model = res
  ST.sel = (#res.tracks > 0) and 1 or nil
  cfg.last_path = path
  Config.save(cfg)
  ST.status = string.format("%s: %d track%s.", basename(path), #res.tracks,
                            #res.tracks == 1 and "" or "s")
  if #res.warnings > 0 then ST.warn = table.concat(res.warnings, " ") end
  return true
end

local function browse()
  local dir = cfg.last_path:match("^(.*[/\\])") or ""
  if reaper.JS_Dialog_BrowseForOpenFiles then
    local rv, file = reaper.JS_Dialog_BrowseForOpenFiles(
      "Open AAF", dir, "", "AAF files (*.aaf)\0*.aaf\0All files (*.*)\0*.*\0", false)
    if rv == 1 and file and file ~= "" then M.load(file) end
  else
    local rv, file = reaper.GetUserFileNameForRead(cfg.last_path, "Open AAF", "aaf")
    if rv and file ~= "" then M.load(file) end
  end
end

------------------------------------------------------------------- sections

local function file_section()
  if ImGui.Button(ctx, "Open AAF...") then browse() end
  ImGui.SameLine(ctx)
  begin_disabled(not ST.model)
  if ImGui.Button(ctx, "Reload") then M.load(ST.model.path) end
  end_disabled()
  local m = ST.model
  if m then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, basename(m.path))
    local bits = {}
    if m.tool and m.tool.product then
      bits[#bits + 1] = m.tool.product .. (m.tool.version and (" " .. m.tool.version) or "")
    end
    if m.name and m.name ~= "" then bits[#bits + 1] = string.format("%q", m.name) end
    if m.tc then bits[#bits + 1] = string.format("TC %s @ %d fps", m.tc.label, m.tc.fps) end
    local t1 = m.tracks[1]
    if t1 then bits[#bits + 1] = string.format("%g Hz", t1.rate_num / t1.rate_den) end
    ImGui.TextColored(ctx, COL_GREY, table.concat(bits, "   "))
  end
end

local function track_table(h)
  local m = ST.model
  if not m then
    help("No file open.")
    return
  end
  if #m.tracks == 0 then
    ImGui.TextColored(ctx, COL_AMBER, "This AAF has no audio tracks.")
    return
  end
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
              | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
  if begin_table("##tracks", 4, flags, 0, h) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableSetupColumn(ctx, "#", ImGui.TableColumnFlags_WidthFixed, 28)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "Volume", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "Pan", ImGui.TableColumnFlags_WidthStretch, 1.4)
    ImGui.TableHeadersRow(ctx)
    for i, tr in ipairs(m.tracks) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      if ImGui.Selectable(ctx, tostring(tr.track_no or i) .. "##row" .. i, ST.sel == i,
                          ImGui.SelectableFlags_SpanAllColumns) then
        ST.sel = i
      end
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, (tr.name ~= "" and tr.name or "(unnamed)")
                      .. ((m.comps > 1 and tr.mob ~= "") and ("  [" .. tr.mob .. "]") or ""))
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, Model.describe(tr.volume, "volume"))
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, Model.describe(tr.pan, "pan"))
    end
    end_table()
  end
end

local function fmt_time(t)
  local mnt = math.floor(t / 60)
  return string.format("%d:%04.1f", mnt, t - mnt * 60)
end

-- The picked track's volume (dB, -48..+12) and pan (L top, R bottom), drawn
-- with the shape REAPER will draw: steps where the AAF says constant.
local DB_LO, DB_HI = -48, 12
local function preview(w, h)
  local m = ST.model
  local tr = m and ST.sel and m.tracks[ST.sel]
  local dl = ImGui.GetWindowDrawList(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, COL_BG)
  ImGui.Dummy(ctx, w, h)
  if not tr then return end
  local span = math.max(tr.length_s, 1e-3)
  local V, A = tr.volume, tr.pan
  if V then span = math.max(span, V.t1) end
  if A then span = math.max(span, A.t1) end

  local vh = A and h * 0.68 or h
  local function X(t) return x0 + 4 + (w - 8) * t / span end
  local function Yv(g)
    local d = math.max(DB_LO, math.min(DB_HI, Model.db(g)))
    return y0 + 4 + (vh - 8) * (DB_HI - d) / (DB_HI - DB_LO)
  end
  local function Yp(p) return y0 + vh + 4 + (h - vh - 8) * (p + 1) / 2 end

  for d = DB_HI, DB_LO, -12 do
    local y = Yv(10 ^ (d / 20))
    ImGui.DrawList_AddLine(dl, x0, y, x0 + w, y, d == 0 and COL_ZERO or COL_GRID, 1)
    ImGui.DrawList_AddText(dl, x0 + 4, y - 14, COL_GREY, string.format("%+d", d))
  end
  if A then
    ImGui.DrawList_AddLine(dl, x0, y0 + vh, x0 + w, y0 + vh, COL_GRID, 1)
    local yc = Yp(0)
    ImGui.DrawList_AddLine(dl, x0, yc, x0 + w, yc, COL_ZERO, 1)
    ImGui.DrawList_AddText(dl, x0 + 4, y0 + vh + 2, COL_GREY, "L")
    ImGui.DrawList_AddText(dl, x0 + 4, y0 + h - 16, COL_GREY, "R")
  end

  local function draw(lane, Y, col)
    local pts = lane.points
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      if a.shape == Model.SHAPE_SQUARE then
        ImGui.DrawList_AddLine(dl, X(a.t), Y(a.v), X(b.t), Y(a.v), col, 2)
        ImGui.DrawList_AddLine(dl, X(b.t), Y(a.v), X(b.t), Y(b.v), col, 2)
      else
        ImGui.DrawList_AddLine(dl, X(a.t), Y(a.v), X(b.t), Y(b.v), col, 2)
      end
    end
    if #pts == 1 then
      ImGui.DrawList_AddCircleFilled(dl, X(pts[1].t), Y(pts[1].v), 3, col)
    end
  end
  if V then draw(V, Yv, COL_VOL) end
  if A then draw(A, Yp, COL_PAN) end
  ImGui.DrawList_AddText(dl, x0 + w - 70, y0 + 4, COL_GREY, fmt_time(span))
  if not V and not A then
    ImGui.DrawList_AddText(dl, x0 + 40, y0 + h / 2 - 7, COL_GREY,
      "No volume or pan in this track -- only its name can be imported.")
  end
end

local function selected_track()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then return nil end
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  return tr, string.format("%d: %s", num, name ~= "" and name or "(unnamed)")
end

local function arrange_view()
  return reaper.GetSet_ArrangeView2(0, false, 0, 0)
end

-- When the lane first moves away from its opening value, in AAF seconds, or
-- nil. Pro Tools lanes often sit flat for a long stretch, which on a zoomed-in
-- view reads as "only one point was written".
local function first_move(pts)
  if not pts or #pts < 2 then return nil end
  local d0 = Model.db(pts[1].v)
  for i = 2, #pts do
    if math.abs(Model.db(pts[i].v) - d0) > 0.01 then return pts[i - 1].t end
  end
end

local function report(ok, p_or_err, warn, verb, tr, off)
  if not ok then
    ST.err, ST.warn, ST.span = p_or_err, nil, nil
    ST.status = "Nothing was changed."
    return
  end
  local p = p_or_err
  ST.err, ST.span = nil, p.span
  ST.status = verb .. ": " .. table.concat(p.what, ", ") .. "."
  local notes = {}
  if p.span then
    ST.status = ST.status .. string.format(" Points from %s to %s.",
                                           fmt_time(p.span[1]), fmt_time(p.span[2]))
    local vs, ve = arrange_view()
    local plen = reaper.GetProjectLength(0)
    if plen > 0 and p.span[1] >= plen then
      notes[#notes + 1] = string.format(
        "They start after the end of the project (%s), because of the placement. "
        .. "Undo, set Placement to \"%s\" and import again.",
        fmt_time(plen), Config.PLACEMENT_LABELS.zero)
    elseif p.span[2] < vs or p.span[1] > ve then
      notes[#notes + 1] = string.format(
        "None of the points is on screen: the arrange view shows %s to %s. "
        .. "Use Show in arrange to go to them.", fmt_time(vs), fmt_time(ve))
    end
    local mv = p.vol_pts and first_move(p.vol_pts)
    if mv and mv > 0 and tr then
      notes[#notes + 1] = string.format("The volume holds %s until %s, then starts to move.",
                                        Model.fmt_db(p.vol_pts[1].v), fmt_time(mv + off))
    end
  end
  if warn then notes[#notes + 1] = warn end
  ST.warn = #notes > 0 and table.concat(notes, " ") or nil
end

local function import_section()
  local m = ST.model
  local tr = m and ST.sel and m.tracks[ST.sel]

  checkbox("Name", "imp_name")
  ImGui.SameLine(ctx)
  checkbox("Volume", "imp_volume")
  ImGui.SameLine(ctx)
  checkbox("Pan", "imp_pan")
  ImGui.SameLine(ctx)
  checkbox("Automation", "imp_automation")
  help("Volume and Pan set the fader. A lane that never moves goes to the fader only; "
    .. "one that moves is written as an envelope when Automation is ticked "
    .. "(the fader then sits at 0 dB / centre), or as its opening value when it is not. "
    .. "An existing envelope keeps its points outside the imported span.")

  local items = {}
  for _, k in ipairs(Config.PLACEMENTS) do items[#items + 1] = Config.PLACEMENT_LABELS[k] end
  ImGui.SetNextItemWidth(ctx, 340)
  local rv, idx = ImGui.Combo(ctx, "Placement", Config.placement_index(cfg) - 1,
                              table.concat(items, "\0") .. "\0")
  if rv then
    cfg.placement = Config.PLACEMENTS[idx + 1] or Config.defaults.placement
    Config.save(cfg)
  end
  local off, oerr = Apply.offset(cfg, m)
  if oerr then
    ImGui.TextColored(ctx, COL_RED, oerr)
  elseif m then
    local vs, ve = arrange_view()
    local plen = reaper.GetProjectLength(0)
    local s = string.format("The AAF's first sample lands at %s in the project.", fmt_time(off))
    local extra
    if plen > 0 and off >= plen then
      extra = string.format(" That is past the end of the project (%s). To start at 0:00, "
                            .. "pick \"%s\".", fmt_time(plen), Config.PLACEMENT_LABELS.zero)
    elseif off < vs or off > ve then
      extra = " That is off screen at the moment."
    end
    if extra then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextColored(ctx, COL_AMBER, s .. extra)
      ImGui.PopTextWrapPos(ctx)
    else
      help(s)
    end
  end

  local track, tname = selected_track()
  ImGui.Dummy(ctx, 1, 4)
  if track then
    ImGui.TextColored(ctx, COL_GREEN, "Selected REAPER track: " .. tname)
  else
    ImGui.TextColored(ctx, COL_GREY, "No REAPER track selected.")
  end

  local can_apply = tr and track and off
  begin_disabled(not can_apply)
  -- Guarded again, not just disabled: the handler must not depend on the
  -- button having been greyed out the same frame.
  if ImGui.Button(ctx, "Apply to selected track", 190, 0) and can_apply then
    local p, err_or_warn = Apply.apply(track, tr, cfg, off)
    report(p ~= nil, p or err_or_warn, p and err_or_warn, "Applied to " .. tname, tr, off)
  end
  end_disabled()
  ImGui.SameLine(ctx)
  begin_disabled(not (tr and off))
  if ImGui.Button(ctx, "Insert as new track", 170, 0) and tr and off then
    local new, p, warn = Apply.insert_new(tr, cfg, off)
    if new then
      report(true, p, warn, "Inserted a new track", tr, off)
    else
      report(false, p)
    end
  end
  end_disabled()
  if tr then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, COL_GREY, "from AAF track: " .. (tr.name ~= "" and tr.name or "(unnamed)"))
  end
end

local function frame()
  file_section()
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.Text(ctx, ST.status)
  ImGui.PopTextWrapPos(ctx)
  if ST.span then
    if ImGui.SmallButton(ctx, "Show in arrange") then
      local a, b = ST.span[1], ST.span[2]
      local pad = math.max(1, (b - a) * 0.02)
      reaper.GetSet_ArrangeView2(0, true, 0, 0, math.max(0, a - pad), b + pad)
    end
  end
  if ST.warn then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, COL_AMBER, ST.warn)
    ImGui.PopTextWrapPos(ctx)
  end
  if ST.err then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, COL_RED, ST.err)
    ImGui.PopTextWrapPos(ctx)
  end

  section("Tracks in the AAF")
  local m = ST.model
  local rows = m and #m.tracks or 0
  track_table(math.min(260, 28 + 22 * math.max(rows, 1)))

  section("Preview")
  local w = select(1, ImGui.GetContentRegionAvail(ctx))
  preview(math.max(w, 100), 150)

  section("Import")
  import_section()
end

-- Everything start() does except enter the defer loop, so a test can drive
-- one frame against a stub ImGui.
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  HAVE_SEPTEXT = opt("SeparatorText") ~= nil
  cfg = Config.load()
  ctx = ImGui.CreateContext("AAF Importer")
  depth.child, depth.disabled, depth.table_ = 0, 0, 0
  ST.model, ST.sel, ST.err, ST.warn, ST.span = nil, nil, nil, nil, nil
  ST.status = "Open a Pro Tools AAF export to list its tracks."
  return ST, ctx, cfg
end

-- Renders one frame and closes anything it left open. Returns ok, err rather
-- than throwing.
function M._frame()
  depth.child, depth.disabled, depth.table_ = 0, 0, 0
  local ok, err = pcall(frame)
  if not ok then
    while depth.table_ > 0 do end_table() end
    while depth.disabled > 0 do end_disabled() end
  end
  return ok, err
end

M._cfg = function() return cfg end
M._depth = function() return depth.child + depth.disabled + depth.table_ end

function M.start(imgui, dir)
  M._init(imgui, dir)
  if cfg.last_path ~= "" then
    local fh = io.open(cfg.last_path, "rb")
    if fh then fh:close() M.load(cfg.last_path) end
  end

  local function loop()
    ImGui.SetNextWindowSize(ctx, 760, 720, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "AAF Importer", true)
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
