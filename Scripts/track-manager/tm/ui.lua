-- @noindex
-- Track Manager -- the panel.
--
-- Laid out the way it is used: pick what the buttons do, pick what "hidden"
-- means, then nine rows of pattern-and-light, then the import, then the two
-- blunt instruments, then the preset shelf.
--
-- The one design commitment everything else follows from: a slot's light is
-- READ OFF THE PROJECT every frame and never stored. A slot is lit when its
-- tracks are, right now, in the state that slot would put them in -- so the
-- button is a toggle without owning any state, and hiding a track by hand or
-- selecting one in the TCP cannot desync the panel, because there is nothing
-- to desync. It also makes the tooltip honest: the count is what pressing the
-- button WOULD affect, not what it did last time.
--
-- Three modes, cycled with numpad /, and Solo/Mute is the one that breaks the
-- panel's own rule that lit means PRESENT: its two squares light for a group
-- that is muted or soloed. Red means muted in every DAW there is, and a red
-- square lit for an unmuted track would be a worse lie than the exception.
--
-- Keyboard shortcuts only arrive while this window has focus. ReaImGui gets
-- keys for its own window and nothing else, and the alternative -- polling the
-- OS through js_ReaScriptAPI -- buys global keys at the cost of a second
-- extension and of numpad 1 firing while you type into a REAPER field. Click
-- the panel once; the footer says so.

local Config = require "tm.config"
local Apply  = require "tm.apply"
local Tracks = require "tm.tracks"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.new()

local ST = {
  snap = { n = 0 }, max_level = 1,
  idxs = {}, show = {}, state = {},
  import = {}, import_n = 0,
  mute = {}, solo = {},
  presets = {}, pname = "",
  confirm_del = false,
  proj = nil,
  close = false,
  err = nil,
}

local COL_GREY     = 0x808080FF
local COL_RED      = 0xE05050FF
local COL_LIT_SEL  = 0x50C878FF   -- green: this group is selected
local COL_LIT_HIDE = 0xE0A050FF   -- amber: this group is showing
local COL_LIT_MUTE = 0xD04848FF   -- red:    this group is muted
local COL_LIT_SOLO = 0xE8C840FF   -- yellow: this group is soloed
local COL_OFF      = 0x2A3036FF

local WIN_FLAGS, MOD_CTRL, KEY_SLOT, KEY_CLOSE, KEY_ADD, KEY_SUB, KEY_MODE
local HAVE_HINT

-- An optional ImGui symbol has to be ASKED for, not assumed: the ReaImGui shim
-- raises on an unknown field rather than returning nil, so `ImGui.A or ImGui.B`
-- never gets a chance to run.
local function opt(name)
  local ok, v = pcall(function() return ImGui[name] end)
  if ok then return v end
  return nil
end

local function shade(col, f)
  local r = math.min(255, math.floor(((col >> 24) & 0xFF) * f))
  local g = math.min(255, math.floor(((col >> 16) & 0xFF) * f))
  local b = math.min(255, math.floor(((col >>  8) & 0xFF) * f))
  return (r << 24) | (g << 16) | (b << 8) | (col & 0xFF)
end

local function alpha(col, a) return (col & 0xFFFFFF00) | (a & 0xFF) end

--------------------------------------------------------------- counted stacks
-- BeginDisabled/EndDisabled and PushStyleColor/PopStyleColor through counted
-- pairs, so an error thrown mid-frame cannot leave either stack unbalanced.
-- Unbalanced, ImGui.End raises its own error over the top of the real one --
-- outside the pcall -- and the panel dies reporting the symptom while hiding
-- the cause.

local depth = { dis = 0, style = 0 }

local function begin_disabled(cond)
  ImGui.BeginDisabled(ctx, cond)
  depth.dis = depth.dis + 1
end

local function end_disabled()
  if depth.dis < 1 then return end
  depth.dis = depth.dis - 1
  ImGui.EndDisabled(ctx)
end

local function push_style(which, col)
  ImGui.PushStyleColor(ctx, which, col)
  depth.style = depth.style + 1
end

local function pop_style(n)
  n = math.min(n or 1, depth.style)
  if n < 1 then return end
  depth.style = depth.style - n
  ImGui.PopStyleColor(ctx, n)
end

