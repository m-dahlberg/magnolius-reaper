-- @description Note Leveling
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/Magnolius-REAPER
-- @provides
--   [nomain] nl/*.lua
--   [nomain] nl/dsp/*.eel
--   [main] Magnolius_NoteLevelingRide.lua
-- @about
--   Levels a vocal per sung note rather than per sample. It detects pitch
--   every few milliseconds, clusters the pitch points into musical notes,
--   measures each note's RMS, and moves notes outside a floor/ceiling window
--   back toward it.
--
--   The result is written as track Volume (Pre-FX) automation, so the original
--   audio is untouched and the correction sits ahead of the vocal chain.
--
--   This package also installs 'Note Leveling - Ride against reference', a
--   no-panel action that rides the vocal against a reference track. Bind it to
--   a key or call it from another script.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Note Leveling
-- Levels a vocal per sung note rather than per sample: detects pitch every few
-- milliseconds, clusters the pitch points into musical notes, measures each
-- note's RMS, and moves notes outside a floor/ceiling window back toward it.
-- The result is written as track Volume (Pre-FX) automation, so the original
-- audio is untouched and the correction sits ahead of the vocal chain.
--
-- Ported from the Volume tab of the Vocal Editor app.
--
-- Requires ReaImGui (used both for the panel and, via CreateFunctionFromEEL,
-- for the pitch kernel).

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Note Leveling", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "nl.ui"

UI.start(ImGui, script_dir)
