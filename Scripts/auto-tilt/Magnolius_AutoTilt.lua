-- @description Auto Tilt
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] at/*.lua
--   [nomain] at/dsp/*.eel
-- @about
--   Matches the spectral balance of one clip to another with a single tilt EQ.
--   It measures the high/low energy ratio of both about a pivot you set,
--   solves for the shelf-pair gain that equalises them, and renders the target
--   as a new take.
--
--   Offline and destructive-by-render: the original take is preserved
--   underneath, so the correction is always reversible.
--
--   See also the Auto Tilt JSFX, which does the same correction continuously
--   in real time.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- AutoTilt
-- Matches the spectral balance of one clip to another with a single tilt EQ:
-- measures the high/low energy ratio of both about a pivot you set, solves for
-- the shelf-pair gain that equalises them, and renders the target as a new take.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "AutoTilt", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "at.ui"

UI.start(ImGui, script_dir)
