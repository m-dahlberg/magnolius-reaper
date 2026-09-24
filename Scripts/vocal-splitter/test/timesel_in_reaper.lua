-- The time selection as a processing range, for the Vocal Splitter.
--
-- This script writes SPLITS, not takes, so narrowing the range narrows where the cuts land
-- rather than producing a shorter render. The thing that fails silently is the origin: span
-- times are measured from the start of the ANALYSED span, so with a selection they must be
-- laid down from `origin`, not from the item's own position. Get that wrong and a run over a
-- selection cuts at the head of the item -- right number of pieces, wrong places.
--
-- The range arithmetic itself is shared (vs/timesel.lua) and covered in the other scripts'
-- suites too; what is specific here is Apply.run honouring the origin.

local here = debug.getinfo(1, "S").source:match("^@(.+)$"):match("^(.*[/\\])")
local root = here:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. root .. "test/?.lua;" .. package.path

local Timesel = require "vs.timesel"
local Apply   = require "vs.apply"
local Config  = require "vs.config"

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then pass = pass + 1
  else fail = fail + 1 print(string.format("  FAIL  %s%s", name,
    extra and ("  -- " .. extra) or "")) end
  return cond
end
local function near(got, want, tol, name)
  ok(type(got) == "number" and math.abs(got - want) <= tol, name,
     string.format("got %s, want %s +/- %s", tostring(got), tostring(want), tostring(tol)))
end
local function bail(msg) fail = fail + 1 print("  FAIL  " .. msg) end

local tracks0, items0 = reaper.CountTracks(0), reaper.CountMediaItems(0)
local ts0_saved, ts1_saved = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

reaper.InsertTrackAtIndex(tracks0, true)
local tr = reaper.GetTrack(0, tracks0)
reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "VS TS fixture", true)

local run_ok, run_err = pcall(function()
  local POS, LEN = 500.0, 8.0
  local item = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", POS)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", LEN)

  local cfg = Config.new and Config.new() or {}
  for k, v in pairs(Config.defaults or {}) do if cfg[k] == nil then cfg[k] = v end end
  cfg.split_only_on_change = false
  cfg.crossfade_ms = 0

  -- Range arithmetic, on this item.
  local SEL0, SEL1 = POS + 2.0, POS + 6.0
  reaper.GetSet_LoopTimeRange(true, false, SEL0, SEL1, false)
  local r, rerr = Timesel.for_item(item, false)
  if not ok(r ~= nil, "the range resolves", tostring(rerr)) then return end
  near(r.t0, SEL0, 1e-6, "it starts at the selection")
  near(r.t1, SEL1, 1e-6, "and ends at it")
  ok(not r.whole, "and is a strict subset of the item")

  local ignored = Timesel.for_item(item, true)
  ok(ignored and ignored.whole, "the override gives the whole item back")

  -- THE POINT: three spans measured from the analysed origin. With origin = SEL0 the cuts must
  -- land at SEL0 + 1.0 and SEL0 + 2.0, NOT at POS + 1.0 and POS + 2.0.
  local spans = {
    { t0 = 0.0, t1 = 1.0, gain_db = 0, class = "voiced", cf_in = 0 },
    { t0 = 1.0, t1 = 2.0, gain_db = 0, class = "voiced", cf_in = 0 },
    { t0 = 2.0, t1 = 4.0, gain_db = 0, class = "voiced", cf_in = 0 },
  }
  local origin = SEL0
  local n = Apply.run(item, spans, cfg, origin)
  ok(n and n >= 3, "three pieces were produced", tostring(n))

  local pieces = {}
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    pieces[#pieces + 1] = reaper.GetTrackMediaItem(tr, i)
  end
  table.sort(pieces, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, "D_POSITION")
         < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
  end)
  if ok(#pieces == 3, "three pieces on the track", tostring(#pieces)) then
    near(reaper.GetMediaItemInfo_Value(pieces[1], "D_POSITION"), POS, 1e-6,
         "the first piece still starts at the item")
    near(reaper.GetMediaItemInfo_Value(pieces[2], "D_POSITION"), origin + 1.0, 1e-6,
         "THE TRAP: the first cut is at origin + t0, not item_pos + t0")
    near(reaper.GetMediaItemInfo_Value(pieces[3], "D_POSITION"), origin + 2.0, 1e-6,
         "and so is the second")
    -- If the origin had been ignored the cuts would sit 2 s earlier; say so explicitly, so a
    -- regression names the cause rather than just a number.
    ok(math.abs(reaper.GetMediaItemInfo_Value(pieces[2], "D_POSITION") - (POS + 1.0)) > 0.5,
       "and NOT where item_pos + t0 would have put it")
  end
end)
if not run_ok then bail("the run raised: " .. tostring(run_err)) end

reaper.GetSet_LoopTimeRange(true, false, ts0_saved, ts1_saved, false)
pcall(reaper.DeleteTrack, tr)
reaper.UpdateArrange()

ok(reaper.CountTracks(0) == tracks0, "fixture track removed",
   string.format("%d tracks, expected %d", reaper.CountTracks(0), tracks0))
ok(reaper.CountMediaItems(0) == items0, "and no items left behind",
   string.format("%d items, expected %d", reaper.CountMediaItems(0), items0))

print(string.format("\ntimesel: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
