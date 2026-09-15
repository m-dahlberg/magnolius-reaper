-- @description DeNoise
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] dn/*.lua
--   [nomain] dn/dsp/*.eel
-- @about
--   Offline spectral noise reduction. The DSP is a port of the DeNoise JSFX
--   (itself a port of libspecbleach by Luciano Dato).
--
--   What is different here is that the noise profile is derived from an
--   analysis of the whole file instead of a manual learn pass - there is no
--   need to find and select a passage of noise alone.
--
--   See also the DeNoise JSFX for the real-time version.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Spectral DeNoise
-- Offline spectral noise reduction for REAPER. The DSP is a port of the
-- SpectralDenoise JSFX (itself a port of libspecbleach by Luciano Dato); what
-- is different here is that the noise profile is derived from an analysis of
-- the whole file instead of a manual learn pass.
--
-- Requires ReaImGui (used both for the panel and, via CreateFunctionFromEEL,
-- for the DSP kernel).

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Spectral DeNoise", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "dn.ui"

UI.start(ImGui, script_dir)
