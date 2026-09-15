-- @noindex
-- Vocal Normalizer -- stage 4: write the gain.
--
-- The only module that touches the project. Everything it writes is one
-- number per clip, so the whole of this file is about getting that number into
-- the right place without disturbing anything else.
--
-- Where it goes: take volume (D_VOL on the take) by default, item volume on
-- request. Take volume is the default because it belongs to the take -- flip
-- to another take of the same recording and that take keeps its own gain, so
-- comping and normalising do not fight.
--
-- Three facts shape the arithmetic:
--
--   * The audio accessor applies NEITHER take volume nor item volume, so the
--     measurement is of the raw file. plan.lua folds the existing volume back
--     in, which makes its `gain_db` a MOVE against what the item currently
--     puts out. So the new setting is the old total times the move, and
--     normalising an already-normalised clip writes the same number back.
--   * The two volumes multiply. Writing take volume while item volume sits at
--     -6 dB has to account for the -6, or the clip lands 6 dB under target.
--     So the setting written is the wanted total divided by whatever the
--     other one is.
--   * Take volume is SIGNED: a negative D_VOL is that take's polarity flip,
--     not a negative gain. The sign is preserved rather than recomputed, or
--     normalising would silently un-flip a deliberately inverted take.
--
-- What it does not touch: track volume, envelopes, the source file, and the
-- take's stretch properties. A normalizer that rendered new audio would make
-- itself un-undoable for the sake of a multiply the mixer does for free.

local M = {}

local function split_gain(row, cfg)
  local want = row.vol_lin * 10 ^ (row.gain_db / 20)
  local partner
  if cfg.apply_to == "item" then
    partner = math.abs(row.geo.take_vol or 1)
  else
    partner = math.abs(row.geo.item_vol or 1)
  end
  -- The other volume is at -inf, so no setting of this one reaches the target.
  -- Write the total unscaled and let the caller report it rather than dividing
  -- by zero and writing an infinity into the project file.
  if partner <= 1e-9 then return want, false end
  return want / partner, true
end

-- rows: the priced rows from vn.plan. Rows without a gain are skipped.
-- Returns nwritten, nskipped, err.
function M.run(rows, cfg)
  local todo = {}
  for _, r in ipairs(rows) do
    if r.gain_db then todo[#todo + 1] = r end
  end
  if #todo == 0 then return 0, #rows, "Nothing measurable to apply" end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- No early return between here and PreventUIRefresh(-1): an unbalanced call
  -- leaves REAPER's UI frozen for the rest of the session. Problems are
  -- collected and reported after the block closes.
  local nwritten, stranded = 0, 0

  for _, r in ipairs(todo) do
    local v, clean = split_gain(r, cfg)
    if not clean then stranded = stranded + 1 end

    if cfg.apply_to == "item" then
      local old = reaper.GetMediaItemInfo_Value(r.item, "D_VOL")
      local sign = (old < 0) and -1 or 1
      reaper.SetMediaItemInfo_Value(r.item, "D_VOL", sign * v)
    else
      local old = reaper.GetMediaItemTakeInfo_Value(r.take, "D_VOL")
      local sign = (old < 0) and -1 or 1
      reaper.SetMediaItemTakeInfo_Value(r.take, "D_VOL", sign * v)
    end
    nwritten = nwritten + 1

    if cfg.write_note then
      reaper.GetSetMediaItemInfo_String(r.item, "P_EXT:vocalnorm",
        string.format(
          "%.1f dB target, %.0f-%.0f Hz order %d, measured %.2f, %+.2f dB%s",
          cfg.target_db, cfg.band_lo_hz, cfg.band_hi_hz, cfg.band_order,
          r.band and r.band.db or 0, r.gain_db,
          r.limit and (" (" .. r.limit .. " limited)") or ""), true)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Vocal normalize", -1)

  local err
  if stranded > 0 then
    err = string.format(
      "%d clip%s could not reach the target: the other volume control is at -inf.",
      stranded, stranded == 1 and "" or "s")
  end
  return nwritten, #rows - #todo, err
end

-- Put the written control back to unity, so an A/B against the untouched take
-- is one click rather than an undo. Deliberately sets 1.0 rather than undoing
-- a specific gain: after a couple of passes there is no single gain to undo,
-- and unity is the state everyone means by "off".
function M.reset(rows, cfg)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local n = 0
  for _, r in ipairs(rows) do
    if cfg.apply_to == "item" then
      local old = reaper.GetMediaItemInfo_Value(r.item, "D_VOL")
      reaper.SetMediaItemInfo_Value(r.item, "D_VOL", (old < 0) and -1 or 1)
    else
      local old = reaper.GetMediaItemTakeInfo_Value(r.take, "D_VOL")
      reaper.SetMediaItemTakeInfo_Value(r.take, "D_VOL", (old < 0) and -1 or 1)
    end
    n = n + 1
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Vocal normalize -- reset volume", -1)
  return n
end

M.split_gain = split_gain
return M
