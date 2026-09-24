-- The time selection as a processing range.
--
-- One suite, the same in every script that grew this feature. It covers the two things that
-- fail SILENTLY:
--
--   * the analysed span must START where the selection does. The take accessor is anchored at
--     0 at the start of the ITEM, so the offset is `range.t0 - item_pos`. Get that subtraction
--     backwards and every read is still the right LENGTH -- only the content is wrong, which no
--     length or null assertion can see.
--   * a selection reaching past both ends of the item IS the whole item and must not split.
--     Splitting at an item's own edges leaves zero-length debris behind.
--
-- The fixture is a track added at the END of whatever project is open and deleted afterwards,
-- and it is built at playrate 1.25: at playrate 1 every quantity in the geometry is the same
-- number, so a scaling mistake passes.

local here = debug.getinfo(1, "S").source:match("^@(.+)$"):match("^(.*[/\\])")
local root = here:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. package.path

local P = "at"
local Analyze = require(P .. ".analyze")
local Timesel = require(P .. ".timesel")
local Config  = require(P .. ".config")
local Wav     = require(P .. ".wav")

local pass, fail = 0, 0
-- Returns the condition: callers gate on it (`if not ok(...) then return end`), and a helper
-- that returned nothing made every such gate fire, ending the run after two assertions while
-- still reporting a green "0 failed".
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
-- Anything that stops the run counts as a failure: an early return is an exit-0 path that
-- means nothing was checked.
local function bail(msg) fail = fail + 1 print("  FAIL  " .. msg) end

local RATE, SECS, PLAYRATE = 48000, 8.0, 1.25

local function write_fixture(path)
  local w, err = Wav.create(path, 1, RATE)
  if not w then return nil, err end
  local n, t = math.floor(SECS * RATE), {}
  for i = 1, n do
    -- A tone that changes character half way, so a wrongly-offset read is at least in
    -- principle detectable by ear as well as by these assertions.
    t[i] = 0.25 * math.sin(2 * math.pi * (i < n / 2 and 220 or 440) * (i - 1) / RATE)
  end
  w:write(t, 1, n)
  w:close()
  return path
end

local tracks0, items0 = reaper.CountTracks(0), reaper.CountMediaItems(0)
local ts0_saved, ts1_saved = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

reaper.InsertTrackAtIndex(tracks0, true)          -- at the END: no existing index moves
local tr = reaper.GetTrack(0, tracks0)
reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "TS fixture", true)

