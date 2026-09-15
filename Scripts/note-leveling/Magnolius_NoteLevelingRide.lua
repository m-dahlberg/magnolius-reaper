-- @noindex
-- Note Leveling -- Ride vocal against reference (no panel)
--
-- Part 2 as a plain action: resolve the selection, read, ride, write, report.
-- No window, no defer loop, so it can be bound to a key, called from another
-- script, or run over a list of takes without anyone watching.
--
-- Every parameter comes from ExtState, which is where the panel leaves them,
-- so the workflow this is built for is "tune it once on one song in the panel,
-- then run this on the other forty". Set `rider_target_track` in the panel
-- first if the auto rule -- the selected audio on the highest-numbered track
-- is the target -- does not suit the session's layout.
--
-- ReaImGui is still required even though nothing is drawn: the pitch and level
-- kernels are EEL compiled through CreateFunctionFromEEL, and that lives in
-- ReaImGui. The context is created and never shown.

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

local ImGui   = require "imgui" "0.9"
local Config  = require "nl.config"
local Kernel  = require "nl.kernel"
local Analyze = require "nl.analyze"
local Apply   = require "nl.apply"
local Ride    = require "nl.ride"
local Select  = require "nl.select"

local function log(fmt, ...)
  reaper.ShowConsoleMsg(string.format(fmt .. "\n", ...))
end

local cfg = Config.load()
local ctx = ImGui.CreateContext("Note Leveling (headless)")

local sel = Select.resolve(cfg)
if sel.err then
  reaper.MB(sel.err, "Note Leveling -- ride", 0)
  return
end
log("Note Leveling -- ride")
log("  %s", Select.describe(sel))

-- One kernel per (channel count, sample rate): the memory map is fixed by
-- both, so a stereo 48 k reference and a mono 44.1 k vocal cannot share one.
-- Kept rather than rebuilt per clip, because a session's clips are usually all
-- the same format and compiling EEL per item would dominate the run.
local kernels = {}
local function ensure_kernel(nchan, rate)
  local key = Config.kernel_sig(cfg, nchan) .. "|" .. rate
  if kernels[key] then
    kernels[key]:set_yin_threshold(cfg.yin_threshold)
    return kernels[key]
  end
  local k, err = Kernel.new(ImGui, ctx, script_dir, nchan, cfg, rate)
  if not k then return nil, err end
  kernels[key] = k
  return k
end

-- Analyze.drive runs the job to completion on this thread, servicing the read
-- requests it yields. That is the whole reason the job yields them rather than
-- reading: GetAudioAccessorSamples returns nil inside a coroutine and leaves
-- the buffer untouched, so a job that read its own audio would analyse silence.
local data, err = Analyze.drive(Ride.analyse(sel, cfg, ensure_kernel, nil))
if not data then
  reaper.MB(tostring(err or "analysis failed"), "Note Leveling -- ride", 0)
  return
end

local rd = Ride.derive(data, cfg)
if #rd == 0 then
  reaper.MB("Nothing to ride.", "Note Leveling -- ride", 0)
  return
end

local results = {}
for _, d in ipairs(rd) do
  log("  %s", Ride.describe(d, cfg))
  results[#results + 1] = {
    item = d.item, take = d.take, geo = d.geo,
    points = d.points, prefx_points = d.prefx_points, segs = d.segs,
  }
end

local nride, npre = Apply.ride(results, cfg)
if not nride then
  reaper.MB(tostring(npre), "Note Leveling -- ride", 0)
  return
end
log("  wrote %d ride points%s", nride,
    cfg.rider_after_notes and string.format(" and %d Pre-FX points", npre) or "")
