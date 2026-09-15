-- @noindex
-- Track Manager -- the only file that touches the project.
--
-- Keeping it to one file is what makes the undo behaviour reviewable, and here
-- it also isolates the two REAPER facts the whole panel depends on:
--
--   * Writing B_SHOWINTCP / B_SHOWINMIXER changes nothing on screen by
--     itself. TrackList_AdjustWindows is what makes the TCP and the mixer
--     re-lay themselves out; without it the tracks are hidden in the project
--     state and still drawn.
--   * Selection and solo changes deliberately get NO undo block. This panel's
--     whole point is that a numpad key is cheap, and an undo point per
--     keypress would bury the edits either side of it. Visibility and mute do
--     get one -- hiding or muting thirty tracks is worth being able to take
--     back, and unlike a solo a mute survives into the render.
--
-- Everything reads from a snapshot taken once per frame rather than asking the
-- project nine times. That is not only speed: it means the nine slots, the
-- lights and the tooltips all describe the same instant.

local Match  = require "tm.match"
local Tracks = require "tm.tracks"

local M = {}

function M.snapshot()
  local snap = { n = 0 }
  if not reaper then return snap end
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    snap[i + 1] = {
      track    = tr,
      name     = name,
      depth    = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")),
      selected = reaper.GetMediaTrackInfo_Value(tr, "I_SELECTED")   > 0.5,
      tcp      = reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP")  > 0.5,
      mcp      = reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER") > 0.5,
      mute     = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0.5,
      -- I_SOLO is 1 for solo and 2 for solo-in-place, and either is soloed.
      -- The API docs also list 5 and 6 for "safe solo", and on 7.75 those are
      -- neither writable nor readable: writing 4, 5 or 6 lands as 0. Solo-safe
      -- is B_SOLO_DEFEAT, a flag of its own that I_SOLO never carries.
      solo     = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0.5,
    }
  end
  snap.n = n
  return snap
end

-- Slot text -> the track indices it names, in project order.
function M.resolve(snap, text, include_folders)
  local p = Match.parse(text)
  if p.empty then return {} end
  local hit = {}
  for i = 1, snap.n do
    if Match.matches(p, snap[i].name) then hit[i] = true end
  end
  if include_folders then hit = Tracks.expand_folders(snap, hit, snap.n) end
  return Tracks.to_list(hit, snap.n)
end

-- The selected tracks' names as slot terms, in project order, at most `limit`
-- of them -- plus how many there were, so the panel can say when it is taking
-- the first nine of more.
--
-- Read off the same per-frame snapshot as everything else, so what the button
-- imports is what the lights and the tooltips are describing.
--
-- An unnamed track is skipped rather than given a slot: matching is on names,
-- so a nameless track cannot be a group, and a slot spent on one would be a
-- dead square sitting where the user expected the next name along.
function M.selected_names(snap, limit)
  local out, total = {}, 0
  for i = 1, snap.n do
    local t = snap[i]
    if t.selected and (t.name or "") ~= "" then
      total = total + 1
      if not limit or #out < limit then out[#out + 1] = Match.literal(t.name) end
    end
  end
  return out, total
end

-- Nesting levels are a property of the snapshot, so they are computed once and
-- kept on it: nine slots and the bulk buttons all ask, and a hand-built
-- snapshot in a test gets the same treatment without having to know.
local function levels_of(snap)
  if not snap.level then snap.level = Tracks.levels(snap, snap.n) end
  return snap.level
end