local wav_path = root .. "test/_timesel_fixture.wav"
local run_ok, run_err = pcall(function()
  if not write_fixture(wav_path) then bail("could not write the fixture WAV") return end
  local src = reaper.PCM_Source_CreateFromFile(wav_path)
  if not src then bail("could not open the fixture WAV") return end

  local POS = 400.0
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", PLAYRATE)
  local len = SECS / PLAYRATE
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", POS)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)

  local cfg = Config.new()
  local full = Analyze.geometry(take)
  near(full.acc_len, len, 1e-6, "with no range the span is the item, not the source")

  -- The middle half.
  local SEL0, SEL1 = POS + len * 0.25, POS + len * 0.75
  reaper.GetSet_LoopTimeRange(true, false, SEL0, SEL1, false)

  local range, rerr = Timesel.for_item(item, cfg.ignore_time_selection)
  if not ok(range ~= nil, "the range resolves", tostring(rerr)) then return end
  ok(range.from_selection, "and says it came from the selection")
  ok(not range.whole, "a mid-item selection is not the whole item")
  near(range.t0, SEL0, 1e-6, "it starts at the selection")
  near(range.t1, SEL1, 1e-6, "and ends at it")

  local geo = Analyze.geometry(take, range)
  near(geo.t0, SEL0 - POS, 1e-6, "THE TRAP: the read starts at range.t0 - item_pos, in take seconds")
  near(geo.acc_len, SEL1 - SEL0, 1e-6, "and spans the selection")
  near(geo.total_samples, (SEL1 - SEL0) * geo.rate, 2, "the sample count matches the span")
  ok(geo.total_samples < full.total_samples, "fewer samples than the whole item",
     string.format("%d vs %d", geo.total_samples, full.total_samples))

  -- The override, and no-selection, must both give the whole item back.
  local ocfg = Config.new()
  ocfg.ignore_time_selection = true
  local orange = Timesel.for_item(item, ocfg.ignore_time_selection)
  ok(orange and orange.whole, "the override processes the whole item")
  ok(orange and not orange.from_selection, "and says the selection was not used")
  near(Analyze.geometry(take, orange).total_samples, full.total_samples, 2,
       "reading as much as having no selection at all")
  near(Analyze.geometry(take, orange).t0, 0, 1e-9, "and from the start of the take")

  -- A selection swallowing the item is the whole item, and must not split.
  reaper.GetSet_LoopTimeRange(true, false, POS - 5, POS + len + 5, false)
  local covering = Timesel.for_item(item, false)
  ok(covering and covering.whole, "a selection covering the item needs no split")
  near(Analyze.geometry(take, covering).total_samples, full.total_samples, 2,
       "and reads the whole item")

  -- One that misses it entirely is refused rather than guessed at.
  reaper.GetSet_LoopTimeRange(true, false, POS + len + 10, POS + len + 20, false)
  local missed, merr = Timesel.for_item(item, false)
  ok(missed == nil and merr ~= nil, "a selection that misses the item is refused")

  -- Which item the run should work on, with several clips selected. This is the bug the
  -- original version had: "the first selected item" is track-then-position order, so with
  -- three clips on a track and a selection over the third, it picked one the selection does
  -- not touch and then refused with "the time selection does not overlap the item" -- true of
  -- that clip, and not what was meant.
  local extra1 = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(extra1, "D_POSITION", POS - 20)
  reaper.SetMediaItemInfo_Value(extra1, "D_LENGTH", 5)
  local extra2 = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(extra2, "D_POSITION", POS - 10)
  reaper.SetMediaItemInfo_Value(extra2, "D_LENGTH", 5)
  -- Give them audio takes, or selected_item skips them for the wrong reason.
  for _, it in ipairs({ extra1, extra2 }) do
    local tk = reaper.AddTakeToMediaItem(it)
    reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(wav_path))
  end

  reaper.GetSet_LoopTimeRange(true, false, SEL0, SEL1, false)
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs({ extra1, extra2, item }) do reaper.SetMediaItemSelected(it, true) end

  local chosen, cerr = Timesel.selected_item(false)
  ok(chosen == item, "picks the selected item the selection is OVER, not the first one",
     tostring(cerr))
  ok(Timesel.selected_item(true) == extra1,
     "and with the override it is simply the first selected")

  ok(Timesel.overlaps(item, SEL0, SEL1), "overlaps() sees the item under the selection")
  ok(not Timesel.overlaps(extra1, SEL0, SEL1), "and not one before it")

  local clips = { { item = extra1 }, { item = extra2 }, { item = item } }
  local kept = Timesel.clips_in_range(clips, range)
  ok(#kept == 1 and kept[1].item == item,
     "clips_in_range keeps only what the range touches", tostring(#kept))
  ok(#Timesel.clips_in_range(clips, nil) == 3, "and keeps everything with no range")
  ok(#Timesel.clips_in_range(clips, orange) == 3, "and with the override")

  -- anchor_clip: which clip of a TRACK a range should be derived from. The panel's range
  -- display and the run must use the same one -- using clips[1] made the display report "the
  -- time selection does not overlap the item" for a run that would have worked, permanently,
  -- on every track holding more than one clip.
  local anchor, aerr = Timesel.anchor_clip(clips, false)
  ok(anchor and anchor.item == item, "anchor_clip picks the clip under the selection",
     tostring(aerr))
  ok(Timesel.anchor_clip(clips, true).item == extra1,
     "and with the override it is simply the first clip")
  ok(Timesel.for_item(Timesel.anchor_clip(clips, false).item, false) ~= nil,
     "so for_item on the anchor resolves rather than refusing")
  local none, nerr = Timesel.anchor_clip({ { item = extra1 }, { item = extra2 } }, false)
  ok(none == nil and nerr ~= nil,
     "a track whose clips the selection all miss reports, rather than picking one anyway")
  ok(Timesel.anchor_clip({}, false) == nil, "an empty clip list anchors nothing")

  -- Source scan. A panel that works from a LIST of clips has to derive its range from the
  -- anchor in BOTH the run and the range display. Using clips[1] in the display while the run
  -- anchored correctly made the panel say "the time selection does not overlap the item" about
  -- work it then went on to do properly -- a panel contradicting its own behaviour, which no
  -- behavioural test can see because the behaviour was right.
  if P == "at" or P == "nl" then
    local fh = io.open(root .. P .. "/ui.lua", "r")
    if not fh then
      bail("cannot read " .. P .. "/ui.lua for the anchor scan")
    else
      local src = fh:read("a")
      fh:close()
      local n = select(2, src:gsub("anchor_clip", ""))
      ok(n >= 2, "the panel anchors the range in both the run and the display",
         "found " .. n .. " use(s)")
      ok(src:find("for_item%(%s*[%w_.]*target%[1%]") == nil,
         "and never derives a range from target[1]")
      ok(src:find("local first = [%w_]+%.target and [%w_]+%.target%[1%]") == nil,
         "nor reaches it through a local named `first`")
    end
  end

  -- The processing range, which is a different question from the analysis range.
  ok(Timesel.render_range(range, false) == range, "processing follows the range by default")
  ok(Timesel.render_range(range, true) == nil,
     "and is nil when the whole item is to be processed -- `x and nil or y` cannot express this")

  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs({ extra1, extra2 }) do
    reaper.DeleteTrackMediaItem(tr, it)
  end

  -- Splitting: three pieces, the middle one exactly the selection, the others untouched.
  reaper.GetSet_LoopTimeRange(true, false, SEL0, SEL1, false)
  local before_takes = reaper.CountTakes(item)
  local middle, serr = Timesel.split_to_range(item, SEL0, SEL1)
  if ok(middle ~= nil, "the item splits to the range", tostring(serr)) then
    ok(reaper.CountTrackMediaItems(tr) == 3, "into three pieces",
       tostring(reaper.CountTrackMediaItems(tr)))
    near(reaper.GetMediaItemInfo_Value(middle, "D_POSITION"), SEL0, 1e-6,
         "the middle piece starts at the selection")
    near(reaper.GetMediaItemInfo_Value(middle, "D_LENGTH"), SEL1 - SEL0, 1e-6,
         "and is exactly as long as it")

    local others = 0
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      if it ~= middle then
        others = others + 1
        ok(reaper.CountTakes(it) == before_takes, "an outer piece keeps its original takes",
           tostring(reaper.CountTakes(it)))
      end
    end
    ok(others == 2, "two outer pieces", tostring(others))
  end
end)
if not run_ok then bail("the run raised: " .. tostring(run_err)) end

reaper.GetSet_LoopTimeRange(true, false, ts0_saved, ts1_saved, false)
pcall(reaper.DeleteTrack, tr)
os.remove(wav_path)
reaper.UpdateArrange()

ok(reaper.CountTracks(0) == tracks0, "fixture track removed",
   string.format("%d tracks, expected %d", reaper.CountTracks(0), tracks0))
ok(reaper.CountMediaItems(0) == items0, "and no items left behind",
   string.format("%d items, expected %d", reaper.CountMediaItems(0), items0))

print(string.format("\ntimesel: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
