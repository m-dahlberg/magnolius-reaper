-- Ground-truth probe: does every slider line actually parse?
--
-- A JSFX header parse error has no error UI: the bad slider and usually every
-- slider after it simply vanish, and the plugin still loads. The only reliable
-- way to see it is to ask REAPER how many params the instance has.
--
-- Run: reaper -newinst -nosplash <proj.rpp> probe.lua
-- Writes the answer to $MIXREF_PROBE_OUT (stdout is not captured).

local out = os.getenv("MIXREF_PROBE_OUT") or "/tmp/mixref_probe.txt"
local fx_name = os.getenv("MIXREF_PROBE_FX") or "Magnolius_MixReference.jsfx"

local lines = {}
local function say(s) lines[#lines + 1] = s end

reaper.InsertTrackAtIndex(0, false)
local tr = reaper.GetTrack(0, 0)
if not tr then
  say("ERROR no track")
else
  local fx = reaper.TrackFX_AddByName(tr, fx_name, false, -1)
  if fx < 0 then
    say("ERROR TrackFX_AddByName failed for " .. fx_name)
  else
    local n = reaper.TrackFX_GetNumParams(tr, fx)
    say("NUMPARAMS " .. n)
    for i = 0, n - 1 do
      local _, nm = reaper.TrackFX_GetParamName(tr, fx, i, "")
      local v, mn, mx = reaper.TrackFX_GetParam(tr, fx, i)
      say(string.format("PARAM %d %s|%.6f|%.6f|%.6f", i, nm, v, mn, mx))
    end
  end
end

local f = io.open(out, "w")
f:write(table.concat(lines, "\n") .. "\n")
f:close()

reaper.Main_SaveProject(0, false)   -- clear the dirty flag...
reaper.Main_OnCommand(40004, 0)     -- ...so File:Quit exits without a dialog