local function unwind()
  while depth.dis > 0 do end_disabled() end
  if depth.style > 0 then pop_style(depth.style) end
end

------------------------------------------------------------------- wrappers

-- The changed-callback is bound to a local before being called. Writing
--     cfg[key] = v (on_change or noop)()
-- reads like two statements and is not: Lua treats a `(` following an
-- expression as a call, so that line calls `v` -- a boolean.
local function changed(key, v, on_change)
  cfg[key] = v
  if on_change then on_change() end
end

local function help(text) ImGui.TextColored(ctx, COL_GREY, text) end

-- The nine slots of the page being looked at. Each mode has its own, so every
-- read and write of a slot goes through here rather than through cfg.slots.
local function slots() return cfg.slots[cfg.mode] or cfg.slots.select end

--------------------------------------------------------------------- project

local function cur_project()
  if not reaper or not reaper.EnumProjects then return nil end
  local ok, p = pcall(reaper.EnumProjects, -1, "")
  if ok then return p end
  return nil
end

local function refresh()
  ST.snap = Apply.snapshot()
  ST.max_level = math.max(1, Tracks.max_level(ST.snap, ST.snap.n))
  -- Solo and mute never expand a folder, whatever the checkbox says. REAPER
  -- already carries a parent's mute and solo down to its children through the
  -- folder's own routing, so expanding would write the flag onto tracks that
  -- were going to follow anyway -- and then a later unmute would clear a child
  -- the user had muted by hand. Select and Hide have no such propagation and
  -- need the expansion.
  local expand = cfg.include_folders and cfg.mode ~= "solo"
  local page = slots()
  for i = 1, Config.NSLOTS do
    ST.idxs[i]  = Apply.resolve(ST.snap, page[i], expand)
    ST.show[i]  = Apply.showable(ST.snap, ST.idxs[i], cfg.folder_levels)
    ST.state[i] = Apply.state(ST.snap, ST.idxs[i], cfg.mode, cfg.scope,
                              cfg.folder_levels)
    -- Both lights of the Solo/Mute row, read every frame like every other
    -- light here. Two more passes over a slot's tracks is nothing, and it
    -- keeps the row's two squares describing the same instant as the rest.
    ST.mute[i]  = Apply.state(ST.snap, ST.idxs[i], "mute")
    ST.solo[i]  = Apply.state(ST.snap, ST.idxs[i], "solo")
  end
  ST.import, ST.import_n = Apply.selected_names(ST.snap, Config.NSLOTS)
end

-- Switching project tab swaps the slots, because the slots belong to the
-- session. A project that has never been touched by this panel keeps whatever
-- is on screen, which then becomes its slots the first time anything is edited.
local function sync_project()
  local p = cur_project()
  if p == ST.proj then return end
  ST.proj = p
  Config.load_proj(cfg)
  ST.pname = cfg.preset[cfg.mode] or ""
  ST.confirm_del = false
end

--------------------------------------------------------------------- actions

-- One square of the Solo/Mute row. Pressing a lit one clears the flag,
-- pressing a dark or half-lit one sets it -- so a half-done group finishes,
-- the same bargain the single square makes in the other two modes.
local function press_flag(i, what)
  local idxs = ST.idxs[i]
  if not idxs or #idxs == 0 then return end
  local st = (what == "mute") and ST.mute[i] or ST.solo[i]
  Apply.set_flag(ST.snap, idxs, what, st ~= "on")
  refresh()
end

local function press_slot(i, ctrl)
  local idxs = ST.idxs[i]
  if not idxs or #idxs == 0 then return end

  -- In Solo/Mute mode the numpad key is solo, and Ctrl reaches the other
  -- square -- the same modifier doing the same job it does in Select mode,
  -- which is getting at the second thing without leaving the numpad.
  if cfg.mode == "solo" then
    press_flag(i, ctrl and "mute" or "solo")
    return
  end

  local lit = ST.state[i] == "on"

  if cfg.mode == "select" then
    if ctrl then
      -- Accumulate: add this group, or take just this group back out, and
      -- leave everything else alone.
      Apply.set_selected(ST.snap, idxs, not lit, false)
    elseif lit then
      Apply.set_selected(ST.snap, {}, false, true)
    else
      Apply.set_selected(ST.snap, idxs, true, true)
    end
  elseif lit then
    -- A group is hidden whole...
    Apply.set_visible(ST.snap, idxs, false, cfg.scope)
  else
    -- ...and revealed only as deep as the folder-level setting reaches.
    Apply.set_visible(ST.snap, ST.show[i] or idxs, true, cfg.scope)
  end
  refresh()
