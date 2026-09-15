-- @description Vocal Normalizer
-- @author Magnolius
-- @version 1.0
-- @link GitHub https://github.com/m-dahlberg/magnolius-reaper
-- @provides
--   [nomain] vn/*.lua
--   [nomain] vn/dsp/*.eel
-- @about
--   Normalises vocal clips to a target loudness measured through the frequency
--   range the melody's fundamentals occupy, rather than across the whole
--   spectrum.
--
--   Ordinary LUFS normalisation is K-weighted, which adds high-frequency
--   weight - so a breathy or sibilant take reads louder than it sounds and
--   gets pushed down, while a dark take gets pushed up. Measuring in the
--   fundamental range instead makes clips match by the part of the sound that
--   carries the melody.
--
--   Requires ReaImGui, which ReaPack will not install for you - get it from
--   the ReaTeam Extensions repository.
--
--   Licensed GPL-3.0-or-later.
-- @changelog
--   Initial ReaPack release

-- Vocal Normalizer
-- Normalises vocal clips to a target loudness measured through the frequency
-- range the melody's fundamentals occupy, rather than across the whole
-- spectrum.
--
-- The problem it solves: ordinary LUFS normalisation is K-weighted, which adds
-- a +4 dB shelf above 1.5 kHz on top of a measurement that already counts
-- every joule in the signal. So a bright, close, sibilant vocal MEASURES
-- several dB hotter than a soft one singing the same line at the same
-- perceived level, and gets turned down by the difference. Two takes that
-- measure identically then sound nothing alike. Restricting the measurement to
-- roughly 100..1000 Hz removes both halves of that -- the shelf is outside the
-- band and so is the sibilance -- while keeping BS.1770's gating, which is the
-- part of the standard that is right.
--
-- Nothing is rendered and no audio is written: the gain lands on take volume
-- (or item volume), so every pass is one undo and one number.
--
-- Requires ReaImGui, used both for the panel and, via CreateFunctionFromEEL,
-- for the measurement kernel.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script requires ReaImGui. Install it from ReaPack.",
            "Vocal Normalizer", 0)
  return
end

package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;"
            .. package.path

local ImGui = require "imgui" "0.9"
local UI = require "vn.ui"

UI.start(ImGui, script_dir)
