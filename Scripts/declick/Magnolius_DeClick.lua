-- @description DeClick
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] dc/*.lua
--   [nomain] dc/dsp/*.eel
-- @about
--   Finds and repairs mouth noise in vocal takes. The detection and repair are
--   a port of the DeClick JSFX (itself a port of Paul Licameli's
--   Audacity/Nyquist De-Clicker).
--
--   What is different here is that the sensitivity threshold is derived from
--   each file's own click distribution instead of dialled in - so a quiet take
--   and a loud one both get an appropriate threshold without adjustment.
--
--   See also the DeClick JSFX for the real-time version.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Adaptive De-Click
-- Finds and repairs mouth noise in vocal takes: the detection and repair are a
-- port of Magnolius_DeClick.jsfx (itself a port of Paul Licameli's Audacity/Nyquist
-- De-Clicker), and what is different here is that the sensitivity threshold is
-- derived from each file's own click distribution instead of dialled in.
--
-- Requires ReaImGui (used both for the panel and, via CreateFunctionFromEEL,
-- for the DSP kernel).

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Adaptive De-Click", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "dc.ui"

UI.start(ImGui, script_dir)