end

local function set_mode(m)
  changed("mode", m, function()
    -- The name field and the combo belong to the page, so they move with it.
    ST.pname = cfg.preset[m] or ""
    ST.confirm_del = false
    Config.save(cfg)
    refresh()
  end)
end

local function cycle_mode()
  set_mode(Config.next_mode(cfg.mode))
end

-- A setting, not an action: it moves nothing by itself. What it changes at
-- once is the LIGHTS, because they are read through the same lens -- which is
-- the feedback that says what the next press will reach.
local function set_levels(n)
  n = math.max(1, math.min(math.floor(n), ST.max_level or 1))
  changed("folder_levels", n, function() Config.save(cfg) refresh() end)
end

-- numpad + and the left button; numpad - and the right one.
-- Every track the nine slots name, once each, in project order.
--
-- This is what the blunt instruments reach in Solo/Mute mode, and it is the
-- one place they are not project-wide. Soloing every track in a project is
-- audibly the same as soloing none, so a key that did it would do nothing;
-- soloing everything the slots name is the useful action -- it leaves exactly
-- your groups up and everything unnamed quiet.
local function slot_union()
  return Tracks.union(ST.idxs, ST.snap.n)
end

local function do_all(on, ctrl)
  if cfg.mode == "select" then
    Apply.all_selected(ST.snap, on)
  elseif cfg.mode == "solo" then
    -- + engages and - clears, Ctrl picks which flag -- the same division the
    -- numpad makes on the slots themselves, one row up.
    Apply.set_flag(ST.snap, slot_union(), ctrl and "mute" or "solo", on)
  else
    Apply.all_visible(ST.snap, on, cfg.scope, cfg.folder_levels)
  end
  refresh()
end

-- The one action that writes the SLOTS rather than the project: the first nine
-- selected track names, as terms, into the slots from the top.
--
-- It fills from the top and stops. Slots past the number imported keep what
-- they had, so importing three tracks is not also a way to lose the other six
-- patterns -- and there is no undo for a slot, ExtState being written straight
-- through. The tooltip says which slots the press will overwrite before it is
-- pressed, which is the same bargain the squares make.
local function import_selection()
  local names = ST.import or {}
  if #names == 0 then return end
  local page = slots()
  for i = 1, #names do page[i] = names[i] end
  Config.save(cfg)
  refresh()
end

-- Onto the page being looked at: a preset is nine patterns, and which mode
-- they are for is the user's business rather than the shelf's.
local function load_preset(sel)
  ST.confirm_del = false
  if sel < 1 then
    cfg.preset[cfg.mode] = ""
  else
    local p = ST.presets[sel]
    if not p then return end
    local page = slots()
    for i = 1, Config.NSLOTS do page[i] = p.slots[i] or "" end
    cfg.preset[cfg.mode], ST.pname = p.name, p.name
  end
  Config.save(cfg)
  refresh()
end

------------------------------------------------------------------------ keys

local function keys()
  -- Skipped entirely while a text field owns the keyboard, or typing "1" into
  -- a slot fires slot 1.
  if ImGui.IsAnyItemActive(ctx) then return end
  local ctrl = MOD_CTRL and ImGui.IsKeyDown(ctx, MOD_CTRL) or false

  for i = 1, Config.NSLOTS do
    local k = KEY_SLOT[i]
    if k and ImGui.IsKeyPressed(ctx, k, false) then press_slot(i, ctrl) end
  end
  if KEY_CLOSE and ImGui.IsKeyPressed(ctx, KEY_CLOSE, false) then
    ST.close = true
  end
  if KEY_ADD and ImGui.IsKeyPressed(ctx, KEY_ADD, false) then do_all(true, ctrl) end
  if KEY_SUB and ImGui.IsKeyPressed(ctx, KEY_SUB, false) then do_all(false, ctrl) end
  if KEY_MODE and ImGui.IsKeyPressed(ctx, KEY_MODE, false) then cycle_mode() end
end

