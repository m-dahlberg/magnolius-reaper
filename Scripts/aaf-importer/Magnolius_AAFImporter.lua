-- @noindex   not published via ReaPack
-- @description AAF Importer
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] ai/*.lua
-- @about
--   Lists the tracks in a Pro Tools AAF export and imports one track's name,
--   volume, pan and automation onto the selected REAPER track, or as a new
--   track. Track settings only: no audio, clips or plugins.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- AAF Importer
-- Reads the AAF itself -- a compound file of AAF objects, parsed in pure Lua
-- -- so it needs nothing but ReaImGui. Pro Tools writes a track's volume
-- automation as a gain effect over each clip, with control points timed as
-- fractions of that clip; ai/model.lua turns those into seconds, and
-- ai/apply.lua writes them as the track's Volume envelope.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "AAF Importer", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "ai.ui"

UI.start(ImGui, script_dir)
