-- Track Manager -- the pure stages, plus panel frames against a stub ImGui.
--
-- No project, no ImGui, no audio. The matching language and the folder walk
-- are functions of strings and integers, and both have exactly stateable
-- answers -- which is the point, because both are places where a plausible
-- implementation is wrong only on the inputs nobody types by hand: a track
-- called "Gtr (DI)", a -2 that closes two folders at once, a folder left open
-- at the end of the project.
--
-- There is no system lua on this machine, so this runs inside the already
-- running REAPER via tools/run_tests.py. That is why the os.exit call is
-- guarded: REAPER's embedded Lua has no os.exit, and unguarded this file would
-- die on its own reporting line when run from the Actions list.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local dir = src:match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;" .. package.path

local Config = require "tm.config"
local Match  = require "tm.match"
local Tracks = require "tm.tracks"
local Apply  = require "tm.apply"

local pass, fail = 0, 0

local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL  %s%s", name, extra and ("  -- " .. extra) or ""))
  end
end

-- Anything that stops the run counts as a failure, not as "nothing to check".
local function bail(msg)
  fail = fail + 1
  print("FAIL  " .. msg)
end

----------------------------------------------------------------- matching

local function hits(text, names)
  local p, out = Match.parse(text), {}
  for _, n in ipairs(names) do
    if Match.matches(p, n) then out[#out + 1] = n end
  end
  return table.concat(out, "|")
end

local NAMES = { "DRUMS", "Kick", "Snare", "Drum room", "GTR 1", "GTR ref",
                "VOX", "Vox dbl", "Gtr (DI)", "Mix bus", "" }

ok(hits("drums", NAMES) == "DRUMS", "a bare term is a substring, case-blind")
ok(hits("drum", NAMES) == "DRUMS|Drum room", "substring finds both drums")
ok(hits("drum*", NAMES) == "DRUMS|Drum room", "a trailing * anchors at the start")
ok(hits("*room", NAMES) == "Drum room", "a leading * anchors at the end")
ok(hits("drums*", NAMES) == "DRUMS", "drums* does not reach Drum room")
ok(hits("*bus", NAMES) == "Mix bus", "ends-with")
ok(hits("gtr?1", NAMES) == "GTR 1", "? is exactly one character")
ok(hits("gtr", NAMES) == "GTR 1|GTR ref|Gtr (DI)", "substring, all three")
ok(hits("gtr, vox", NAMES) == "GTR 1|GTR ref|VOX|Vox dbl|Gtr (DI)",
   "a comma is or")
ok(hits("gtr; vox", NAMES) == "GTR 1|GTR ref|VOX|Vox dbl|Gtr (DI)",
   "a semicolon is or too")
ok(hits("gtr, -ref", NAMES) == "GTR 1|Gtr (DI)", "a leading - excludes")
ok(hits("-gtr", NAMES) == "DRUMS|Kick|Snare|Drum room|VOX|Vox dbl|Mix bus|",
   "exclusion alone means everything else")
ok(hits("gtr, -gtr", NAMES) == "", "exclusion beats inclusion")
ok(hits("  gtr 1  ", NAMES) == "GTR 1", "terms are trimmed, spaces kept inside")
ok(hits("gtr (di)", NAMES) == "Gtr (DI)",
   "Lua pattern magic in a term is a literal")
ok(hits("*", NAMES) == table.concat(NAMES, "|"),
   "a lone * matches everything, including an unnamed track")

ok(Match.parse("").empty, "an empty slot is empty")
ok(Match.parse("  , ; ").empty, "a slot of separators is empty")
ok(not Match.parse("-vox").empty, "a slot holding only an exclusion is not")
ok(hits("", NAMES) == "", "an empty slot matches nothing")

-------------------------------------------------------------- import terms
-- A track name has to survive the trip back into the slot language, and the
-- language has no escape -- so the round trip, not the spelling, is the test.

local function round(name)
  return hits(Match.literal(name), { name }) == name
end

ok(Match.literal("  GTR 1  ") == "GTR 1", "an imported name is trimmed")
ok(Match.literal("Gtr, DI") == "Gtr? DI",
   "a comma would split the term, so it is spent as ?", Match.literal("Gtr, DI"))
ok(Match.literal("Vox; dbl") == "Vox? dbl", "and a semicolon with it")
ok(Match.literal("-Room") == "?Room",
   "a leading - would invert the whole slot, so it goes too",
   Match.literal("-Room"))
ok(Match.literal("Sub-bus") == "Sub-bus", "a - anywhere else is a literal")
ok(Match.literal("") == "", "an unnamed track imports as an empty term")

ok(round("GTR 1"), "an imported name matches the track it came from")
ok(round("Gtr, DI"), "...one holding a comma")
ok(round("-Room"), "...one starting with a -")
ok(round("Gtr (DI)"), "...and one full of Lua pattern magic")
ok(hits(Match.literal("GTR 1"), NAMES) == "GTR 1",
   "and reaches nothing else in the project")

------------------------------------------------------------------ folders

local function expand(depths, hit_idx)
  local list = {}
  for i, d in ipairs(depths) do list[i] = { depth = d } end
  local hit = {}
  for _, i in ipairs(hit_idx) do hit[i] = true end
  return table.concat(Tracks.to_list(
    Tracks.expand_folders(list, hit, #list), #list), ",")
end

ok(expand({ 1, 0, -1, 0 }, { 1 }) == "1,2,3", "a folder pulls in its children")
ok(expand({ 1, 0, -1, 0 }, { 4 }) == "4", "a plain track pulls in nothing")
ok(expand({ 1, 0, -1, 0 }, { 2 }) == "2", "a child does not pull in its parent")
ok(expand({ 1, 1, -1, -1, 0 }, { 1 }) == "1,2,3,4", "nesting is recursive")
ok(expand({ 1, 1, -1, -1, 0 }, { 2 }) == "2,3", "the inner folder alone")
ok(expand({ 1, 1, -2, 0 }, { 1 }) == "1,2,3", "-2 closes two folders at once")
ok(expand({ 0, 1, 0 }, { 2 }) == "2,3",
   "a folder left unclosed at the end terminates")
ok(expand({ 1, 0, -1, 1, 0, -1 }, { 1, 4 }) == "1,2,3,4,5,6", "two folders")

local function union(lists, n)
  return table.concat(Tracks.union(lists, n), ",")
end

ok(union({ { 1, 2 }, { 4 } }, 5) == "1,2,4", "the slot union merges lists")
ok(union({ { 3, 1 }, { 1, 2 } }, 5) == "1,2,3",
   "and dedups overlapping slots back into project order",
   union({ { 3, 1 }, { 1, 2 } }, 5))
ok(union({ {}, {} }, 5) == "", "a union of empty slots is empty")
ok(union({}, 5) == "", "and so is a union of no slots at all")

local function levels(depths)
  local list = {}
  for i, d in ipairs(depths) do list[i] = { depth = d } end
  return table.concat(Tracks.levels(list, #list), ","),
         Tracks.max_level(list, #list)
end

local lv, mx = levels({ 1, 0, -1, 0 })
ok(lv == "1,2,2,1", "a folder parent sits on its siblings' level, not its children's", lv)
ok(mx == 2, "and the project is two levels deep", tostring(mx))

lv, mx = levels({ 1, 1, -1, -1, 0 })
ok(lv == "1,2,3,2,1", "a subfolder parent is level 2, its tracks level 3", lv)
ok(mx == 3, "three levels deep", tostring(mx))

lv = levels({ 1, 1, -2, 0 })
ok(lv == "1,2,3,1", "-2 unwinds both folders at once", lv)

lv = levels({ 0, 0, 0 })
ok(lv == "1,1,1", "a flat project is all level 1", lv)

lv = levels({ 0, -1, 0 })
ok(lv == "1,1,1", "an unbalanced -1 cannot push anything below level 1", lv)

lv, mx = levels({})
ok(lv == "" and mx == 0, "an empty project has no levels", lv .. "/" .. tostring(mx))

--------------------------------------------------------------------- modes

ok(Config.next_mode("select") == "hide", "numpad / goes select -> hide")
ok(Config.next_mode("hide") == "solo", "hide -> solo")
ok(Config.next_mode("solo") == "select", "and solo wraps back to select")
ok(Config.next_mode("nonsense") == "select",
   "an unrecognised mode falls back rather than sticking")
ok(#Config.MODES == 3 and Config.defaults.mode == Config.MODES[1],
   "the default mode is one of the three, and the first")

------------------------------------------------------------------- resolve
-- Apply.resolve and Apply.state read a snapshot, and a snapshot is a plain
-- table -- so both are testable here without a project.

local function snap_of(names, depths, flags)
  local s = { n = #names }
  for i = 1, #names do
    local f = (flags or {})[i] or {}
    s[i] = { track = {}, name = names[i], depth = depths[i] or 0,
             selected = f.sel or false,
             tcp = f.tcp ~= false, mcp = f.mcp ~= false,
             mute = f.mute or false, solo = f.solo or false }
  end
  return s
end

local SNAP = snap_of({ "DRUMS", "Kick", "Snare", "GTR 1", "GTR ref", "VOX" },
                     { 1, 0, -1, 0, 0, 0 })

local function ids(t) return table.concat(t, ",") end

ok(ids(Apply.resolve(SNAP, "drums*", true))  == "1,2,3",
   "folders on: drums* takes the whole folder")
ok(ids(Apply.resolve(SNAP, "drums*", false)) == "1",
   "folders off: drums* takes the folder track only")
ok(ids(Apply.resolve(SNAP, "gtr*, -gtr ref", true)) == "4",
   "exclusion survives folder expansion")
ok(ids(Apply.resolve(SNAP, "", true)) == "", "an empty slot resolves to nothing")

-- What the import button collects, off the same snapshot the lights read.
local SEL = snap_of({ "DRUMS", "Kick", "", "GTR 1", "VOX" },
                    { 1, 0, -1, 0, 0 },
                    { { sel = true }, { sel = false }, { sel = true },
                      { sel = true }, { sel = true } })
local imp, ntotal = Apply.selected_names(SEL)
ok(table.concat(imp, "|") == "DRUMS|GTR 1|VOX",
   "import takes the selected tracks in project order", table.concat(imp, "|"))
ok(ntotal == 3, "and an unnamed selected track is skipped, not slotted",
   tostring(ntotal))
local few, fewtotal = Apply.selected_names(SEL, 2)
ok(table.concat(few, "|") == "DRUMS|GTR 1", "never more than the limit",
   table.concat(few, "|"))
ok(fewtotal == 3, "though the tally still counts the ones left behind",
   tostring(fewtotal))
ok(#Apply.selected_names(snap_of({ "A", "B" }, { 0, 0 })) == 0,
   "nothing selected imports nothing")

local S2 = snap_of({ "A", "B", "C" }, { 0, 0, 0 },
                   { { sel = true }, { sel = true }, { sel = false } })
ok(Apply.state(S2, { 1, 2 }, "select") == "on",   "all selected reads on")
ok(Apply.state(S2, { 3 },    "select") == "off",  "none selected reads off")
ok(Apply.state(S2, { 1, 3 }, "select") == "mixed", "some selected reads mixed")
ok(Apply.state(S2, {},       "select") == "off",  "an empty slot reads off")

-- The and/or form of that test read a hidden track as selected, because an
-- unselected track makes the `and` fall through to the visibility branch.
local S2h = snap_of({ "A", "B" }, { 0, 0 },
                    { { sel = false, tcp = false, mcp = false },
                      { sel = false, tcp = true,  mcp = true } })
ok(Apply.state(S2h, { 1 }, "select", "both") == "off",
   "a hidden track is not selected")
ok(Apply.state(S2h, { 1, 2 }, "select", "both") == "off",
   "and neither is a hidden one next to a visible one")

-- Lit means PRESENT: showing, not hidden.
local S3 = snap_of({ "A", "B", "C" }, { 0, 0, 0 },
                   { { tcp = true,  mcp = true  },
                     { tcp = false, mcp = false },
                     { tcp = false, mcp = true  } })
ok(Apply.state(S3, { 1 }, "hide", "both") == "on",
   "showing in both reads on under both")
ok(Apply.state(S3, { 2 }, "hide", "both") == "off", "hidden in both reads off")
ok(Apply.state(S3, { 3 }, "hide", "both") == "off",
   "showing in the mixer only does not read on under both")
ok(Apply.state(S3, { 3 }, "hide", "tcp") == "off", "...and is off under tcp")
ok(Apply.state(S3, { 3 }, "hide", "mcp") == "on",  "...but on under mcp")
ok(Apply.state(S3, { 1, 2 }, "hide", "both") == "mixed", "half showing is mixed")

-- The folder-level setting is a lens on showing, and the lights are read
-- through it: a track below the setting is not a job left undone.
local S4 = snap_of({ "P", "kid", "sub", "deep", "loose" },
                   { 1, 0, 1, -2, 0 },
                   { { tcp = true }, { tcp = true }, { tcp = true },
                     { tcp = false, mcp = false }, { tcp = true } })
local ALL = { 1, 2, 3, 4, 5 }
ok(table.concat(Apply.showable(S4, ALL, 1), ",") == "1,5",
   "level 1 reaches the folder parent and the loose track",
   table.concat(Apply.showable(S4, ALL, 1), ","))
ok(table.concat(Apply.showable(S4, ALL, 2), ",") == "1,2,3,5",
   "level 2 reaches one level in, subfolder parents included",
   table.concat(Apply.showable(S4, ALL, 2), ","))
ok(table.concat(Apply.showable(S4, ALL, 3), ",") == "1,2,3,4,5",
   "level 3 reaches everything in this fixture")
ok(table.concat(Apply.showable(S4, ALL, nil), ",") == "1,2,3,4,5",
   "no setting means no lens")

ok(Apply.state(S4, ALL, "hide", "tcp", 2) == "on",
   "lit at level 2: everything the slot can reach is showing")
ok(Apply.state(S4, ALL, "hide", "tcp", 3) == "mixed",
   "expose another level and the same slot is only half done")
ok(Apply.state(S4, ALL, "hide", "tcp") == "mixed",
   "and unfiltered it is half done too")
ok(Apply.state(S4, { 4 }, "hide", "tcp", 2) == "off",
   "a slot that reaches nothing at this level reads off")
ok(Apply.state(S4, ALL, "select", nil, 1) == "off",
   "the lens does not touch Select mode")
ok(Apply.state(S4, ALL, "mute", nil, 1) == "off",
   "nor the mute light -- the lens is hide's alone")

-- The Solo/Mute row asks two questions of the same slot, and lit means
-- ENGAGED here rather than present: a red square lit for an unmuted track
-- would be the wrong way round in every DAW there is.
local S5 = snap_of({ "A", "B", "C" }, { 0, 0, 0 },
                   { { mute = true, solo = true },
                     { mute = true },
                     {} })
ok(Apply.state(S5, { 1, 2 }, "mute") == "on", "a wholly muted group is lit red")
ok(Apply.state(S5, { 3 }, "mute") == "off", "an unmuted one is dark")
ok(Apply.state(S5, { 1, 3 }, "mute") == "mixed", "half muted is half-lit")
ok(Apply.state(S5, { 1 }, "solo") == "on", "and solo is read separately")
ok(Apply.state(S5, { 2 }, "solo") == "off",
   "a muted track is not thereby soloed")
ok(Apply.state(S5, { 1, 2 }, "solo") == "mixed", "half soloed is half-lit")
ok(Apply.state(S5, {}, "mute") == "off", "an empty slot reads off in both")
ok(Apply.state(S5, { 1, 2 }, "hide", "both") == "on",
   "and a muted track is still SHOWING -- the two are different questions")

------------------------------------------------------------------- presets
-- Round-tripped through the real ExtState, under a section name that is not
-- the panel's, so a test run cannot eat the user's saved presets.

if not reaper then
  bail("presets need REAPER's ExtState")
else
  local real = Config.EXT_SECTION
  Config.EXT_SECTION = "track_manager_test"
  local okp, perr = pcall(function()
    Config.preset_delete("Mix")
    Config.preset_delete("Edit")
    reaper.SetExtState(Config.EXT_SECTION, "preset.count", "0", true)

    local list = Config.preset_save("Mix", { "drums*", "gtr*" })
    ok(#list == 1 and list[1].name == "Mix", "a preset saves")
    ok(Config.presets_load()[1].slots[1] == "drums*", "and reloads its slots")
    ok(Config.presets_load()[1].slots[9] == "",
       "slots past the end come back empty, not nil")

    Config.preset_save("Edit", { "vox*" })
    ok(#Config.presets_load() == 2, "a second preset appends")

    Config.preset_save("Mix", { "kick" })
    local l = Config.presets_load()
    ok(#l == 2, "saving an existing name overwrites rather than appending")
    ok(l[1].slots[1] == "kick" and l[1].slots[2] == "",
       "and replaces the whole set, not just the slots given")

    Config.preset_delete("Mix")
    l = Config.presets_load()
    ok(#l == 1 and l[1].name == "Edit", "delete compacts the list")
    ok(l[1].slots[1] == "vox*", "and the survivor kept its own slots")

    Config.preset_save("Third", { "x" })
    l = Config.presets_load()
    ok(#l == 2 and l[2].slots[1] == "x",
       "a shrunk list leaves no orphan keys to resurrect")

    Config.preset_delete("Edit")
    Config.preset_delete("Third")
    ok(#Config.presets_load() == 0, "the list empties")
  end)
  Config.EXT_SECTION = real
  if not okp then bail("presets raised: " .. tostring(perr)) end
end

--------------------------------------------------------------------- pages
-- Each mode has its own nine, and both stores carry all three pages. Run under
-- section names that are not the panel's, so a test cannot eat real settings.

if not reaper then
  bail("the page stores need REAPER's ExtState")
else
  local realx, realp = Config.EXT_SECTION, Config.PROJ_SECTION
  Config.EXT_SECTION, Config.PROJ_SECTION =
    "track_manager_test", "track_manager_test"
  local okg, gerr = pcall(function()
    local a = Config.new()
    ok(type(a.slots.select) == "table" and type(a.slots.hide) == "table"
       and type(a.slots.solo) == "table", "a fresh config has three pages")

    a.slots.select[1] = "drums*"
    ok(a.slots.hide[1] == "" and a.slots.solo[1] == "",
       "and the pages are independent tables, not three names for one")

    a.slots.hide[1] = "vox*"
    a.slots.solo[1] = "gtr*"
    a.slots.solo[9] = ""
    a.preset.select, a.preset.solo = "Mix", "Tracking"
    a.mode = "solo"
    Config.save(a)

    local b = Config.new()
    Config.load_proj(b)
    ok(b.slots.select[1] == "drums*" and b.slots.hide[1] == "vox*"
       and b.slots.solo[1] == "gtr*",
       "all three pages round-trip through the project",
       table.concat({ b.slots.select[1], b.slots.hide[1], b.slots.solo[1] }, "/"))
    ok(b.preset.select == "Mix" and b.preset.solo == "Tracking"
       and b.preset.hide == "",
       "and so does each page\'s loaded preset name")
    ok(b.mode == "solo", "with the mode alongside them")

    -- The global store on its own, which is what a brand-new project loads
    -- from: clear the project section so nothing can override it.
    reaper.SetProjExtState(0, Config.PROJ_SECTION, "", "")
    local g = Config.load()
    ok(g.slots.hide[1] == "vox*" and g.slots.solo[1] == "gtr*"
       and g.slots.select[1] == "drums*",
       "all three pages come back from the global store too",
       table.concat({ g.slots.select[1], g.slots.hide[1], g.slots.solo[1] }, "/"))
    ok(g.preset.select == "Mix", "with their preset names")

    -- The same migration on the global side -- the first run after an update,
    -- where the keys on disk are one shared set and there is no marker.
    reaper.DeleteExtState(Config.EXT_SECTION, Config.PRESENT_KEY, true)
    reaper.SetExtState(Config.EXT_SECTION, "slot.1", "old gtr", true)
    local h = Config.load()
    ok(h.slots.select[1] == "old gtr" and h.slots.hide[1] == "old gtr"
       and h.slots.solo[1] == "old gtr",
       "an unmarked global store seeds every page with its nine",
       table.concat({ h.slots.select[1], h.slots.hide[1], h.slots.solo[1] }, "/"))

    -- Format 1: nine slots shared by every mode. A session saved before the
    -- panel had pages must open with those nine on all three, not blank.
    reaper.SetProjExtState(0, Config.PROJ_SECTION, "", "")
    reaper.SetProjExtState(0, Config.PROJ_SECTION, Config.PRESENT_KEY, "1")
    reaper.SetProjExtState(0, Config.PROJ_SECTION, "slot.1", "old drums")
    reaper.SetProjExtState(0, Config.PROJ_SECTION, "preset", "Legacy")
    local c = Config.new()
    ok(Config.load_proj(c), "a format-1 project still reports settings")
    ok(c.slots.select[1] == "old drums" and c.slots.hide[1] == "old drums"
       and c.slots.solo[1] == "old drums",
       "and seeds every page with the nine it had",
       table.concat({ c.slots.select[1], c.slots.hide[1], c.slots.solo[1] }, "/"))
    ok(c.preset.hide == "Legacy", "including the one preset name it stored")

    reaper.SetProjExtState(0, Config.PROJ_SECTION, "", "")
    local d = Config.new()
    ok(not Config.load_proj(d), "and a cleared section still reports nothing")
  end)
  Config.EXT_SECTION, Config.PROJ_SECTION = realx, realp
  if not okg then bail("the page stores raised: " .. tostring(gerr)) end
end

-------------------------------------------------------------- panel frames

local okf, Frame = pcall(require, "ui_frame")
local oku, UI = pcall(require, "tm.ui")
if not okf or not oku then
  bail("could not load the panel: " .. tostring(Frame) .. " " .. tostring(UI))
else
  local states = {
    { "default", nil, {} },
    { "hide mode", function(_, c) c.mode = "hide" end, {} },
    { "hide, tcp only", function(_, c) c.mode = "hide" c.scope = "tcp" end, {} },
    { "folders off", function(_, c) c.include_folders = false end, {} },
    { "one folder level", function(st, c)
        c.mode, c.folder_levels, st.max_level = "hide", 1, 4
      end, {} },
    { "slots filled", function(_, c)
        c.slots.select[1] = "drums*" c.slots.select[2] = "gtr*, -gtr ref"
        c.slots.select[3] = "vox"
      end, {} },
    { "a preset loaded", function(st, c)
        c.preset.select, st.pname = "Mix", "Mix"
        c.slots.select[1] = "drums*"
      end, {} },
    { "delete confirm", function(st, c)
        c.preset.select, st.pname, st.confirm_del = "Mix", "Mix", true
      end, {} },
    { "solo mode", function(_, c)
        c.mode = "solo"
        c.slots.solo[1] = "drums*" c.slots.solo[2] = "kick"
        c.slots.solo[3] = "vox"
      end, {} },
    { "solo squares pressed", function(_, c)
        c.mode = "solo"
        c.slots.solo[1] = "drums*" c.slots.solo[2] = "kick"
      end,
      { ["##mute1"] = true, ["##solo1"] = true, ["##mute2"] = true,
        ["Solo all##bulk_on"] = true, ["Unsolo all##bulk_off"] = true,
        ["Solo/Mute"] = true } },
    { "every button clicked", function(_, c) c.slots.select[1] = "drums*" end,
      { Select = true, Hide = true, TCP = true, MCP = true, Both = true,
        Save = true, Del = true, ["Sure?"] = true,
        ["Select all"] = true, ["Deselect all"] = true,
        ["Show all"] = true, ["Hide all"] = true,
        ["##hit1"] = true, ["##hit2"] = true,
        ["From selection"] = true, ["Solo/Mute"] = true } },
  }

  for _, moved in ipairs({ false, true }) do
    for _, s in ipairs(states) do
      local name = s[1] .. (moved and " (moved)" or "")
      local good, err, log = Frame.run(UI, root, s[2], s[3], moved)
      ok(good, "frame: " .. name, tostring(err))
      if good then
        ok(log.push == 0, "style stack balanced: " .. name, tostring(log.push))
        ok(log.dis == 0, "disabled stack balanced: " .. name, tostring(log.dis))
      end
    end
  end

  -- The import button asserted rather than merely rendered: the stub project
  -- has exactly one selected track, so a click has to land its name in slot 1
  -- and leave slot 2 alone.
  do
    local good, err, _, _, c =
      Frame.run(UI, root, nil, { ["From selection"] = true }, false)
    ok(good, "frame: import from selection", tostring(err))
    ok(good and c.slots.select[1] == "GTR 1",
       "the import button fills slot 1 of the page from the selection",
       good and ("[" .. c.slots.select[1] .. "]") or "-")
    ok(good and c.slots.select[2] == "",
       "and stops at the number of tracks selected")
  end

  -- Solo/Mute names tracks, not folders. The stub project is a DRUMS folder
  -- over Kick and Snare, so the two modes must resolve the same pattern
  -- differently -- which is a panel-level rule, invisible to Apply.resolve.
  do
    local good, err, _, st = Frame.run(UI, root, function(_, c)
      c.mode, c.include_folders = "solo", true
      c.slots.solo[1] = "drums"
    end, {}, false)
    ok(good, "frame: solo mode resolves a folder name", tostring(err))
    ok(good and table.concat(st.idxs[1], ",") == "1",
       "Solo/Mute reaches the parent alone, folders checkbox or not",
       good and table.concat(st.idxs[1], ",") or "-")

    local good2, err2, _, st2 = Frame.run(UI, root, function(_, c)
      c.mode, c.include_folders = "hide", true
      c.slots.hide[1] = "drums"
    end, {}, false)
    ok(good2, "frame: hide mode resolves the same name", tostring(err2))
    ok(good2 and table.concat(st2.idxs[1], ",") == "1,2,3",
       "while Hide still takes the whole folder",
       good2 and table.concat(st2.idxs[1], ",") or "-")
  end

  -- Every config key the panel names must exist, and every key must have a
  -- control. A renamed key is otherwise a nil read that kills the frame, and
  -- an orphaned key is a setting that persists and can never be changed.
  local f = io.open(root .. "tm/ui.lua", "r")
  if not f then
    bail("could not read tm/ui.lua for the key scan")
  else
    local text = f:read("a")
    f:close()
    local seen = {}
    for key in text:gmatch('cfg%.([%w_]+)') do seen[key] = true end
    for key in text:gmatch('changed%("([%w_]+)"') do
      seen[key] = true
      ok(Config.defaults[key] ~= nil,
         string.format('changed("%s") names a real config key', key))
    end
    local missing = {}
    for key in pairs(Config.defaults) do
      if not seen[key] then missing[#missing + 1] = key end
    end
    table.sort(missing)
    ok(#missing == 0, "every setting is named by the panel",
       "not named: " .. table.concat(missing, ", "))
  end
end

print(string.format("\nheadless: %d passed, %d failed", pass, fail))
-- The tally has to reach the exit code, or a CI job or an && chain reads a
-- suite that printed FAIL as green. Run from the Actions list this is a no-op:
-- REAPER's Lua has no os.exit, so the call is simply absent.
if os.exit then os.exit(fail == 0 and 0 or 1) end
