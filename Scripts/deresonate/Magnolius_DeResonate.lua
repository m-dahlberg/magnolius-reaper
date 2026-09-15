-- @description DeResonate
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/Magnolius-REAPER
-- @provides
--   [nomain] dr/*.lua
--   [nomain] dr/dsp/*.eel
-- @about
--   Finds fixed-frequency room resonances and broad room/mic colouration in a
--   close-mic vocal, and measures the room's decay time.
--
--   It uses the singer's own pitch to tell a resonance apart from a harmonic -
--   the distinction that makes automatic de-resonance possible at all, since a
--   sustained note and a ringing room mode look alike in a plain spectrum.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository. It is used both for the panel and, via
--   CreateFunctionFromEEL, for the analysis kernel.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- DeResonate
-- Finds fixed-frequency room resonances and broad room/mic colouration in a
-- close-mic vocal, using the singer's own pitch to tell a resonance apart from
-- a harmonic, and measures the room's decay time.
--
-- Requires ReaImGui (used both for the panel and, via CreateFunctionFromEEL,
-- for the analysis kernels).

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "DeResonate", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "dr.ui"

UI.start(ImGui, script_dir)
