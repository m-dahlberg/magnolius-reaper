-- @noindex
-- AAF Importer -- settings and their persistence.
--
-- Pure Lua apart from load/save, which are guarded, so the headless suite can
-- load it with no reaper at all.

local M = {}

M.EXT_SECTION = "magnolius_aaf_importer"

-- Where the AAF's first sample lands in REAPER. Index order is the panel's
-- dropdown order.
M.PLACEMENTS = { "zero", "cursor", "timecode" }
M.PLACEMENT_LABELS = {
  zero     = "AAF start at project start (0:00)",
  cursor   = "AAF start at the edit cursor",
  timecode = "Match timecode (uses the project start time)",
}

M.defaults = {
  -- The AAF last opened, reopened when the panel starts.
  last_path = "",
  placement = "zero",
  -- What to import.
  imp_name = true,
  imp_volume = true,
  imp_pan = true,
  imp_automation = true,
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

function M.placement_index(cfg)
  for i, p in ipairs(M.PLACEMENTS) do
    if p == cfg.placement then return i end
  end
  return 1
end

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    if M.defaults[k] ~= nil then
      reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
    end
  end
end

-- Types are recovered from the defaults, so a missing or corrupt key falls
-- back instead of erroring. Booleans compare against the string "true":
-- tostring(false) is "false", which Lua would read as true.
function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  for k, default in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      local s = reaper.GetExtState(M.EXT_SECTION, k)
      if type(default) == "number" then
        cfg[k] = tonumber(s) or default
      elseif type(default) == "boolean" then
        cfg[k] = (s == "true")
      else
        cfg[k] = s
      end
    end
  end
  if not M.PLACEMENT_LABELS[cfg.placement] then cfg.placement = M.defaults.placement end
  return cfg
end

return M