----------------------------------------------------------------------- frame

local function draw_modes()
  if ImGui.RadioButton(ctx, "Select", cfg.mode == "select") then
    set_mode("select")
  end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Hide", cfg.mode == "hide") then set_mode("hide") end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Solo/Mute", cfg.mode == "solo") then
    set_mode("solo")
  end

  -- Both of these belong to Hide alone: there is one selection and both panels
  -- show it, and mute and solo are per-track and reach whatever a slot names.
  local hiding = cfg.mode == "hide"
  begin_disabled(not hiding)
  ImGui.Text(ctx, "Panels:")
  for _, s in ipairs({ { "TCP", "tcp" }, { "MCP", "mcp" }, { "Both", "both" } }) do
    ImGui.SameLine(ctx)
    if ImGui.RadioButton(ctx, s[1], cfg.scope == s[2]) then
      changed("scope", s[2], function() Config.save(cfg) refresh() end)
    end
  end
  end_disabled()

  -- Greyed in Solo/Mute, where a folder's children follow their parent through
  -- REAPER's own routing and this panel deliberately leaves them alone.
  begin_disabled(cfg.mode == "solo")
  local rv, v = ImGui.Checkbox(ctx, "Include tracks in folders",
                               cfg.include_folders)
  if rv then
    changed("include_folders", v, function() Config.save(cfg) refresh() end)
  end
  end_disabled()

  -- An outline control rather than a stored preference: it takes effect the
  -- moment it moves, and never on load. Clamped to what the project actually
  -- has, so the box cannot be wound past the deepest folder in the session.
  begin_disabled(not hiding)
  ImGui.SetNextItemWidth(ctx, 96)
  local rvl, lv = ImGui.InputInt(ctx, "##levels", cfg.folder_levels, 1)
  if rvl then set_levels(lv) end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, string.format("levels of %d", ST.max_level or 1))
  end_disabled()
end

-- One 18px light. Drawn dark, half-lit or lit, and disabled when the slot
-- names nothing -- a pattern with a typo in it reads as a dead square rather
-- than a live button that does nothing.
local function square(id, col, st, dead, on_press)
  local base = COL_OFF
  if st == "on" then base = col
  elseif st == "mixed" then base = alpha(col, 0x80) end
  push_style(ImGui.Col_Button, base)
  push_style(ImGui.Col_ButtonHovered, shade(base, 1.3))
  push_style(ImGui.Col_ButtonActive, shade(base, 1.6))
  begin_disabled(dead)
  if ImGui.Button(ctx, id, 18, 0) then on_press() end
  end_disabled()
  pop_style(3)
end

