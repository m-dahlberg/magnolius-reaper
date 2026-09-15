-- @noindex
-- Adaptive De-Click -- the CSV row.
--
-- Pure Lua. One row per processed item: what the file was, what the two
-- estimators said, what was actually used, and how much got repaired. The
-- point of it is that a bad result in a long session is findable afterwards --
-- the panel only ever shows you the item in front of you.

local M = {}

M.COLUMNS = {
  "time", "item", "rate", "seconds", "channels",
  "tail_db", "knee_db", "derived_db", "offset_db", "sens_used_db",
  "events", "repaired_pct", "retries", "budget_exceeded",
  "bands", "phases", "step_ms", "mode", "elapsed_s", "note",
}

local function csv_escape(v)
  local s = tostring(v == nil and "" or v)
  if s:find('[",\n]') then return '"' .. s:gsub('"', '""') .. '"' end
  return s
end

function M.header()
  local t = {}
  for i, c in ipairs(M.COLUMNS) do t[i] = csv_escape(c) end
  return table.concat(t, ",")
end

local function fmt(v, places)
  if v == nil then return "" end
  return string.format("%." .. places .. "f", v)
end

function M.row(rec)
  local th, st, cfg = rec.th or {}, (rec.th or {}).stats or {}, rec.cfg or {}
  local vals = {
    rec.time or "", rec.name or "", rec.rate or "",
    fmt(rec.seconds, 3), rec.channels or "",
    fmt(th.tail_db, 2), fmt(th.knee_db, 2), fmt(th.derived_db, 2),
    fmt(cfg.sens_offset_db, 2), fmt(th.sens_used, 2),
    st.events or 0, fmt((st.repaired or 0) * 100, 4),
    th.retries or 0, th.budget_exceeded and "yes" or "no",
    cfg.nbands or "", cfg.nphases or "", fmt(cfg.step_ms, 2),
    rec.mode or "", fmt(rec.elapsed, 2), rec.note or "",
  }
  local t = {}
  for i, v in ipairs(vals) do t[i] = csv_escape(v) end
  return table.concat(t, ",")
end

-- Appends, writing the header only when creating the file, so a directory of
-- takes accumulates into one auditable table across sessions.
function M.append(path, rec)
  local exists = false
  local fh = io.open(path, "rb")
  if fh then exists = true fh:close() end
  local out, err = io.open(path, "ab")
  if not out then return nil, err end
  if not exists then out:write(M.header(), "\n") end
  out:write(M.row(rec), "\n")
  out:close()
  return true
end

return M
