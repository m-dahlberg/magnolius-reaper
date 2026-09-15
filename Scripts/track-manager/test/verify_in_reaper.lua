-- Track Manager -- the project edge, against a real project.
--
-- Everything below Apply.snapshot is pure and covered headlessly. This suite
-- covers the part that is not: that B_SHOWINTCP and B_SHOWINMIXER really do
-- move the way the scope says, that exclusive and accumulating selection do
-- what the two press styles promise, and that the nine slots survive a round
-- trip through project ExtState.
--
-- It builds its own fixture rather than relying on the open project having
-- useful tracks, and every name is prefixed TM so a pattern in the suite
-- cannot reach into the user's own tracks. The fixture is deleted and the
-- selection and visibility of every pre-existing track restored, in an
-- unwind that runs whether or not the body raised -- selection, visibility,
-- mute and solo, which are the four things it writes.
--
-- It does leave the project DIRTY: adding and deleting tracks is an edit, and
-- so is the ExtState round trip. Run it on a scratch project.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local dir = src:match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;" .. package.path

local Config = require "tm.config"
local Apply  = require "tm.apply"
local Tracks = require "tm.tracks"

local pass, fail = 0, 0

local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL  %s%s", name, extra and ("  -- " .. extra) or ""))
  end
end

local function bail(msg)
  fail = fail + 1
  print("FAIL  " .. msg)
end

local function ids(t) return table.concat(t, ",") end

------------------------------------------------------------------- restore
-- Taken before anything is touched, applied in the unwind. These four are what
-- this suite writes to tracks it did not make -- and mute and solo are on the
-- list because this suite mutes and solos tracks of its own, and a run that did
-- not restore them would leave the user's session sounding different.

local function capture()
  local n, out = reaper.CountTracks(0), {}
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    out[i + 1] = {
      track = tr,
      sel = reaper.GetMediaTrackInfo_Value(tr, "I_SELECTED"),
      tcp = reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP"),
      mcp = reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER"),
      mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
      solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"),
    }
  end
  return out
end

