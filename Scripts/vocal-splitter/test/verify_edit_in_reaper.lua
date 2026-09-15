-- Vocal Splitter -- in-REAPER verification of the read geometry and the
-- split/crossfade geometry. Run from the Actions list.
--
-- Two cases every run, because they cover different things and neither is
-- optional:
--
--   the selected item, if there is one -- real material, on the user's own
--   settings, which is the only case that can say whether this take survives
--   the pipeline;
--
--   a TIME-STRETCHED fixture, always -- built from the WAV the repo ships, on
--   a temporary track, at playrate 1.25. At playrate 1 every quantity in the
--   geometry is the same number, so every scaling mistake in it passes.
--
-- What is checked, in the order the bugs appear:
--
--   The read span. The take audio accessor's timeline is ITEM time and the
--   audio it returns already has the playrate applied, so the span to read is
--   item_len, not item_len * playrate. Reading the longer span returns the
--   item's audio followed by silence -- which reads as a pause and moves the
--   section and phrase structure, not just the tail.
--
--   The frame time base. Frames are hop samples apart in accessor time, so
--   frame index -> time is hop / rate, with no playrate in it. Getting this
--   wrong slides every detected element and every cut toward zero.
--
--   The sync invariant, which is exact:
--
--       startoffs - position * playrate  is the same for every resulting item
--
--   because both sides describe where in the source file t=0 of the timeline
--   would fall. Any arithmetic slip in the overlap code breaks it. This is the
--   automated stand-in for the render-and-null test; run the null afterwards
--   as well, since it additionally proves the fade shapes reconstruct to
--   unity, which geometry alone cannot show.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowConsoleMsg("FAIL  ReaImGui is missing -- nothing was checked.\n")
  if os.exit then os.exit(1) end
  return
end
package.path = script_dir .. "?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui      = require "imgui" "0.9"
local Config     = require "vs.config"
local Analyze    = require "vs.analyze"
local AutoThresh = require "vs.autothresh"
local Hierarchy  = require "vs.hierarchy"
local Levels     = require "vs.levels"
local Apply      = require "vs.apply"

-- Output is buffered and printed at the end, so an uncaught error inside a
-- case would otherwise take the whole report with it. Every case is pcall'd.
local buf, fails, checks = {}, 0, 0
local function say(s) buf[#buf + 1] = s end
local function report()
  reaper.ShowConsoleMsg(table.concat(buf, "\n") ..
    ("\n\n%d/%d checks passed\n"):format(checks - fails, checks))
end
local function check(ok, msg, extra)
  checks = checks + 1
  if not ok then fails = fails + 1 end
  say(("  %s  %s%s"):format(ok and "ok  " or "FAIL", msg,
      extra and ("   (" .. extra .. ")") or ""))
end
-- Anything that stops the whole run counts as a failure. Every one of these is
-- an early return in the natural writing of a suite, and every one of them is
-- an exit-0 path that means nothing was checked at all.
local function bail(msg)
  fails = fails + 1
  checks = checks + 1
  say("  FAIL  " .. msg)
  report()
  if os.exit then os.exit(1) end
end
-- Inside a case, a stop is recorded and that case abandoned -- the other case
-- still has to run, and "the stretched one never executed" must not look like
-- "the stretched one passed".
local function die(msg)
  fails = fails + 1
  checks = checks + 1
  say("  FAIL  " .. msg)
end

reaper.ShowConsoleMsg("")
say("Vocal Splitter -- read and edit geometry verification\n")

local ctx = ImGui.CreateContext("vs verify")

------------------------------------------------------------ the fixture

-- The stretched case is built from the repo's own test WAV rather than a
-- generated tone: the pipeline has to reach Apply.run with real spans and real
-- crossfades for the sync invariant to be worth anything, and a sine produces
-- neither.
--
-- It lives on a temporary track in the CURRENT project and is deleted at the
-- end. Opening a project tab instead is a trap: a script cannot close one
-- without risking a modal save prompt that hangs the run and blocks the UI.
local FIX_PLAYRATE = 1.25
local FIX_POS      = 7.5      -- not at zero, on purpose: the invariant is
                              -- trivially satisfied by every arithmetic at 0

local function build_fixture()
  local path = script_dir .. "VocalSplit test.wav"
  local psrc = reaper.PCM_Source_CreateFromFile(path)
  if not psrc then return nil, "could not open " .. path end
  local src_len = reaper.GetMediaSourceLength(psrc)
  if src_len <= 0 then return nil, "the fixture WAV has no length" end

  local ntr = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(ntr, false)
  local tr = reaper.GetTrack(0, ntr)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "vsplit verify (temp)", true)

  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, psrc)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", FIX_POS)
  reaper.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", FIX_PLAYRATE)
  -- The item is as long as the stretched source: at playrate 1.25 a 32 s file
  -- plays in 25.6 s of timeline.
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", src_len / FIX_PLAYRATE)
  reaper.UpdateArrange()
  return it, tr
