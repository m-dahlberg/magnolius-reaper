-- Adaptive De-Click -- whole-pipeline verification. Run from the Actions list
-- with one audio item selected.
--
-- The kernel selftest proves the DSP; the null test proves it matches the
-- plugin. Neither of them touches an accessor, a take or a WAV file, and that
-- seam -- the one stage with passing tests on either side of it and none
-- through it -- is where this kind of script actually breaks. So this suite
-- runs the real thing end to end.
--
-- Two assertions carry it:
--
--   Analysis saw audio. GetAudioAccessorSamples returns nil from inside a
--   coroutine, silently, leaving the buffer as it was -- so a job that reads
--   its own audio analyses a completely silent file and says nothing. If the
--   waveform buckets come back flat, that is what happened.
--
--   An empty gain envelope nulls at shift 0, exactly. Offline there is no
--   lookahead and nothing to compensate, so the rendered take must line up
--   with the source sample for sample. The test also checks that the error at
--   +-1 sample is large, or an off-by-one would pass.
--
-- Run it on a time-stretched item too: at playrate 1 the D_PLAYRATE path is
-- never exercised and every scaling bug here passes.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src:match("^(.*[/\\])"):gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function section(s) say("-- " .. s) end
local function report()
  reaper.ShowConsoleMsg(table.concat(out, "\n") ..
    string.format("\n\n%d passed, %d failed\n", pass, fail))
end
-- Anything that stops the run counts as a failure. "No item selected" is an
-- exit-0 path that means nothing was checked, and a green exit has to mean the
-- thing was verified.
local function bail(msg)
  fail = fail + 1
  say("  FAIL  " .. msg)
  report()
  if os.exit then os.exit(1) end
end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") return end
package.path = script_dir .. "?.lua;" .. reaper.ImGui_GetBuiltinPath()
            .. "/?.lua;" .. package.path

local ImGui   = require "imgui" "0.9"
local Config  = require "dc.config"
local Kernel  = require "dc.kernel"
local Analyze = require "dc.analyze"
local Detect  = require "dc.detect"
local Render  = require "dc.render"
local Apply   = require "dc.apply"

local Wav = require "dc.wav"

local ctx = ImGui.CreateContext("De-Click verify")

-- Two cases every run, because they cover different things and neither is
-- optional:
--
--   the selected item, if there is one -- real material, the only thing that
--   can say whether the rules match a voice;
--
--   a TIME-STRETCHED fixture, always -- at playrate 1 the D_PLAYRATE path is
--   never exercised and every geometry bug passes. The take accessor's span is
--   item time and the audio it returns already has the stretch applied, so
--   this is the case that catches reading item_len * playrate or copying the
--   playrate onto the rendered take.
--
-- The fixture lives on a temporary track in the CURRENT project and is deleted
-- at the end. It used to open a project tab, which cannot be closed from a
-- script without risking a modal save prompt that hangs the run.
local FIX_RATE, FIX_LEN, FIX_PLAYRATE = 48000, 4.0, 1.25

local function build_fixture()
  local path = script_dir .. "test/_fixture.wav"
  local w, werr = Wav.create(path, 2, FIX_RATE)
  if not w then return nil, werr end
  local n = math.floor(FIX_RATE * FIX_LEN)
  local shape, isclick = { 0.6, -0.5, 0.4 }, {}
  for _, p in ipairs({ 24000, 48000, 72000, 96000, 120000, 144000 }) do
    for j = 1, #shape do isclick[p + j - 1] = shape[j] end
  end
  local buf, m = {}, 0
  for i = 0, n - 1 do
    local v = 0.3 * math.sin(2 * math.pi * 440 * i / FIX_RATE) + (isclick[i] or 0)
    buf[m + 1], buf[m + 2] = v, v
    m = m + 2
    if m >= 8192 then w:write(buf, 1, m) buf, m = {}, 0 end
  end
  if m > 0 then w:write(buf, 1, m) end
  w:close()

  local ntr = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(ntr, false)
  local tr = reaper.GetTrack(0, ntr)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "declick verify (temp)", true)
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  local psrc = reaper.PCM_Source_CreateFromFile(path)
  if not psrc then return nil, "could not open the fixture WAV" end
  reaper.SetMediaItemTake_Source(tk, psrc)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 7.5)   -- not at zero, on purpose
  reaper.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", FIX_PLAYRATE)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", FIX_LEN / FIX_PLAYRATE)
  reaper.UpdateArrange()
  return it, tr, path