local function restore(saved)
  for _, s in ipairs(saved) do
    -- ValidatePtr, because the body may have deleted a track by the time this
    -- runs and writing through a stale pointer crashes REAPER outright.
    if reaper.ValidatePtr2(0, s.track, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(s.track, "I_SELECTED", s.sel)
      reaper.SetMediaTrackInfo_Value(s.track, "B_SHOWINTCP", s.tcp)
      reaper.SetMediaTrackInfo_Value(s.track, "B_SHOWINMIXER", s.mcp)
      reaper.SetMediaTrackInfo_Value(s.track, "B_MUTE", s.mute)
      reaper.SetMediaTrackInfo_Value(s.track, "I_SOLO", s.solo)
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

------------------------------------------------------------------- fixture

local FIXTURE = {
  { "TMDRUMS",   1 },
  { "TMKick",    0 },
  { "TMSnare",  -1 },
  { "TMGtr 1",   0 },
  { "TMGtr ref", 0 },
  { "TMVox",     0 },
}

local function build(base)
  local made = {}
  for i, f in ipairs(FIXTURE) do
    reaper.InsertTrackAtIndex(base + i - 1, false)
    local tr = reaper.GetTrack(0, base + i - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", f[1], true)
    reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", f[2])
    made[i] = tr
  end
  reaper.TrackList_AdjustWindows(false)
  return made
end

local function teardown(made)
  for i = #made, 1, -1 do
    if reaper.ValidatePtr2(0, made[i], "MediaTrack*") then
      reaper.DeleteTrack(made[i])
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

---------------------------------------------------------------------- body

local function body(base)
  local function snap() return Apply.snapshot() end
  local function at(i) return base + i end        -- fixture row -> track index

  local S = snap()
  ok(S.n == base + #FIXTURE, "the fixture built",
     string.format("%d tracks, expected %d", S.n, base + #FIXTURE))
  ok(S[at(1)].name == "TMDRUMS", "and is where it was put", S[at(1)].name)

  -- Matching and folders, through the real snapshot ------------------------
  local drums_f  = Apply.resolve(S, "tmdrums*", true)
  local drums_nf = Apply.resolve(S, "tmdrums*", false)
  ok(ids(drums_f) == ids({ at(1), at(2), at(3) }),
     "folders on: the drum folder brings its two children", ids(drums_f))
  ok(ids(drums_nf) == tostring(at(1)),
     "folders off: only the folder track itself", ids(drums_nf))

  local gtr = Apply.resolve(S, "tmgtr*, -tmgtr ref", true)
  ok(ids(gtr) == tostring(at(4)), "exclusion removes the ref take", ids(gtr))

  -- Selection ---------------------------------------------------------------
  Apply.set_selected(S, drums_f, true, true)
  S = snap()
  ok(Apply.state(S, drums_f, "select") == "on", "an exclusive press selects")
  ok(Apply.state(S, gtr, "select") == "off",
     "and the other slot is not lit with it")
  ok(reaper.CountSelectedTracks(0) == #drums_f,
     "nothing else in the project is selected",
     tostring(reaper.CountSelectedTracks(0)))

  Apply.set_selected(S, gtr, true, false)   -- Ctrl+press
  S = snap()
  ok(Apply.state(S, drums_f, "select") == "on"
     and Apply.state(S, gtr, "select") == "on",
     "Ctrl accumulates: both slots lit")
  ok(reaper.CountSelectedTracks(0) == #drums_f + #gtr,
     "and only those two groups")

  Apply.set_selected(S, gtr, false, false)  -- Ctrl+press a lit slot
  S = snap()
  ok(Apply.state(S, gtr, "select") == "off"
     and Apply.state(S, drums_f, "select") == "on",
     "Ctrl on a lit slot removes just that group")

  Apply.set_selected(S, {}, false, true)    -- a plain press on a lit slot
  S = snap()
  ok(reaper.CountSelectedTracks(0) == 0, "a lit slot pressed plain clears all")

  Apply.all_selected(S, true)
  ok(reaper.CountSelectedTracks(0) == S.n, "numpad + selects every track")
  Apply.all_selected(S, false)
  ok(reaper.CountSelectedTracks(0) == 0, "numpad - deselects every track")

  -- Import from the selection ----------------------------------------------
  -- The headless suite covers the term-building; what it cannot say is that a
  -- name taken off a real track resolves back to that one track.
  Apply.set_selected(S, { at(4), at(6) }, true, true)
  S = snap()
  local imported, n_imported = Apply.selected_names(S, Config.NSLOTS)
  ok(n_imported == 2 and table.concat(imported, "|") == "TMGtr 1|TMVox",
     "import reads the selected names off the project, in project order",
     table.concat(imported, "|"))
  ok(ids(Apply.resolve(S, imported[1], true)) == tostring(at(4)),
     "an imported name resolves back to exactly the track it came from",
     ids(Apply.resolve(S, imported[1], true)))
  ok(ids(Apply.resolve(S, imported[2], true)) == tostring(at(6)),
     "and so does the second", ids(Apply.resolve(S, imported[2], true)))

  Apply.set_selected(S, drums_f, true, true)
  S = snap()
  local folder_import = Apply.selected_names(S, Config.NSLOTS)
  ok(ids(Apply.resolve(S, folder_import[1], true))
       == ids({ at(1), at(2), at(3) }),
     "a folder parent imports as its whole folder, as any slot would",
     ids(Apply.resolve(S, folder_import[1], true)))

  Apply.all_selected(S, false)
  S = snap()

  -- Visibility --------------------------------------------------------------
  ok(Apply.state(S, drums_f, "hide", "both") == "on",
     "a visible group is lit -- lit means present, in both modes")

  Apply.set_visible(S, drums_f, false, "tcp")
  S = snap()
  ok(S[at(1)].tcp == false, "scope tcp hides in the TCP")
  ok(S[at(1)].mcp == true,  "and leaves the mixer alone")
  ok(Apply.state(S, drums_f, "hide", "tcp") == "off", "dark under tcp")
  ok(Apply.state(S, drums_f, "hide", "mcp") == "on",
     "still lit under mcp, where it is still showing")
  ok(Apply.state(S, drums_f, "hide", "both") == "off",
     "and dark under both, because it is gone from one of them")

  Apply.set_visible(S, drums_f, true, "tcp")
  S = snap()
  ok(S[at(1)].tcp == true, "and shows again")
  ok(Apply.state(S, drums_f, "hide", "both") == "on", "lit once more")

  Apply.set_visible(S, drums_f, false, "both")
  S = snap()
  ok(S[at(1)].tcp == false and S[at(1)].mcp == false, "scope both hides in both")
  ok(Apply.state(S, drums_f, "hide", "both") == "off", "dark under both")
  ok(S[at(4)].tcp == true, "a track outside the slot is untouched")

  Apply.all_visible(S, true, "both")
  S = snap()
  ok(S[at(1)].tcp and S[at(1)].mcp, "numpad + shows every track")
  Apply.all_visible(S, false, "both")
  S = snap()
  ok(not S[at(1)].tcp and not S[at(4)].mcp, "numpad - hides every track")
  Apply.all_visible(S, true, "both")

  -- Folder levels -----------------------------------------------------------
  -- The setting is a lens on SHOWING and nothing else: it moves no track by
  -- itself, it never constrains a hide, and it leaves everything outside the
  -- action exactly as it was.
  --
  -- Levels are read off the project rather than assumed, because the fixture
  -- is appended to whatever the user already has open -- if their last track
  -- opened a folder, the whole fixture sits one level in.
  S = snap()
  local lv = Tracks.levels(S, S.n)
  local L0 = lv[at(1)]
  ok(lv[at(2)] == L0 + 1 and lv[at(3)] == L0 + 1,
     "the folder's tracks are one level in", tostring(lv[at(2)] - L0))
  ok(lv[at(4)] == L0, "a loose track sits on the folder parent's level")

  Apply.set_visible(S, drums_f, false, "both")
  S = snap()
  ok(not S[at(1)].tcp and not S[at(2)].tcp, "the group hides whole")

  Apply.set_visible(S, Apply.showable(S, drums_f, L0), true, "both")
  S = snap()
  ok(S[at(1)].tcp, "showing at the parent's level brings the parent back")
  ok(not S[at(2)].tcp and not S[at(3)].tcp,
     "and leaves the tracks inside it hidden")
  ok(Apply.state(S, drums_f, "hide", "both", L0) == "on",
     "fully lit through the same lens")
  ok(Apply.state(S, drums_f, "hide", "both", L0 + 1) == "mixed",
     "and only half done once the next level is exposed")

  Apply.set_visible(S, Apply.showable(S, drums_f, L0 + 1), true, "both")
  S = snap()
  ok(S[at(2)].tcp and S[at(3)].tcp, "one level deeper exposes them")
  ok(Apply.state(S, drums_f, "hide", "both", L0 + 1) == "on", "and lights up")

  Apply.set_visible(S, drums_f, false, "both")
  S = snap()
  ok(not S[at(2)].tcp, "hiding is never filtered by the lens")

  Apply.all_visible(S, true, "both", L0)
  S = snap()
  ok(S[at(1)].tcp and S[at(4)].tcp, "show-all reaches the shallow tracks")
  ok(not S[at(2)].tcp, "and does not reach past the lens")

  Apply.set_visible(S, { at(2) }, true, "both")
  S = snap()
  ok(S[at(2)].tcp, "a deep track shown by hand is showing")
  Apply.all_visible(S, true, "both", L0)
  S = snap()
  ok(S[at(2)].tcp,
     "and show-all leaves it as it was -- the lens hides nothing")

  Apply.all_visible(S, true, "both")

  -- Mute and solo -----------------------------------------------------------
  -- Lit means ENGAGED in this mode, which is the one place the panel inverts
  -- its own rule, so the assertions read the other way round from the ones
  -- above: on means muted.
  S = snap()
  ok(Apply.state(S, gtr, "mute") == "off", "an unmuted group is dark")

  Apply.set_flag(S, drums_f, "mute", true)
  S = snap()
  ok(S[at(1)].mute and S[at(2)].mute, "mute reaches the whole folder")
  ok(Apply.state(S, drums_f, "mute") == "on", "and lights the red square")
  ok(not S[at(4)].mute, "a track outside the slot is untouched")
  ok(Apply.state(S, drums_f, "solo") == "off",
     "muting is not soloing -- the two squares are separate questions")
  ok(Apply.state(S, drums_f, "hide", "both") == "on",
     "and a muted track is still showing")

  Apply.set_flag(S, { at(2) }, "mute", false)
  S = snap()
  ok(Apply.state(S, drums_f, "mute") == "mixed", "half a group reads half-lit")

  Apply.set_flag(S, gtr, "solo", true)
  S = snap()
  ok(S[at(4)].solo, "solo engages")
  ok(Apply.state(S, gtr, "solo") == "on", "and lights the yellow square")
  ok(not S[at(4)].mute, "without touching mute")

  -- The panel has to write what the button writes, and 1 is not always it:
  -- I_SOLO 1 ignores routing, so a track whose master send is off and which
  -- reaches the mix only through a send goes silent under it. REAPER's button
  -- follows the "solo in place" preference, and this asks the action rather
  -- than a constant, so it holds whichever way that preference is set.
  local probe = S[at(6)].track
  reaper.Main_OnCommand(40297, 0)                 -- unselect all tracks
  reaper.SetMediaTrackInfo_Value(probe, "I_SELECTED", 1)
  reaper.Main_OnCommand(7, 0)                     -- toggle solo, as a click does
  local button = reaper.GetMediaTrackInfo_Value(probe, "I_SOLO")
  reaper.SetMediaTrackInfo_Value(probe, "I_SOLO", 0)
  local written = reaper.GetMediaTrackInfo_Value(S[at(4)].track, "I_SOLO")
  ok(written == button,
     "and writes exactly what a click on the solo button writes",
     string.format("panel %g vs button %g", written, button))

  -- Solo-in-place is still soloed, whichever the user's preference writes.
  reaper.SetMediaTrackInfo_Value(S[at(5)].track, "I_SOLO", 2)
  S = snap()
  ok(S[at(5)].solo, "a solo-in-place track reads as soloed")

  -- Solo-safe is routing the user set deliberately, and it is a flag of its
  -- own -- I_SOLO holds only 0, 1 or 2 on 7.75, so writing solo cannot carry
  -- it away. Asserted rather than assumed, because the API docs say otherwise.
  reaper.SetMediaTrackInfo_Value(S[at(5)].track, "B_SOLO_DEFEAT", 1)
  Apply.set_flag(S, { at(5) }, "solo", true)
  Apply.set_flag(S, { at(5) }, "solo", false)
  ok(reaper.GetMediaTrackInfo_Value(S[at(5)].track, "B_SOLO_DEFEAT") > 0.5,
     "a solo-safe track keeps its safe flag through a solo and an unsolo")
  reaper.SetMediaTrackInfo_Value(S[at(5)].track, "B_SOLO_DEFEAT", 0)

  -- The blunt instruments: the union of the slots, not the project.
  local both = Tracks.union({ drums_f, gtr }, S.n)
  ok(ids(both) == ids({ at(1), at(2), at(3), at(4) }),
     "two slots union into one list, in project order", ids(both))

  Apply.set_flag(S, both, "solo", true)
  S = snap()
  ok(Apply.state(S, both, "solo") == "on", "numpad + solos every slot")
  ok(not S[at(6)].solo, "and leaves a track no slot names alone")

  Apply.set_flag(S, both, "solo", false)
  S = snap()
  ok(Apply.state(S, both, "solo") == "off", "numpad - unsolos them again")
  ok(Apply.state(S, drums_f, "mute") == "mixed", "with the mutes left alone")

  Apply.set_flag(S, both, "mute", false)
  S = snap()
  ok(Apply.state(S, both, "mute") == "off", "Ctrl+numpad - unmutes every slot")
  reaper.SetMediaTrackInfo_Value(S[at(5)].track, "I_SOLO", 0)

  -- Project ExtState --------------------------------------------------------
  -- Under a section of its own, so the user's own saved slots are not the
  -- thing being overwritten, and cleared again below.
  local real = Config.PROJ_SECTION
  Config.PROJ_SECTION = "track_manager_test"
  local okp, perr = pcall(function()
    local a = Config.new()
    a.slots.hide[1], a.slots.hide[9] = "tmdrums*", "tmvox"
    a.slots.hide[5] = ""
    a.slots.solo[1] = "tmgtr*"
    a.mode, a.scope, a.include_folders = "hide", "mcp", false
    Config.save(a)

    local b = Config.new()
    ok(Config.load_proj(b), "the project reports settings of its own")
    ok(b.slots.hide[1] == "tmdrums*" and b.slots.hide[9] == "tmvox",
       "slots round-trip through the project",
       b.slots.hide[1] .. "/" .. b.slots.hide[9])
    ok(b.slots.solo[1] == "tmgtr*" and b.slots.select[1] == "",
       "each page keeps its own nine", b.slots.solo[1])
    ok(b.slots.hide[5] == "",
       "an empty slot comes back empty rather than missing",
       "[" .. b.slots.hide[5] .. "]")
    ok(b.mode == "hide" and b.scope == "mcp", "and so do the mode and scope")
    ok(b.include_folders == false,
       "a stored false is false, not the string 'false'",
       tostring(b.include_folders))

    reaper.SetProjExtState(0, Config.PROJ_SECTION, "", "")   -- clear the section
    local c = Config.new()
    ok(not Config.load_proj(c), "a cleared section reports nothing")
  end)
  Config.PROJ_SECTION = real
  if not okp then bail("project ExtState raised: " .. tostring(perr)) end
end

----------------------------------------------------------------------- run

if not reaper then
  bail("this suite needs REAPER")
else
  local saved = capture()
  local base = reaper.CountTracks(0)
  local made = build(base)
  local good, err = pcall(body, base)
  teardown(made)
  restore(saved)
  if not good then bail("the body raised: " .. tostring(err)) end
end

print(string.format("\nverify: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
