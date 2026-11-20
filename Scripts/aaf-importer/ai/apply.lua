-- @noindex
-- AAF Importer -- the only file that touches the project.
--
-- M.plan is pure (no reaper) and decides WHAT to write from one AAF track and
-- the checkboxes; the headless suite tests it directly. M.apply and
-- M.insert_new carry a plan out inside one undo block.
--
-- Measured on REAPER 7.75 before this was written:
--
--   * GetTrackEnvelopeByChunkName(track, "<VOLENV2" / "<PANENV2") hands back
--     the built-in Volume and Pan lanes even on a fresh track with no
--     envelopes -- with 0 points, inactive. So nothing has to be created; the
--     order is wipe the span, write, THEN activate (an empty envelope cannot
--     be activated).
--   * The Pan envelope runs the OTHER way from D_PAN: an envelope value of +1
--     formats as "100%L", while D_PAN = -1 is left. So the lane gets -pan.
--   * The Volume lane uses fader scaling (mode 1); values go through
--     ScaleToEnvelopeMode, which is what makes 0.5 read -6.02 dB.
--   * DeleteEnvelopePointRange keeps an envelope's last point, so points in
--     the span go by index, back to front.

local Model = require "ai.model"

local M = {}

-- Automation modes that overwrite a lane on playback rather than read it.
-- Reported, not refused.
local WRITING_MODES = { [2] = "Touch", [3] = "Write", [4] = "Latch",
                        [5] = "Latch Preview" }