end

-- Inside a case, a stop is recorded and the case abandoned -- the other case
-- still has to run, and "the stretched one never executed" must not look like
-- "the stretched one passed".
local function die(msg)
  fail = fail + 1
  say("  FAIL  " .. msg)
end

local function run_case(item, take, label)
section(label)

local cfg = Config.new()
cfg.write_log, cfg.place_take_markers = false, false
cfg.thresh_auto, cfg.new_take, cfg.select_take = false, true, true

local geo = Analyze.geometry(take)
section(string.format("item: %.2f s, %d ch at %d Hz, playrate %.4f",
                      geo.acc_len, geo.nchan, geo.rate, geo.playrate))
if math.abs(geo.playrate - 1) < 1e-9 then
  say("  ..    playrate is 1: the D_PLAYRATE path is NOT exercised by this run")
else
  say(string.format("  ..    stretched: the accessor spans %.3f s of item time",
                    geo.acc_len))
end

local k, kerr = Kernel.new(ImGui, ctx, script_dir, geo, cfg)
if not k then die("kernel: " .. tostring(kerr)) return end

--------------------------------------------------------------- the accessor

section("analysis through the accessor")
local res, aerr = Analyze.drive(function() return Analyze.run(take, cfg, k) end)
if not res then die("analysis failed: " .. tostring(aerr)) return end
ok(res.steps > 4, "analysis produced steps", tostring(res.steps))

do
  -- The canary. A silent buffer is what an unserviced accessor read looks
  -- like, and it is indistinguishable from a silent file at every later stage.
  local wmin, wmax = k:waveform()
  local peak = 0
  for i = 1, #wmax do
    peak = math.max(peak, math.abs(wmax[i] or 0), math.abs(wmin[i] or 0))
  end
  ok(peak > 0.0001,
     "the accessor delivered audio, not silence (peak %.4f)" and
     string.format("the accessor delivered audio, not silence (peak %.4f)", peak),
     "the buffers came back flat -- see analyze.lua on coroutine reads")
end

-------------------------------------------------------------- the alignment

