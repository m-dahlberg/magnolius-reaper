-- @noindex
-- Track Manager -- defaults and the three places settings live.
--
-- Pure enough to load headlessly: every function guards on `reaper` and hands
-- back the defaults when there is no REAPER to ask.
--
-- Each MODE has its own page of nine slots: the groups you want to reach in
-- Select are rarely the ones you want to hide, and neither is the handful you
-- solo. All three pages live in every store together.
--
-- Three stores, because they answer three different questions:
--
--   project ExtState   what THIS session's nine slots are. REAPER writes it
--                      into the .RPP, so it saves and loads with the session,
--                      which is the whole point of the feature.
--   global  ExtState   what the slots were last time, so a brand-new project
--                      opens with something in it rather than nine blanks.
--   presets (global)   named sets of nine, shared across every project.
--
-- Both of the first two are written on every edit. The project one wins on
-- load when it is there, and PRESENT_KEY is how "there" is decided -- an empty
-- slot stores an empty string, SetProjExtState deletes a key set to empty, and
-- a missing key is therefore indistinguishable from an empty slot. One marker
-- key settles it for all nine.
--
-- That marker carries the FORMAT with it, which is what makes the move to
-- pages safe: "1" is a session saved when nine slots were shared by every
-- mode, and it loads by seeding all three pages with those nine rather than
-- opening blank.

local M = {}

M.EXT_SECTION = "track_manager"
M.PROJ_SECTION = "track_manager"
M.PRESENT_KEY = "saved"
M.FORMAT = "2"          -- "1": one set of nine slots shared by every mode
M.NSLOTS = 9

-- The three modes, in the order numpad / cycles them. Pure, so the cycle is
-- testable without a panel -- and an unrecognised mode falls back to the first
-- rather than sticking, which is what a hand-edited .RPP would produce.
M.MODES = { "select", "hide", "solo" }

function M.next_mode(mode)
  for i, m in ipairs(M.MODES) do
    if m == mode then return M.MODES[i % #M.MODES + 1] end
  end
  return M.MODES[1]
end

M.defaults = {
  mode            = "select",   -- select | hide | solo
  scope           = "both",     -- tcp | mcp | both
  include_folders = true,
  -- How many levels of folder nesting stay visible. 2 shows top-level tracks,
  -- folder parents and everything one level in -- including subfolder parents,
  -- but not what is inside them. Applied when it is changed and not on load:
  -- reopening a session must not overwrite the visibility it was saved with.
  folder_levels   = 2,
}

-- cfg.slots and cfg.preset are keyed by MODE, not by index: cfg.slots.hide[3]
-- is the third slot of the Hide page, and cfg.preset.hide is the preset name
-- that page's combo is showing.
function M.new()
  local cfg = {}
  for k, v in pairs(M.defaults) do cfg[k] = v end
  cfg.slots, cfg.preset = {}, {}
  for _, m in ipairs(M.MODES) do
    cfg.slots[m] = {}
    for i = 1, M.NSLOTS do cfg.slots[m][i] = "" end
    cfg.preset[m] = ""
  end
  return cfg
end

-- Types come back off the default, so an absent or corrupt key falls back
-- rather than erroring. `tostring(false)` is "false", which is truthy in Lua,
-- so booleans must be compared as strings and not merely tested.
local function coerce(default, s)
  if type(default) == "number" then return tonumber(s) or default end
  if type(default) == "boolean" then return s == "true" end
  return s
end

local function slot_key(mode, i) return "slot." .. mode .. "." .. i end
local function loaded_key(mode) return "loaded." .. mode end

-- Format 1: one set of nine, and one loaded-preset name, for the whole panel.
local function slot_key_v1(i) return "slot." .. i end
local V1_LOADED = "preset"

------------------------------------------------------------------- global

local function save_global(cfg)
  for k in pairs(M.defaults) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(cfg[k]), true)
  end
  reaper.SetExtState(M.EXT_SECTION, M.PRESENT_KEY, M.FORMAT, true)
  for _, m in ipairs(M.MODES) do
    for i = 1, M.NSLOTS do
      reaper.SetExtState(M.EXT_SECTION, slot_key(m, i), cfg.slots[m][i] or "",
                         true)
    end
    reaper.SetExtState(M.EXT_SECTION, loaded_key(m), cfg.preset[m] or "", true)
  end
end

local function load_global(cfg)
  for k, default in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      cfg[k] = coerce(default, reaper.GetExtState(M.EXT_SECTION, k))
    end
  end
  -- No marker means the nine keys on disk are the shared set from format 1.
  -- Every page gets them: better than three blank pages on the first run
  -- after an update, and the next edit writes the pages out properly.
  local paged = reaper.GetExtState(M.EXT_SECTION, M.PRESENT_KEY) == M.FORMAT
  for _, m in ipairs(M.MODES) do
    for i = 1, M.NSLOTS do
      local k = paged and slot_key(m, i) or slot_key_v1(i)
      if reaper.HasExtState(M.EXT_SECTION, k) then
        cfg.slots[m][i] = reaper.GetExtState(M.EXT_SECTION, k)
      end
    end
    cfg.preset[m] = reaper.GetExtState(M.EXT_SECTION,
                                       paged and loaded_key(m) or V1_LOADED)
  end
