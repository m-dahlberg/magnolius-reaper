-- @noindex   not published via ReaPack
-- @description Loudness Envelope
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] le/*.lua
--   [nomain] le/dsp/*.eel
-- @about
--   Measures the general loudness outline of a vocal track -- phrase by
--   phrase, not syllable by syllable -- and writes it as Target level
--   automation for the Vocal Rider (Magnolius) on another track.
--
--   Built for two takes of the same melody in different languages: the rider
--   on the second take aims at the first take's phrasing, while the
--   syllables, which fall in different places, are left out of the curve.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Loudness Envelope
-- Measures the source track in the Vocal Rider's own units (the louder
-- channel's energy through its 50 ms detector), keeps only the frames where
-- someone is singing, and draws a sliding median through them -- which does
-- not move for a syllable, and does move for a phrase. A zero-phase Gaussian
-- rounds it, gaps are bridged rather than dipped into, and depth/range/offset
-- shape it. The result is written as the rider's Target level envelope on the
-- destination track.
--
-- Requires ReaImGui, used both for the panel and, via CreateFunctionFromEEL,
-- for the measurement kernel.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Loudness Envelope", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "le.ui"

UI.start(ImGui, script_dir)
