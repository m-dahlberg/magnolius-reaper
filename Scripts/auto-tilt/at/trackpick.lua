-- @noindex
-- Track roles: a dropdown, plus a typed track name that overrides it.
--
-- The same control in three scripts now, so it lives in one file that is copied between them
-- rather than rewritten. Origin: the Quicktune script's `qt/select.lua` and its `track_picker`
-- widget. Keep the copies identical; a fix belongs in all of them.
--
-- A role is stored as THREE settings under one prefix:
--
--   <prefix>_guid      the track's GUID, written when you pick from the dropdown
--   <prefix>_name      its name at that moment
--   <prefix>_override  a name you typed, which wins over both
--
-- All three because they fail in different directions. A GUID survives renaming and reordering
-- but not a track being deleted and rebuilt -- which is exactly what happens when a guide or a
-- stem gets re-rendered by another pass. A name survives that, and breaks when two tracks share
-- one. The typed override exists for the case the dropdown cannot express: naming a track that
-- does not exist yet, so the setting is ready when it does.
--
-- Resolution order is therefore: typed name, then GUID, then remembered name. A typed name that
-- matches nothing is an ERROR rather than a fallback -- silently ignoring it and using the old
-- GUID would process the wrong track and say nothing.
--
-- Nothing here raises. Callers get a nil plus a message, because the panel asks every frame and
-- wants to report the problem, not stop.
--
-- ImGui is passed in rather than required, so the widget can be driven by the frame test's stub
-- and the module stays loadable headlessly.

local M = {}

--- The settings one role needs, as a table to merge into a config's defaults.
function M.defaults(prefix)
  return {
    [prefix .. "_guid"] = "",
    [prefix .. "_name"] = "",
    [prefix .. "_override"] = "",
  }
end

--- The same three key names, for a parameter-class signature.
function M.sig_keys(prefix)
  return { prefix .. "_guid", prefix .. "_name", prefix .. "_override" }
end

--- Every track in the project, in project order.
function M.tracks()
  local out = {}
  if not reaper then return out end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    out[#out + 1] = {
      track = tr,
      name = (name ~= "" and name or ("Track " .. (i + 1))),
      guid = reaper.GetTrackGUID(tr),
      index = i,
      num = i + 1,
    }
  end
  return out
end

--- Resolve one role. Pure: `tracks` is the table above, so this is unit-testable.
function M.find(tracks, override, guid, name)
  if override and override ~= "" then
    for _, t in ipairs(tracks) do
      if t.name:lower() == override:lower() then return t end
    end
    return nil, string.format("no track named %q", override)
  end
  if guid and guid ~= "" then
    for _, t in ipairs(tracks) do if t.guid == guid then return t end end
  end
  if name and name ~= "" then
    for _, t in ipairs(tracks) do if t.name == name then return t end end
  end
  return nil
end

--- Resolve a role straight out of a config.
function M.resolve(tracks, cfg, prefix)
  return M.find(tracks,
    cfg[prefix .. "_override"], cfg[prefix .. "_guid"], cfg[prefix .. "_name"])
end

--- Is a role set at all? A role nobody has pointed anywhere is not an error, it is empty.
function M.is_set(cfg, prefix)
  return (cfg[prefix .. "_override"] or "") ~= ""
      or (cfg[prefix .. "_guid"] or "") ~= ""
      or (cfg[prefix .. "_name"] or "") ~= ""
end

function M.clear(cfg, prefix)
  cfg[prefix .. "_guid"], cfg[prefix .. "_name"], cfg[prefix .. "_override"] = "", "", ""
end

--- Every audio item on a track, in position order, as { item = , take = }.
--- MIDI takes and empty items are skipped; an item whose active take is MIDI is not audio even
--- when the item has audio takes behind it, because the active take is what would be read.
function M.items(track)
  local out = {}
  if not track then return out end
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = item and reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      out[#out + 1] = { item = item, take = take }
    end
  end
  table.sort(out, function(a, b)
    return reaper.GetMediaItemInfo_Value(a.item, "D_POSITION")
         < reaper.GetMediaItemInfo_Value(b.item, "D_POSITION")
  end)
  return out
end

--- A short label for a resolved role, for the panel and for a headless log.
function M.label(resolved, empty)
  if not resolved then return empty or "(none)" end
  return resolved.name
end

--- The control: a dropdown and a name box, drawn as one row per role.
---
--- `on_change` is called after any edit, so the caller can persist and invalidate. Returns true
--- when something changed this frame.
---
--- Picking from the dropdown CLEARS the typed override -- otherwise the override would go on
--- silently winning and the dropdown would look broken.
function M.widget(ImGui, ctx, label, cfg, prefix, tracks, resolved, err, on_change)
  local guid_key, name_key = prefix .. "_guid", prefix .. "_name"
  local over_key = prefix .. "_override"
  local picked = false

  if ImGui.BeginCombo(ctx, label, M.label(resolved)) then
    if ImGui.Selectable(ctx, "(none)", resolved == nil) then
      M.clear(cfg, prefix)
      picked = true
    end
    for _, t in ipairs(tracks) do
      local selected = resolved ~= nil and resolved.guid == t.guid
      if ImGui.Selectable(ctx, t.num .. ": " .. t.name .. "##" .. t.guid, selected) then
        cfg[guid_key], cfg[name_key], cfg[over_key] = t.guid, t.name, ""
        picked = true
      end
    end
    ImGui.EndCombo(ctx)
  end

  ImGui.SetNextItemWidth(ctx, 180)
  local rv, text = ImGui.InputText(ctx, "by name##" .. prefix, cfg[over_key] or "")
  if rv then cfg[over_key] = text end

  -- on_change throws away a cached analysis, so it fires on a COMMIT only. Firing per keystroke
  -- would re-read the audio while the name is still half-typed.
  local committed = ImGui.IsItemDeactivatedAfterEdit(ctx)

  if err then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, err)
  end

  if (picked or committed) and on_change then on_change() end
  return picked or committed
end

return M