end

------------------------------------------------------------------ project

local function save_proj(cfg)
  reaper.SetProjExtState(0, M.PROJ_SECTION, M.PRESENT_KEY, M.FORMAT)
  for k in pairs(M.defaults) do
    reaper.SetProjExtState(0, M.PROJ_SECTION, k, tostring(cfg[k]))
  end
  for _, m in ipairs(M.MODES) do
    for i = 1, M.NSLOTS do
      reaper.SetProjExtState(0, M.PROJ_SECTION, slot_key(m, i),
                             cfg.slots[m][i] or "")
    end
    reaper.SetProjExtState(0, M.PROJ_SECTION, loaded_key(m), cfg.preset[m] or "")
  end
end

local function proj_get(k)
  local _, v = reaper.GetProjExtState(0, M.PROJ_SECTION, k)
  return v
end

-- Returns true when this project had settings of its own.
function M.load_proj(cfg)
  if not reaper then return false end
  local ver = proj_get(M.PRESENT_KEY)
  if ver ~= "1" and ver ~= M.FORMAT then return false end
  for k, default in pairs(M.defaults) do
    cfg[k] = coerce(default, proj_get(k))
  end
  for _, m in ipairs(M.MODES) do
    for i = 1, M.NSLOTS do
      cfg.slots[m][i] = proj_get(ver == "1" and slot_key_v1(i)
                                             or slot_key(m, i))
    end
    cfg.preset[m] = proj_get(ver == "1" and V1_LOADED or loaded_key(m))
  end
  return true
end

--------------------------------------------------------------------- both

-- The single write entry point. Everything the panel edits goes through here,
-- which is also the one function a test has to stub to keep a stub-driven
-- frame from writing over the user's real settings.
function M.save(cfg)
  if not reaper then return end
  save_global(cfg)
  save_proj(cfg)
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  load_global(cfg)
  M.load_proj(cfg)
  return cfg
end

function M.reset(cfg)
  for k, v in pairs(M.defaults) do cfg[k] = v end
  for _, m in ipairs(M.MODES) do
    for i = 1, M.NSLOTS do cfg.slots[m][i] = "" end
    cfg.preset[m] = ""
  end
  M.save(cfg)
  return cfg
end

------------------------------------------------------------------ presets

-- A preset is one PAGE of nine, not the whole panel: Save stores the page you
-- are looking at and the combo recalls onto the page you are looking at, so a
-- set of drum groups can be dropped into Select today and Solo/Mute tomorrow.
--
-- One ExtState key per field -- preset.1.name, preset.1.slot.3 -- rather than
-- one key holding nine joined strings. Joining would need an escape, and an
-- escape is a bug waiting for the first person to put the delimiter in a track
-- name. Keys are cheap; ExtState is a flat ini file.

local function pkey(i, what) return "preset." .. i .. "." .. what end

function M.presets_load()
  if not reaper then return {} end
  local n = tonumber(reaper.GetExtState(M.EXT_SECTION, "preset.count")) or 0
  local out = {}
  for i = 1, n do
    local name = reaper.GetExtState(M.EXT_SECTION, pkey(i, "name"))
    if name ~= "" then
      local slots = {}
      for j = 1, M.NSLOTS do
        slots[j] = reaper.GetExtState(M.EXT_SECTION, pkey(i, "slot." .. j))
      end
      out[#out + 1] = { name = name, slots = slots }
    end
  end
  return out
end

local function presets_write(list)
  local old = tonumber(reaper.GetExtState(M.EXT_SECTION, "preset.count")) or 0
  for i, p in ipairs(list) do
    reaper.SetExtState(M.EXT_SECTION, pkey(i, "name"), p.name, true)
    for j = 1, M.NSLOTS do
      reaper.SetExtState(M.EXT_SECTION, pkey(i, "slot." .. j),
                         p.slots[j] or "", true)
    end
  end
  -- Delete down from the old count, or a shrinking list leaves orphan keys
  -- that reappear the next time the list grows back.
  for i = #list + 1, old do
    reaper.DeleteExtState(M.EXT_SECTION, pkey(i, "name"), true)
    for j = 1, M.NSLOTS do
      reaper.DeleteExtState(M.EXT_SECTION, pkey(i, "slot." .. j), true)
    end
  end
  reaper.SetExtState(M.EXT_SECTION, "preset.count", tostring(#list), true)
end

-- Overwrites by name, appends otherwise. Returns the stored list.
function M.preset_save(name, slots)
  if not reaper or name == "" then return M.presets_load() end
  local list = M.presets_load()
  local copy = {}
  for j = 1, M.NSLOTS do copy[j] = slots[j] or "" end
  local found = false
  for _, p in ipairs(list) do
    if p.name == name then p.slots, found = copy, true end
  end
  if not found then list[#list + 1] = { name = name, slots = copy } end
  presets_write(list)
  return list
end

function M.preset_delete(name)
  if not reaper then return {} end
  local list, out = M.presets_load(), {}
  for _, p in ipairs(list) do
    if p.name ~= name then out[#out + 1] = p end
  end
  presets_write(out)
  return out
end

return M
