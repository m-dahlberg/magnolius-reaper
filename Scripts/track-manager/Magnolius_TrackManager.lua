-- @description Track Manager
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] tm/*.lua
-- @about
--   Nine named track groups on a narrow always-on-top panel. Type a pattern
--   ('drums*', 'gtr*, -gtr ref') into a slot once, and from then on that
--   slot's button - or its numpad key - selects that group, hides it, or solos
--   and mutes it, depending on which of the three modes the panel is in.
--
--   Each mode has its own page of nine: the groups you reach for are rarely
--   the ones you hide, and neither is the handful you solo.
--
--   Slots save with the project, so a session opens with its own groups.
--   Presets are global, so the names you always use follow you between
--   sessions.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Track Manager
-- Nine named track groups on a narrow always-on-top panel: type a pattern
-- ("drums*", "gtr*, -gtr ref") into a slot once, and from then on that slot's
-- button -- or its numpad key -- selects that group, hides it, or solos and
-- mutes it, depending on which of the three modes the panel is in.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Track Manager", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "tm.ui"

UI.start(ImGui, script_dir)