-- What importing `tr` under `cfg` means:
--   name      string or nil
--   vol       D_VOL to set, or nil
--   pan       D_PAN to set (-1 = left), or nil
--   vol_pts   volume envelope points ({t, v=gain, shape}), or nil
--   pan_pts   pan envelope points ({t, v=D_PAN units, shape}), or nil
--   what      human-readable list of the above
--
-- The fader rules: a static lane goes to the fader and writes no envelope.
-- A lane that moves goes to the envelope; with Volume (or Pan) also ticked,
-- the fader is set to 0 dB (centre) so it does not add to the envelope, and
-- with only Volume ticked the fader takes the lane's opening value.
function M.plan(tr, cfg)
  local p = { what = {} }
  local function did(s) p.what[#p.what + 1] = s end

  if cfg.imp_name and tr.name and tr.name ~= "" then
    p.name = tr.name
    did(string.format("name %q", tr.name))
  end

  local V = tr.volume
  if V then
    if V.static then
      if cfg.imp_volume then p.vol = V.static did("volume " .. Model.fmt_db(V.static)) end
    else
      if cfg.imp_automation then
        p.vol_pts = V.points
        did(string.format("%d volume points", #V.points))
        if cfg.imp_volume then p.vol = 1.0 did("fader 0.0 dB") end
      elseif cfg.imp_volume then
        p.vol = V.first
        did("volume " .. Model.fmt_db(V.first) .. " (the automation's opening value)")
      end
    end
  end

  local A = tr.pan
  if A then
    if A.static then
      if cfg.imp_pan then p.pan = A.static did("pan " .. Model.fmt_pan(A.static)) end
    else
      if cfg.imp_automation then
        p.pan_pts = A.points
        did(string.format("%d pan points", #A.points))
        if cfg.imp_pan then p.pan = 0 did("pan C") end
      elseif cfg.imp_pan then
        p.pan = A.first
        did("pan " .. Model.fmt_pan(A.first) .. " (the automation's opening value)")
      end
    end
  end

  p.empty = #p.what == 0
  return p
end

-- Seconds to add to every AAF time.
function M.offset(cfg, model)
  if cfg.placement == "cursor" then
    return reaper.GetCursorPosition()
  elseif cfg.placement == "timecode" then
    if not (model and model.tc) then
      return nil, "This AAF has no timecode track, so it cannot be placed by timecode."
    end
    return model.tc.seconds - reaper.GetProjectTimeOffset(0, false)
  end
  return 0
end

-- Writes `pts` onto `env` shifted by `offset`, replacing only the span they
-- cover. Returns the number written, the number dropped below 0 s, and the
-- project times of the first and last point written.
local function write_lane(env, pts, offset, to_env)
  local t0, t1 = pts[1].t + offset, pts[#pts].t + offset
  for i = reaper.CountEnvelopePoints(env) - 1, 0, -1 do
    local _, t = reaper.GetEnvelopePoint(env, i)
    if t >= t0 - 1e-9 and t <= t1 + 1e-9 then
      reaper.DeleteEnvelopePointEx(env, -1, i)
    end
  end
  local mode = reaper.GetEnvelopeScalingMode(env)
  local n, dropped, first, last = 0, 0, nil, nil
  for _, p in ipairs(pts) do
    local t = p.t + offset
    if t < 0 then
      dropped = dropped + 1
    else
      reaper.InsertEnvelopePoint(env, t, to_env(mode, p.v), p.shape, 0, false, true)
      n = n + 1
      first, last = first or t, t
    end
  end
  reaper.Envelope_SortPoints(env)
  if n > 0 then
    reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true)
    reaper.GetSetEnvelopeInfo_String(env, "VISIBLE", "1", true)
  end
  return n, dropped, first, last
end

local function vol_to_env(mode, g) return reaper.ScaleToEnvelopeMode(mode, g) end
local function pan_to_env(_, p) return -p end

-- Carries out a plan on `track`. No undo block: the callers own that.
-- Records the project times the written envelope points span in p.span, so
-- the panel can say where they went: with Match timecode they can land an
-- hour into a project whose view sits at 0:00.
local function carry_out(track, p, offset)
  local dropped = 0
  local function spanned(first, last)
    if not first then return end
    if not p.span then p.span = { first, last } return end
    p.span[1] = math.min(p.span[1], first)
    p.span[2] = math.max(p.span[2], last)
  end
  if p.name then reaper.GetSetMediaTrackInfo_String(track, "P_NAME", p.name, true) end
  if p.vol then reaper.SetMediaTrackInfo_Value(track, "D_VOL", p.vol) end
  if p.pan then reaper.SetMediaTrackInfo_Value(track, "D_PAN", p.pan) end
  if p.vol_pts then
    local env = reaper.GetTrackEnvelopeByChunkName(track, "<VOLENV2")
    if not env then error("REAPER would not hand over the track's Volume envelope.", 0) end
    local _, d, a, b = write_lane(env, p.vol_pts, offset, vol_to_env)
    dropped = dropped + d
    spanned(a, b)
  end
  if p.pan_pts then
    local env = reaper.GetTrackEnvelopeByChunkName(track, "<PANENV2")
    if not env then error("REAPER would not hand over the track's Pan envelope.", 0) end
    local _, d, a, b = write_lane(env, p.pan_pts, offset, pan_to_env)
    dropped = dropped + d
    spanned(a, b)
  end
  return dropped
end

local function with_undo(label, fn)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local ok, res = pcall(fn)
  -- Balanced whatever happened: an unbalanced PreventUIRefresh freezes
  -- REAPER's UI for the rest of the session.
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(label, -1)
  return ok, res
end

local function warnings(track, p, dropped)
  local w = {}
  if dropped > 0 then
    w[#w + 1] = string.format("%d points fell before 0:00 and were left out -- check the placement.", dropped)
  end
  if p.vol_pts or p.pan_pts then
    local mode = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_AUTOMODE"))
    if WRITING_MODES[mode] then
      w[#w + 1] = string.format("The track is in %s mode, which will overwrite this automation on playback.",
                                WRITING_MODES[mode])
    end
  end
  return #w > 0 and table.concat(w, " ") or nil
end

-- Applies AAF track `tr` to `track`. Returns the plan and an optional warning,
-- or nil + message.
function M.apply(track, tr, cfg, offset)
  if not track then return nil, "Select a track in REAPER first." end
  local p = M.plan(tr, cfg)
  if p.empty then return nil, "Nothing to import with these boxes ticked." end
  local ok, res = with_undo("AAF import: apply " .. (tr.name or "track"), function()
    return carry_out(track, p, offset)
  end)
  if not ok then return nil, tostring(res) end
  return p, warnings(track, p, res)
end

-- Inserts a new track below the last selected one (or at the end) and applies
-- `tr` to it. Returns the new track, the plan and an optional warning.
function M.insert_new(tr, cfg, offset)
  local p = M.plan(tr, cfg)
  local track
  local ok, res = with_undo("AAF import: insert " .. (tr.name or "track"), function()
    local idx = reaper.CountTracks(0)
    local nsel = reaper.CountSelectedTracks(0)
    if nsel > 0 then
      local last = reaper.GetSelectedTrack(0, nsel - 1)
      idx = math.floor(reaper.GetMediaTrackInfo_Value(last, "IP_TRACKNUMBER"))
    end
    reaper.InsertTrackAtIndex(idx, true)
    track = reaper.GetTrack(0, idx)
    if not track then error("REAPER did not create the track.", 0) end
    reaper.SetOnlyTrackSelected(track)
    return carry_out(track, p, offset)
  end)
  if not ok then return nil, tostring(res) end
  return track, p, warnings(track, p, res)
end

return M