-- Which of these tracks a SHOW would actually reveal.
--
-- The folder-level setting is a lens on showing and on nothing else. It never
-- moves a track by itself and it never constrains hiding: a group is hidden
-- whole, and revealed only as deep as the setting reaches. Everything outside
-- the action is left exactly as the user left it.
function M.showable(snap, idxs, levels)
  if not levels then return idxs end
  local lv, out = levels_of(snap), {}
  for _, i in ipairs(idxs) do
    if lv[i] <= levels then out[#out + 1] = i end
  end
  return out
end

-- "Showing" against the chosen scope. Both means both: a track gone from the
-- mixer is not showing, so a slot that has only been applied to the TCP reads
-- as mixed rather than dark, and pressing it finishes the job instead of
-- undoing half of it.
local function showing(t, scope)
  if scope == "tcp" then return t.tcp end
  if scope == "mcp" then return t.mcp end
  return t.tcp and t.mcp
end

-- What lights the square. Lit means PRESENT in both modes -- selected in
-- select mode, visible in hide mode -- so the lights read as "here is what you
-- have", and a dark square is a group that is gone. Read off the project every
-- frame and never stored, so hiding a track by hand cannot desync the panel.
-- `mode` is the panel's mode -- select, hide -- or one of the two questions the
-- Solo/Mute row asks, "mute" and "solo". Lit means SELECTED or SHOWING in the
-- first two and ENGAGED in the last two, which is a deliberate inversion: red
-- means muted everywhere in every DAW, and a red square that lit for an
-- unmuted track would be a worse lie than the inconsistency.
function M.state(snap, idxs, mode, scope, levels)
  -- In hide mode the tally runs over what the slot can REACH. A track below
  -- the level setting is not a job left undone -- the panel is not offering to
  -- show it -- so counting it would peg the light at half-lit forever. It is
  -- hide's lens alone: mute and solo reach every track a slot names.
  if mode == "hide" then idxs = M.showable(snap, idxs, levels) end
  if #idxs == 0 then return "off" end
  local on = 0
  for _, i in ipairs(idxs) do
    local t = snap[i]
    -- Written as an if, not as `(mode == "select") and t.selected or ...`.
    -- That form reads like a ternary and is not one: a track that is not
    -- selected makes the `and` fall through to the `or`, so in Select mode
    -- every HIDDEN track used to read as selected.
    local v
    if mode == "select" then v = t.selected
    elseif mode == "mute" then v = t.mute
    elseif mode == "solo" then v = t.solo
    else v = showing(t, scope) end
    if v then on = on + 1 end
  end
  if on == #idxs then return "on" end
  if on == 0 then return "off" end
  return "mixed"
end

------------------------------------------------------------------- writes

local function redraw()
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

function M.set_selected(snap, idxs, on, exclusive)
  reaper.PreventUIRefresh(1)
  if exclusive then
    for i = 1, snap.n do reaper.SetTrackSelected(snap[i].track, false) end
  end
  for _, i in ipairs(idxs) do reaper.SetTrackSelected(snap[i].track, on) end
  reaper.PreventUIRefresh(-1)
  redraw()
end

function M.all_selected(snap, on)
  M.set_selected(snap, {}, false, true)
  if not on then return end
  local all = {}
  for i = 1, snap.n do all[i] = i end
  M.set_selected(snap, all, true, false)
end

local function write_visible(snap, idxs, show, scope, undo)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  -- Nothing between here and PreventUIRefresh(-1) may return early: an
  -- unbalanced call leaves REAPER's UI frozen for the rest of the session.
  local v = show and 1 or 0
  for _, i in ipairs(idxs) do
    local tr = snap[i].track
    if scope ~= "mcp" then reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", v) end
    if scope ~= "tcp" then reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", v) end
  end
  reaper.PreventUIRefresh(-1)
  redraw()
  -- UNDO_STATE_TRACKCFG (1): visibility is track configuration, and asking for
  -- the whole project state here would snapshot every item on every keypress.
  reaper.Undo_EndBlock2(0, undo, 1)
end

function M.set_visible(snap, idxs, show, scope)
  if #idxs == 0 then return end
  write_visible(snap, idxs, show, scope,
                show and "Track Manager: show tracks"
                     or  "Track Manager: hide tracks")
end

-- What a press of the solo button would write, which is not always 1.
--
-- I_SOLO 1 is solo ignoring routing: the track goes straight to master and
-- everything else is silenced. 2 is solo-in-place, which keeps the track's own
-- routing, so a track with its master send off that feeds a bus is still
-- heard. REAPER's button picks between them from the "solo in place" setting,
-- and this panel has to make the same choice or it looks like a solo and
-- sounds like nothing. Measured on 7.75: soloip=0 -> the button writes 1,
-- soloip=1 -> it writes 2, and get_config_var_string tracks the preference
-- live, with no SWS needed. Read per press, because the setting can change
-- while the panel is open; solo-in-place is REAPER's default, so that is what
-- an unreadable setting falls back to.
local function solo_value()
  local ok, v = true, nil
  if reaper.get_config_var_string then
    ok, v = reaper.get_config_var_string("soloip")
  end
  if not ok then return 2 end
  return tonumber(v) == 0 and 1 or 2
end

-- Mute and solo, over the tracks a slot names.
--
-- Nothing here touches B_SOLO_DEFEAT -- so a solo-safe track, which is how a
-- reverb return stays audible under someone else's solo, keeps its safe flag
-- through any number of presses. That separation is REAPER's, not this file's:
-- I_SOLO holds only 0, 1 or 2 on 7.75, whatever the documented 5 and 6
-- suggest.
--
-- Mute gets an undo point and solo does not, which is the same trade
-- visibility and selection make. A mute is a mix decision and survives into
-- the render; a solo is monitoring and never leaves the room, and an undo
-- point on the most-pressed key in this mode would bury the edits either side
-- of it.
function M.set_flag(snap, idxs, what, on)
  if #idxs == 0 then return end
  local muting = what == "mute"
  if muting then reaper.Undo_BeginBlock() end
  reaper.PreventUIRefresh(1)
  -- Nothing between here and PreventUIRefresh(-1) may return early.
  local v = on and (muting and 1 or solo_value()) or 0
  for _, i in ipairs(idxs) do
    local tr = snap[i].track
    if muting then
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", v)
    else
      reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", v)
    end
  end
  reaper.PreventUIRefresh(-1)
  redraw()
  if muting then
    reaper.Undo_EndBlock2(0, on and "Track Manager: mute tracks"
                              or  "Track Manager: unmute tracks", 1)
  end
end

function M.all_visible(snap, show, scope, levels)
  local all = {}
  for i = 1, snap.n do all[i] = i end
  -- Show reaches only as deep as the setting; hide takes everything.
  if show then all = M.showable(snap, all, levels) end
  if #all == 0 then return end
  write_visible(snap, all, show, scope,
                show and "Track Manager: show all tracks"
                     or  "Track Manager: hide all tracks")
end

return M