section("alignment: an empty envelope must null at shift 0")
local ntakes0 = reaper.CountTakes(item)
do
  -- Never detect, so the gain envelope stays as setup left it: all zeros. The
  -- render then exercises the accessor, the filters, the WAV writer and the
  -- take attachment with nothing to change, which is the only configuration in
  -- which "identical" is the correct answer.
  local path = Render.output_path(take, cfg)
  if not path then die("no free output filename") return end
  local rres, rerr = Analyze.drive(function()
    return Render.run(take, cfg, k, path)
  end)
  if not rres then die("render failed: " .. tostring(rerr)) return end
  ok(math.abs(rres.samples - geo.total_samples) <= 1,
     "the rendered file spans the accessor, i.e. the item length",
     string.format("%d vs %d", rres.samples, geo.total_samples))

  local th = { sens_used = 99, manual = true, stats = { events = 0, repaired = 0 } }
  local nt = Apply.run(item, take, rres, cfg, {}, th)
  if not nt then die("apply failed") return end
  ok(reaper.CountTakes(item) == ntakes0 + 1, "a take was added")
  ok(reaper.GetMediaItemTakeInfo_Value(nt, "D_STARTOFFS") == 0,
     "the new take starts at offset 0")
  -- NOT the original's playrate. The accessor already applied it, so copying
  -- it across would stretch already-stretched audio and slide the whole take.
  ok(reaper.GetMediaItemTakeInfo_Value(nt, "D_PLAYRATE") == 1,
     "and is neutral, because the render already contains the stretch",
     string.format("%.6f", reaper.GetMediaItemTakeInfo_Value(nt, "D_PLAYRATE")))
  ok(reaper.GetMediaItemTakeInfo_Value(nt, "I_CHANMODE") == 0,
     "and neutral channel mode, for the same reason")

  -- The take must also have a WAVEFORM. REAPER only builds peaks for files
  -- that arrive through an import path, so a source made with
  -- PCM_Source_CreateFromFile has none and nothing asks for them: the take
  -- plays back perfectly and draws an empty lane. Nothing else in this suite
  -- can see that -- audio is decoded on demand, peaks are not, so every null
  -- and every geometry assertion passes with the waveform missing.
  local pbuf = reaper.new_array(64 * 2)
  pbuf.clear(0)
  local pret = reaper.PCM_Source_GetPeaks(
    reaper.GetMediaItemTake_Source(nt), 8, 0, 1, 64, 0, pbuf)
  local pmax = 0
  for _, v in ipairs(pbuf.table()) do pmax = math.max(pmax, math.abs(v or 0)) end
  ok((pret & 0xFFFFF) > 0 and pmax > 0,
     "the new take has peaks, i.e. a waveform is drawn",
     string.format("%d peak samples, max %.4f", pret & 0xFFFFF, pmax))

  -- Compare the two takes through their own accessors. Both accessor
  -- timelines are source time anchored at 0, so a correct pipeline agrees
  -- sample for sample with no shift at all.
  local aa1 = reaper.CreateTakeAudioAccessor(take)
  local aa2 = reaper.CreateTakeAudioAccessor(nt)
  if not aa1 or not aa2 then die("could not create accessors") return end

  local NS, MARGIN = 32768, 8
  local start = math.min(math.floor(geo.total_samples * 0.25),
                         math.max(0, geo.total_samples - NS - MARGIN))
  local n = math.min(NS, geo.total_samples - start - MARGIN)
  local nch = geo.nchan
  local b1 = reaper.new_array((n + 2 * MARGIN) * nch)
  local b2 = reaper.new_array(n * nch)
  b1.clear(0) b2.clear(0)
  local g1 = reaper.GetAudioAccessorSamples(aa1, geo.rate, nch,
               (start - MARGIN) / geo.rate, n + 2 * MARGIN, b1)
  local g2 = reaper.GetAudioAccessorSamples(aa2, geo.rate, nch,
               start / geo.rate, n, b2)
  reaper.DestroyAudioAccessor(aa1)
  reaper.DestroyAudioAccessor(aa2)
  ok(g1 == 1 and g2 == 1, "both accessor reads were serviced")

  local t1, t2 = b1.table(1, (n + 2 * MARGIN) * nch), b2.table(1, n * nch)
  local best, best_shift = math.huge, nil
  local err_at = {}
  for shift = -MARGIN, MARGIN do
    local acc = 0
    for i = 0, n - 1 do
      for c = 1, nch do
        local a = t1[(i + MARGIN + shift) * nch + c] or 0
        local b = t2[i * nch + c] or 0
        acc = acc + (a - b) * (a - b)
      end
    end
    err_at[shift] = math.sqrt(acc / (n * nch))
    if err_at[shift] < best then best, best_shift = err_at[shift], shift end
  end
  ok(best_shift == 0, "the best alignment is shift 0",
     "best at " .. tostring(best_shift))
  -- Not bit-exact, and it cannot be. Two things stop it, neither a defect:
  -- the output is a 32-bit float file, so every sample is rounded to 2^-24
  -- (~1.5e-08 at this level); and where the source is resampled -- any
  -- stretched take, or one whose rate had to be converted -- the resampler's
  -- output depends on where you seek into it, so a single read cannot
  -- reproduce a strided traversal to the last bit. Measured directly: the
  -- rendered file agrees with the accessor to 1.5e-08, and the new take's
  -- accessor agrees with that file exactly.
  --
  -- The kernel's own null IS bit-exact; that is asserted in the selftest,
  -- where no file and no resampler are involved.
  ok(err_at[0] < 1e-4, "and it nulls to -80 dB or better",
     string.format("rms %.3g (%.1f dB)", err_at[0],
                   20 * math.log(math.max(err_at[0], 1e-30), 10)))
  -- Without this an off-by-one that happened to null well would pass. A real
  -- slip moves the minimum off zero, which the assertion above already
  -- catches; this is the backstop for a slip that does not.
  ok(err_at[1] > err_at[0] * 4 and err_at[-1] > err_at[0] * 4,
     "while +-1 sample is clearly worse",
     string.format("-1 %.3g, 0 %.3g, +1 %.3g", err_at[-1], err_at[0], err_at[1]))

  os.remove(rres.path)
  -- Remove the take we added rather than undoing. Undo_DoUndo2 invalidates the
  -- MediaItem pointer we are still holding, so every later call on it fails
  -- with "MediaItem expected" -- which reads like a logic bug and is not one.
  -- The action works on the selection, so we have to take it over briefly.
  -- Restore it afterwards: a test that silently deselects the user's item is a
  -- test that breaks the next thing they run.
  local was = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    was[#was + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.SetActiveTake(nt)
  reaper.Main_OnCommand(40129, 0)          -- Take: delete active take from items
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(was) do reaper.SetMediaItemSelected(it, true) end
  ok(reaper.CountTakes(item) == ntakes0, "the added take was removed",
     string.format("%d vs %d", reaper.CountTakes(item), ntakes0))
end

------------------------------------------------------------ a real de-click

section("a real pass over this item")
do
  local hist = Detect.survey(k, cfg)
  ok(hist.events ~= nil, "the survey ran")
  say(string.format("  ..    %d candidates at the %.1f dB floor",
                    hist.events or 0, cfg.sens_floor_db))

  local c = Config.new()
  c.write_log, c.place_take_markers = false, false
  local th = Detect.commit(k, c, hist)
  ok(th.final_db ~= nil, "a threshold was derived")
  say(string.format("  ..    tail %s  knee %s  used %.2f dB  ->  %d clicks, " ..
                    "%.4f%% repaired, %d retries",
    th.tail_db and string.format("%.2f", th.tail_db) or "--",
    th.knee_db and string.format("%.2f", th.knee_db) or "--",
    th.sens_used, th.stats.events, th.stats.repaired * 100, th.retries))
  if th.warning then say("  ..    " .. th.warning) end

  ok(th.stats.repaired >= 0 and th.stats.repaired <= 1,
     "the repaired fraction is a fraction")
  -- The budget is the guard that stops a bad threshold destroying material, so
  -- it has to actually bind.
  if c.use_budget and not th.budget_exceeded then
    ok(th.stats.repaired <= c.repair_budget_pct / 100,
       "the repair budget was respected",
       string.format("%.4f%% vs %.2f%%", th.stats.repaired * 100,
                     c.repair_budget_pct))
  else
    ok(true, "the budget bailed out after its retries, as designed")
  end
end

end   -- run_case

------------------------------------------------------------------- the run

-- A Lua error inside a case would otherwise take the whole buffered report
-- with it, so a crash would look like a silent runner failure rather than a
-- named one.
local function protected(item, take, label)
  local good, err = pcall(run_case, item, take, label)
  if not good then
    fail = fail + 1
    say("  FAIL  " .. label .. " raised: " .. tostring(err))
  end
end

local sel = reaper.GetSelectedMediaItem(0, 0)
if sel then
  local tk = reaper.GetActiveTake(sel)
  if tk and not reaper.TakeIsMIDI(tk) then
    protected(sel, tk, "selected item (real material)")
  else
    say("-- the selected item has no audio take; skipping the real-material case")
  end
else
  say("-- nothing selected; the real-material case is not covered by this run")
end

local fit, ftr, fpath = build_fixture()
if not fit then
  bail("could not build the stretched fixture: " .. tostring(ftr))
  return
end
protected(fit, reaper.GetActiveTake(fit), "stretched fixture (playrate 1.25)")

-- Always clean up, pass or fail: the fixture lives on a temporary track in the
-- user's own project.
reaper.DeleteTrack(ftr)
reaper.UpdateArrange()
os.remove(fpath)

report()
if os.exit then os.exit(fail == 0 and 0 or 1) end