-- Counted from the project as it is, so it names what the press WOULD affect
-- rather than what it did last time.
local function tooltip(i, head)
  local idxs = ST.idxs[i] or {}
  if #idxs == 0 or not ImGui.IsItemHovered(ctx) then return end
  local names = {}
  for n = 1, math.min(#idxs, 8) do
    local t = ST.snap[idxs[n]]
    names[n] = (t.name ~= "" and t.name) or ("track " .. idxs[n])
  end
  if #idxs > 8 then names[#names + 1] = "..." end
  ImGui.SetTooltip(ctx, head .. "\n" .. table.concat(names, "\n"))
end

local function draw_slots()
  local soloing, page = cfg.mode == "solo", slots()
  local lit_col = (cfg.mode == "select") and COL_LIT_SEL or COL_LIT_HIDE

  for i = 1, Config.NSLOTS do
    local idxs, st = ST.idxs[i] or {}, ST.state[i] or "off"
    local dead = #idxs == 0
    local count = string.format("%d track%s", #idxs, #idxs == 1 and "" or "s")

    ImGui.Text(ctx, tostring(i))
    ImGui.SameLine(ctx)

    -- Room for the second square, and only in the mode that has one.
    ImGui.SetNextItemWidth(ctx, soloing and -52 or -26)
    local rv, v = ImGui.InputText(ctx, "##slot" .. i, page[i])
    if rv then page[i] = v end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      Config.save(cfg)
      refresh()
    end

    if soloing then
      -- Mute first, then solo, in the order they sit on a REAPER track panel.
      ImGui.SameLine(ctx)
      square("##mute" .. i, COL_LIT_MUTE, ST.mute[i], dead,
             function() press_flag(i, "mute") end)
      tooltip(i, (ST.mute[i] == "on" and "Unmute " or "Mute ") .. count)

      ImGui.SameLine(ctx)
      square("##solo" .. i, COL_LIT_SOLO, ST.solo[i], dead,
             function() press_flag(i, "solo") end)
      tooltip(i, (ST.solo[i] == "on" and "Unsolo " or "Solo ") .. count)
    else
      ImGui.SameLine(ctx)
      square("##hit" .. i, lit_col, st, dead, function()
        press_slot(i, MOD_CTRL and ImGui.IsKeyDown(ctx, MOD_CTRL) or false)
      end)

      -- Held back is worth saying out loud: otherwise a slot that shows four
      -- of its six tracks looks like a bug rather than the level setting.
      local head = count
      local held = #idxs - #(ST.show[i] or idxs)
      if cfg.mode == "hide" and held > 0 then
        head = head .. string.format(", %d below level %d",
                                     held, cfg.folder_levels)
      end
      tooltip(i, head)
    end
  end
end

local function draw_import()
  local names, total = ST.import or {}, ST.import_n or 0
  local span = #names == 1 and "slot 1"
               or string.format("slots 1-%d", #names)

  begin_disabled(#names == 0)
  if ImGui.Button(ctx, "From selection", 110, 0) then import_selection() end
  end_disabled()

  if #names > 0 and ImGui.IsItemHovered(ctx) then
    local head = "Overwrites " .. span
    if total > #names then
      head = head .. string.format(" -- the first %d of %d selected",
                                   #names, total)
    end
    ImGui.SetTooltip(ctx, head .. "\n" .. table.concat(names, "\n"))
  end

  ImGui.SameLine(ctx)
  help(#names == 0 and "nothing selected" or ("into " .. span))
end

local BULK = {
  select = { "Select all", "Deselect all" },
  hide   = { "Show all",   "Hide all" },
}

-- In Solo/Mute mode these two follow the modifier, and they say so by
-- RELABELLING while it is held: the same press, spelled out before it is made.
-- The ## suffix keeps each button's identity stable across the relabel, or a
-- Ctrl pressed mid-click would land on a different widget and be swallowed.
local function draw_solo_bulk()
  local all = slot_union()
  local muting = MOD_CTRL and ImGui.IsKeyDown(ctx, MOD_CTRL) or false
  local tip = string.format("%d track%s named by the slots",
                            #all, #all == 1 and "" or "s")

  begin_disabled(#all == 0)
  if ImGui.Button(ctx, (muting and "Mute all" or "Solo all") .. "##bulk_on",
                  110, 0) then
    do_all(true, muting)
  end
  end_disabled()
  if #all > 0 and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, tip) end

  ImGui.SameLine(ctx)
  begin_disabled(#all == 0)
  if ImGui.Button(ctx, (muting and "Unmute all" or "Unsolo all") .. "##bulk_off",
                  110, 0) then
    do_all(false, muting)
  end
  end_disabled()
  if #all > 0 and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, tip) end
end

local function draw_bulk()
  if cfg.mode == "solo" then return draw_solo_bulk() end
  local label = BULK[cfg.mode] or BULK.select
  if ImGui.Button(ctx, label[1], 110, 0) then do_all(true) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, label[2], 110, 0) then do_all(false) end
end

local function draw_presets()
  local loaded = cfg.preset[cfg.mode] or ""
  local labels, cur = { "(none)" }, 0
  for i, p in ipairs(ST.presets) do
    labels[i + 1] = p.name
    if p.name == loaded then cur = i end
  end

  ImGui.SetNextItemWidth(ctx, -1)
  local rv, sel = ImGui.Combo(ctx, "##preset", cur,
                              table.concat(labels, "\0") .. "\0")
  if rv then load_preset(sel) end

  -- -100 is the two buttons and BOTH gaps beside them (8 + 44 + 8 + 40), so
  -- the row ends flush with the combo above it. Counting one gap leaves Del
  -- hanging 8px past the right edge.
  ImGui.SetNextItemWidth(ctx, -100)
  local rv2, nm
  if HAVE_HINT then
    rv2, nm = ImGui.InputTextWithHint(ctx, "##pname", "name", ST.pname)
  else
    rv2, nm = ImGui.InputText(ctx, "##pname", ST.pname)
  end
  if rv2 then ST.pname = nm end

  ImGui.SameLine(ctx)
  begin_disabled(ST.pname == "")
  if ImGui.Button(ctx, "Save", 44, 0) then
    ST.presets = Config.preset_save(ST.pname, slots())
    cfg.preset[cfg.mode] = ST.pname
    Config.save(cfg)
    ST.confirm_del = false
  end
  end_disabled()

  ImGui.SameLine(ctx)
  -- Two steps, because one click would otherwise throw away a named set with
  -- no undo -- ExtState is written straight through.
  if ST.confirm_del then
    push_style(ImGui.Col_Button, 0xB04040FF)
    if ImGui.Button(ctx, "Sure?", 40, 0) then
      ST.presets = Config.preset_delete(loaded)
      cfg.preset[cfg.mode] = ""
      Config.save(cfg)
      ST.confirm_del = false
    end
    pop_style(1)
  else
    begin_disabled(loaded == "")
    if ImGui.Button(ctx, "Del", 40, 0) then ST.confirm_del = true end
    end_disabled()
  end
end

local function frame()
  sync_project()
  refresh()
  keys()

  draw_modes()
  ImGui.Separator(ctx)
  draw_slots()
  ImGui.Dummy(ctx, 1, 4)
  draw_import()
  ImGui.Dummy(ctx, 1, 4)
  draw_bulk()
  ImGui.Separator(ctx)
  draw_presets()
  ImGui.Dummy(ctx, 1, 4)
  if cfg.mode == "solo" then
    help("Numpad 1-9 solo, Ctrl mutes")
  elseif cfg.mode == "hide" then
    help("Numpad 1-9 slots")
  else
    help("Numpad 1-9 slots, Ctrl adds")
  end
  help("Numpad / cycles mode, 0 closes")
  help(cfg.mode == "solo" and "Numpad +/- all slots on/off"
                          or  "Numpad +/- all or none")
  help("Keys need this window focused.")
end

------------------------------------------------------------------ test hooks

-- Everything start() does except enter the defer loop. Split out so a test can
-- drive one frame against a stub: the panel is otherwise the only file the
-- suites cannot execute, and it is where a renamed config key lands -- as a
-- nil read that errors the frame and takes the whole panel below it with it.
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir

  WIN_FLAGS = (opt("WindowFlags_TopMost") or 0)
            | (opt("WindowFlags_NoDocking") or 0)
  MOD_CTRL  = opt("Mod_Ctrl")
  KEY_CLOSE = opt("Key_Keypad0")
  KEY_ADD   = opt("Key_KeypadAdd")
  KEY_SUB   = opt("Key_KeypadSubtract")
  KEY_MODE  = opt("Key_KeypadDivide")
  HAVE_HINT = opt("InputTextWithHint") ~= nil
  KEY_SLOT = {}
  for i = 1, Config.NSLOTS do KEY_SLOT[i] = opt("Key_Keypad" .. i) end

  cfg = Config.load()
  ST.presets = Config.presets_load()
  ST.pname = cfg.preset[cfg.mode] or ""
  ST.proj = cur_project()
  ST.close, ST.err, ST.confirm_del = false, nil, false
  depth.dis, depth.style = 0, 0

  ctx = ImGui.CreateContext("Track Manager")
  refresh()
  return ST, cfg
end

-- Renders one frame and closes anything it left open. Returns ok, err rather
-- than throwing, so no caller has to remember the unwind.
function M._frame()
  depth.dis, depth.style = 0, 0
  local ok, err = pcall(frame)
  if not ok then unwind() end
  return ok, err
end

function M._cfg() return cfg end
function M._state() return ST end
function M._depth() return depth.dis, depth.style end

function M.start(imgui, dir)
  M._init(imgui, dir)

  local function loop()
    ImGui.SetNextWindowSize(ctx, 260, 500, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Track Manager", true, WIN_FLAGS)
    if visible then
      local ok, err = M._frame()
      if not ok then
        ST.err = tostring(err)
        ImGui.TextColored(ctx, COL_RED, ST.err)
      end
      ImGui.End(ctx)
    end
    if open and not ST.close then reaper.defer(loop) end
  end

  reaper.defer(loop)
end

return M
