-- @description Vocal Splitter
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] vs/*.lua
--   [nomain] vs/dsp/*.eel
-- @about
--   Segments a vocal take top-down into sections, phrases, breaths, hard
--   consonants and sibilance, then splits, levels and crossfades it.
--
--   Working top-down means the section boundaries are found before the phrase
--   boundaries and the phrases before the breaths, so a quiet breath inside a
--   loud phrase is still found as a breath.
--
--   See also the Vocal Splitter JSFX, which separates the same classes in real
--   time as a four-way output split.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository. It is used both for the panel and, via
--   CreateFunctionFromEEL, for the analysis kernel.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Vocal Splitter
-- Segments a vocal take top-down into sections, phrases, breaths, hard
-- consonants and sibilance, then splits, levels and crossfades it.
--
-- Requires ReaImGui (used both for the panel and, via CreateFunctionFromEEL,
-- for the analysis kernel).

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Vocal Splitter", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "vs.ui"

UI.start(ImGui, script_dir)
