-- @noindex
-- Loudness Envelope -- the only file that touches the project.
--
-- Writes the curve as automation of the Vocal Rider's Target level on the
-- destination track. Measured on REAPER 7.75, and the reason this is simple:
-- a JSFX parameter envelope stores the slider's OWN units, so a point written
-- as -18 is -18 dB and the envelope interpolates linearly in dB -- exactly the
-- domain the curve was simplified in. (A volume envelope would not be: that
-- one interpolates in its own fader-scaled domain.)
--
-- Two more facts from the same probe shape the order of operations:
--
--   * GetFXEnvelope(..., create=true) creates the lane with ONE point already
--     in it, at time 0, holding the slider's current value. Left there, the
--     target would ramp from that value at the top of the song to the first
--     real point. A lane this file created is therefore emptied first.
--   * A lane that already existed belongs to the user, so only the span being
--     written is cleared -- the same rule Note Leveling's rider follows.
--   * DeleteEnvelopePointRange refuses to delete an envelope's last point, so
--     the seeded one cannot be removed that way. Points go by index instead.

local M = {}

-- The rider is recognised by name and its Target by parameter name. Both
-- checks, because the alternative failure -- automating whatever parameter 0
-- of whatever plugin happens to be first -- is silent.
M.FX_MATCH    = "vocal rider"
M.PARAM_MATCH = "target"
M.PARAM       = 0

-- Returns { fx = index, name = name } or nil + message. Pure read; the panel
-- calls it every frame to show the status line.
function M.find_rider(track)
  if not track then return nil, "Pick a destination track." end
  for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, fx, "")
    if name:lower():find(M.FX_MATCH, 1, true) then
      local _, pname = reaper.TrackFX_GetParamName(track, fx, M.PARAM, "")
      if not pname:lower():find(M.PARAM_MATCH, 1, true) then
        return nil, string.format(
          "%s has %q as parameter %d, not Target level -- refusing to automate it.",
          name, pname, M.PARAM + 1)
      end
      return { fx = fx, name = name, param_name = pname }
    end
  end
  return nil, "No Vocal Rider on the destination track. Add one first."
end

-- Automation modes that will overwrite the lane on playback rather than
-- read it. Not refused -- the user may mean it -- but reported.
local WRITING_MODES = { [2] = "Touch", [3] = "Write", [4] = "Latch",
                        [5] = "Latch Preview" }

-- Write `points` ({ {t, v}, ... } in project seconds and dB) over the span
-- t0..t1. Returns the number of points written and an optional warning, or
-- nil + message.
function M.write(track, points, t0, t1)
  local rider, err = M.find_rider(track)
  if not rider then return nil, err end
  if #points == 0 then return nil, "Nothing to write." end

  local existed = reaper.GetFXEnvelope(track, rider.fx, M.PARAM, false) ~= nil

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local ok, res = pcall(function()
    local env = reaper.GetFXEnvelope(track, rider.fx, M.PARAM, true)
    if not env then error("REAPER would not create the Target level envelope.", 0) end
    -- By index, back to front -- not DeleteEnvelopePointRange, which on
    -- 7.75 will not delete an envelope's LAST point: the seeded point of a
    -- fresh lane, or a lone user point inside the span, would survive it and
    -- sit among the curve's points. DeleteEnvelopePointEx has no such floor.
    for i = reaper.CountEnvelopePoints(env) - 1, 0, -1 do
      local _, t = reaper.GetEnvelopePoint(env, i)
      if not existed or (t >= t0 - 1e-6 and t <= t1 + 1e-6) then
        reaper.DeleteEnvelopePointEx(env, -1, i)
      end
    end
    local mode = reaper.GetEnvelopeScalingMode(env)
    for _, p in ipairs(points) do
      reaper.InsertEnvelopePoint(env, p.t, reaper.ScaleToEnvelopeMode(mode, p.v),
                                 0, 0, false, true)
    end
    reaper.Envelope_SortPoints(env)
    -- Write, THEN activate: an empty envelope cannot be activated.
    reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true)
    reaper.GetSetEnvelopeInfo_String(env, "VISIBLE", "1", true)
    return env
  end)
  -- Balanced whatever happened: an unbalanced PreventUIRefresh freezes
  -- REAPER's UI for the rest of the session.
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Loudness envelope: write Vocal Rider target", -1)
  if not ok then return nil, tostring(res) end

  local warn
  local mode = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_AUTOMODE"))
  if WRITING_MODES[mode] then
    warn = string.format("The destination track is in %s mode, which will overwrite this lane on playback.",
                         WRITING_MODES[mode])
  end
  return #points, warn, res
end

return M