end

--------------------------------------------------------------- a case

local function run_case(item, cfg, label)
  say("\n== " .. label .. " ==\n")

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    die("no audio take") return
  end

  local track    = reaper.GetMediaItemTrack(item)
  local o_pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local o_len    = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local o_offs   = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then playrate = 1 end
  local anchor   = o_offs - o_pos * playrate

  say(("source: pos %.4f  len %.4f  offs %.4f  playrate %.4f")
      :format(o_pos, o_len, o_offs, playrate))
  if math.abs(playrate - 1) < 1e-9 then
    say("  ..    playrate is 1: the D_PLAYRATE path is NOT exercised by this")
    say("        case. The stretched fixture below is what covers it.")
  end

  -- the accessor's own timeline ---------------------------------------------
  --
  -- Stated as an assertion rather than a comment, because it is the fact the
  -- whole geometry rests on and it was assumed wrongly for as long as the
  -- script existed.
  say("\naccessor geometry")
  do
    local aa = reaper.CreateTakeAudioAccessor(take)
    if not aa then die("could not create an audio accessor") return end
    local a0 = reaper.GetAudioAccessorStartTime(aa)
    local a1 = reaper.GetAudioAccessorEndTime(aa)
    reaper.DestroyAudioAccessor(aa)
    check(math.abs((a1 - a0) - o_len) < 1e-6,
          "the accessor spans the item, not the source",
          ("%.4f s of accessor vs %.4f s of item, %.4f s of source")
          :format(a1 - a0, o_len, o_len * playrate))
  end

  -- run the pipeline --------------------------------------------------------
  local F, err = Analyze.run(take, cfg, ImGui, ctx, script_dir)
  if not F then die("analysis failed: " .. tostring(err)) return end

  say("\nthe read covers the accessor and stops there")
  -- The bug this catches: total_samples taken as item_len * playrate * rate.
  -- At playrate 1.25 that asks for 25% more audio than exists and the surplus
  -- comes back as silence.
  local read_s = F.n * F.hop / F.rate
  check(math.abs(read_s - o_len) <= F.hop / F.rate + 1e-9,
        "the frames span the item length",
        ("%.4f s read vs %.4f s of item"):format(read_s, o_len))

  -- And the symptom of having read too far, asserted directly: the surplus
  -- comes back as digital silence, which lands in the frames as an exact
  -- floor. Real room tone never is.
  --
  -- An item may legitimately outlast its media, so the allowance is computed
  -- rather than assumed: whatever the source has left past D_STARTOFFS, played
  -- at the playrate, is how much timeline actually has audio behind it.
  local tsrc = reaper.GetMediaItemTake_Source(take)
  local slen = tsrc and reaper.GetMediaSourceLength(tsrc) or 0
  local audible = math.max(0, (slen - o_offs) / playrate)
  local allowed = math.max(0, o_len - audible) + 0.05
  local tail = 0
  for i = F.n, 1, -1 do
    if F.ms[i] > 0 then break end
    tail = tail + 1
  end
  check(tail * F.acc_frame_dur <= allowed,
        "the frames do not end in silence the media cannot account for",
        ("%.3f s of digital silence, %.3f s allowed")
        :format(tail * F.acc_frame_dur, allowed))

  say("\nframe times are item-relative project seconds")
  -- ftime is what places every cut, so its two ends are worth pinning. The
  -- playrate must not appear in it: frames are hop samples apart in accessor
  -- time, and accessor time is item time.
  check(math.abs(F.acc_frame_dur - F.hop / F.rate) < 1e-15,
        "one frame is hop / rate of project time, with no playrate in it",
        ("%.9f vs %.9f"):format(F.acc_frame_dur, F.hop / F.rate))
  check(math.abs(F.src_frame_dur - F.hop / F.rate * playrate) < 1e-15,
        "and hop / rate * playrate of source time",
        ("%.9f"):format(F.src_frame_dur))
  check(math.abs(Hierarchy.ftime(F, F.n + 1) - read_s) < 1e-9,
        "the last frame ends where the read ended",
        ("%.4f vs %.4f"):format(Hierarchy.ftime(F, F.n + 1), read_s))

  local th = AutoThresh.gate(F, cfg)
  th.sib_thresh = AutoThresh.sib_threshold(F, th.gate_db, cfg)
  local _, gaps = Hierarchy.gate(F, th.gate_db, cfg)
  local gt = AutoThresh.gap_thresholds(gaps, cfg)
  th.section_gap_ms, th.phrase_gap_ms = gt.section_gap_ms, gt.phrase_gap_ms

  local tree, terr = Hierarchy.build(F, th, cfg)
  if not tree then die("segmentation failed: " .. tostring(terr)) return end
  Levels.cascade(tree, cfg)
  local spans = Hierarchy.spans(F, tree, cfg)

  -- Every cut has to fall inside the item. With the frame times scaled by the
  -- playrate they still did, which is why this alone is not enough and the
  -- read-span checks above carry the case.
  say("\ncuts fall inside the item")
  local outside = 0
  for _, c in ipairs(tree.cuts) do
    if c.t < -1e-9 or c.t > o_len + 1e-9 then outside = outside + 1 end
  end
  check(outside == 0, "no cut lands outside the item", outside .. " outside")

  say(("\n%d frames, %d sections, %d spans -> applying\n")
      :format(F.n, #tree.sections, #spans))
  local n = Apply.run(item, spans, cfg)
  say(("created %d items\n"):format(n))

  -- collect the result ------------------------------------------------------
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local l = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if p < o_pos + o_len - 1e-9 and p + l > o_pos + 1e-9 then
      items[#items + 1] = it
    end
  end
  if #items == 0 then die("the edit left no items behind") return end
  table.sort(items, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, "D_POSITION")
         < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
  end)

  say("sync invariant")
  local worst, worst_i = 0, 0
  for i, it in ipairs(items) do
    local tk = reaper.GetActiveTake(it)
    if tk then
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local off = reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")
      local d = math.abs((off - p * playrate) - anchor)
      if d > worst then worst, worst_i = d, i end
    end
  end
  check(worst < 1e-7,
        ("every item maps to the same source position (%d items)"):format(#items),
        ("worst drift %.3e s at item %d"):format(worst, worst_i))

  say("\ncoverage")
  local first_p = reaper.GetMediaItemInfo_Value(items[1], "D_POSITION")
  local last = items[#items]
  local last_e = reaper.GetMediaItemInfo_Value(last, "D_POSITION")
            + reaper.GetMediaItemInfo_Value(last, "D_LENGTH")
  check(math.abs(first_p - o_pos) < 1e-6, "starts where the original started",
        ("%.6f vs %.6f"):format(first_p, o_pos))
  check(math.abs(last_e - (o_pos + o_len)) < 1e-6, "ends where the original ended",
        ("%.6f vs %.6f"):format(last_e, o_pos + o_len))

  say("\nno holes between items")
  local holes = 0
  for i = 2, #items do
    local pe = reaper.GetMediaItemInfo_Value(items[i-1], "D_POSITION")
             + reaper.GetMediaItemInfo_Value(items[i-1], "D_LENGTH")
    local p = reaper.GetMediaItemInfo_Value(items[i], "D_POSITION")
    if p > pe + 1e-9 then holes = holes + 1 end
  end
  check(holes == 0, "consecutive items touch or overlap", holes .. " holes")

  say("\ncrossfades")
  local bad_fade, overlaps = 0, 0
  for i = 2, #items do
    local pe = reaper.GetMediaItemInfo_Value(items[i-1], "D_POSITION")
             + reaper.GetMediaItemInfo_Value(items[i-1], "D_LENGTH")
    local p = reaper.GetMediaItemInfo_Value(items[i], "D_POSITION")
    local ov = pe - p
    if ov > 1e-9 then
      overlaps = overlaps + 1
      -- Overlapping items must use the AUTO fade slots; the manual ones do not
      -- render as a crossfade at all.
      local fo = reaper.GetMediaItemInfo_Value(items[i-1], "D_FADEOUTLEN_AUTO")
      local fi = reaper.GetMediaItemInfo_Value(items[i], "D_FADEINLEN_AUTO")
      if math.abs(fo - ov) > 1e-6 or math.abs(fi - ov) > 1e-6 then
        bad_fade = bad_fade + 1
      end
    end
  end
  check(overlaps > 0, "the edit produced overlaps to crossfade", overlaps .. " overlaps")
  check(bad_fade == 0, "auto fade lengths match every overlap", bad_fade .. " mismatched")

  say("\nfade shape")
  -- Only the fades that make up a crossfade. The first item's fade-in and the
  -- last item's fade-out are the outer edges of the take: they are whatever the
  -- source item already carried -- REAPER's own 10 ms shape-1 default, as often
  -- as not -- and they are not part of any reconstruction. Checking every item's
  -- fade-in reported that default as a failure of the edit, and at the same time
  -- never looked at a single fade-out, which is half of every crossfade.
  local nonlinear = 0
  for i = 2, #items do
    local pe = reaper.GetMediaItemInfo_Value(items[i-1], "D_POSITION")
             + reaper.GetMediaItemInfo_Value(items[i-1], "D_LENGTH")
    if pe - reaper.GetMediaItemInfo_Value(items[i], "D_POSITION") > 1e-9 then
      if reaper.GetMediaItemInfo_Value(items[i], "C_FADEINSHAPE") ~= 0
      or reaper.GetMediaItemInfo_Value(items[i], "D_FADEINDIR") ~= 0
      or reaper.GetMediaItemInfo_Value(items[i-1], "C_FADEOUTSHAPE") ~= 0
      or reaper.GetMediaItemInfo_Value(items[i-1], "D_FADEOUTDIR") ~= 0 then
        nonlinear = nonlinear + 1
      end
    end
  end
  check(nonlinear == 0, "crossfades are linear (equal-gain reconstructs coherent audio)",
        nonlinear .. " non-linear")
end

------------------------------------------------------------------- the run

local function protected(item, cfg, label)
  local good, err = pcall(run_case, item, cfg, label)
  if not good then
    fails = fails + 1
    checks = checks + 1
    say("  FAIL  " .. label .. " raised: " .. tostring(err))
  end
end

-- The selected item runs on the panel's own settings, since the question it
-- answers is "does this take survive what I have the sliders set to".
local sel = reaper.GetSelectedMediaItem(0, 0)
if sel then
  local tk = reaper.GetActiveTake(sel)
  if tk and not reaper.TakeIsMIDI(tk) then
    protected(sel, Config.load(), "selected item, panel settings")
  else
    say("\n-- the selected item has no audio take; the real-material case is")
    say("   not covered by this run")
  end
else
  say("\n-- nothing selected; the real-material case is not covered by this run")
end

-- The fixture runs on defaults, so it is the same regression every time
-- regardless of what the panel was last left set to.
local fit, ftr = build_fixture()
if not fit then
  bail("could not build the stretched fixture: " .. tostring(ftr))
  return
end
protected(fit, Config.new(),
          ("stretched fixture, playrate %.2f"):format(FIX_PLAYRATE))

-- Always clean up, pass or fail: the fixture lives on a temporary track in the
-- user's own project. DeleteTrack takes its items with it.
--
-- Not Undo_DoUndo2: that invalidates the MediaItem pointers still held here and
-- every later call fails with "MediaItem expected", which reads like a logic
-- bug and is not one.
reaper.DeleteTrack(ftr)
reaper.UpdateArrange()

say("\nUndo to restore the selected item, then render and null for the final proof.")
report()
if fails > 0 then
  reaper.MB(("%d of %d checks failed -- see the console.")
            :format(fails, checks), "Vocal Splitter verify", 0)
end
if os.exit then os.exit(fails == 0 and 0 or 1) end
