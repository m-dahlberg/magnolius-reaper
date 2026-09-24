-- @noindex
-- Vocal Splitter -- ReaImGui panel.
--
-- Laid out top to bottom in the same order the algorithm runs, so the panel
-- reads as the cascade: gate, sections, phrases, elements.

local Config     = require "vs.config"
local Analyze    = require "vs.analyze"
local AutoThresh = require "vs.autothresh"
local Hierarchy  = require "vs.hierarchy"
local Levels     = require "vs.levels"
local Apply      = require "vs.apply"
local Timesel  = require "vs.timesel"

local M = {}

local ImGui, ctx, script_dir
local cfg = Config.defaults
local ST = {
  item = nil, take = nil, F = nil, th = nil, tree = nil, spans = nil,
  status = "Select an item and press Analyze.", err = nil,
  cache_key = nil, counts = {}, dirty = false,
}

local function count_classes()
  local c = { phrase = 0, breath = 0, consonant = 0, sibilance = 0 }
  if ST.spans then
    for _, s in ipairs(ST.spans) do
      c[s.class] = (c[s.class] or 0) + 1
    end
  end
  c.sections = ST.tree and #ST.tree.sections or 0
  c.phrases = 0
  if ST.tree then
    for _, sec in ipairs(ST.tree.sections) do c.phrases = c.phrases + #sec.phrases end
  end
  c.items = ST.spans and #ST.spans or 0
  ST.counts = c
end

-- Stages 2 to 4 only. Cheap enough to run on every slider frame, which is the
-- whole point of caching stage 1.
local function recompute()
  if not ST.F then return end
  local th = AutoThresh.gate(ST.F, cfg)
  th.sib_thresh = AutoThresh.sib_threshold(ST.F, th.gate_db, cfg)

  -- Gap thresholds need the gaps, which need the gate: run the gate once with
  -- the configured durations, cluster what comes out, then build for real.
  local _, gaps = Hierarchy.gate(ST.F, th.gate_db, cfg)
  local gt = AutoThresh.gap_thresholds(gaps, cfg)
  th.section_gap_ms = gt.section_gap_ms
  th.phrase_gap_ms  = gt.phrase_gap_ms

  local tree, err = Hierarchy.build(ST.F, th, cfg)
  if not tree then ST.err = err; ST.tree = nil; ST.spans = nil; return end

  Levels.cascade(tree, cfg)
  tree.file_ref = Levels.measure(ST.F, 1, ST.F.n, cfg, th.gate_db).db
  ST.th, ST.tree = th, tree
  ST.spans = Hierarchy.spans(ST.F, tree, cfg)
  ST.err = nil
  count_classes()
end

local function analyze()
  -- The item the time selection is over, not blindly the first selected one -- with several
  -- clips on a track, "first selected" is often one the selection does not touch.
  local picked, perr = Timesel.selected_item(cfg.ignore_time_selection)
  if not picked then ST.status = perr return end
  ST.item = picked
  if not ST.item then ST.status = "No item selected."; ST.F = nil; return end

  -- Split at the selection edges BEFORE anything is analysed, and work on the middle piece
  -- from here on. This script sets D_VOL on each resulting clip, so a piece that straddles a
  -- selection edge would carry a gain decided from only the part inside it -- audible on the
  -- half that was never looked at. Splitting first means every clip that receives a gain lies
  -- wholly within the range.
  do
    local pre = Timesel.for_item(ST.item, cfg.ignore_time_selection)
    if pre and pre.from_selection and not pre.whole then
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)
      local middle, serr = Timesel.split_to_range(ST.item, pre.t0, pre.t1)
      reaper.PreventUIRefresh(-1)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Vocal Splitter: isolate the time selection", -1)
      if not middle then ST.status = serr or "could not split to the time selection" return end
      ST.item = middle
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(middle, true)
      -- The piece IS the range now, so nothing downstream has to offset anything.
      ST.F, ST.cache_key = nil, nil
    end
  end
  ST.take = reaper.GetActiveTake(ST.item)
  if not ST.take or reaper.TakeIsMIDI(ST.take) then
    ST.status = "Selected item has no audio take."; ST.F = nil; return
  end

  local key = Analyze.cache_key(ST.take, Analyze.pick_rate(ST.take, cfg))
  if ST.F and key == ST.cache_key then
    ST.status = ST.status .. "  (cached)"
    recompute()
    return
  end

  -- No range is passed on: the item was already cut down to the selection above, so the whole
  -- of what is left IS the work. One coordinate system instead of two.
  ST.range = nil
  local F, err = Analyze.run(ST.take, cfg, ImGui, ctx, script_dir)
  if not F then ST.status = "Analysis failed: " .. tostring(err); ST.F = nil; return end

  ST.F, ST.cache_key = F, key
  ST.status = string.format("%d frames at %d Hz (%.1f s)", F.n, F.rate,
                            F.n * F.acc_frame_dur)
  recompute()
end

--------------------------------------------------------------------------- draw

-- The level histogram with the gate drawn on it. Vocal material is bimodal,
-- and seeing where the gate sits relative to the two lobes is far faster than
-- guessing a number.
local function draw_histogram(w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##hist", w, h)

  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, 0x14181CFF, 4)
  if not ST.th then return end

  local hist = ST.th.hist
  local peak = 1
  for b = hist.lo, hist.hi do peak = math.max(peak, hist.bins[b]) end

  local n = hist.hi - hist.lo
  local bw = w / n
  for b = hist.lo, hist.hi - 1 do
    local frac = hist.bins[b] / peak
    -- sqrt so the noise lobe stays visible next to a tall signal lobe
    local bh = math.sqrt(frac) * (h - 4)
    local bx = x + (b - hist.lo) * bw
    ImGui.DrawList_AddRectFilled(dl, bx, y + h - bh, bx + bw - 1, y + h, 0x4A7FB5FF)
  end

  local function vline(db_val, col, label)
    local px = x + (db_val - hist.lo) / n * w
    ImGui.DrawList_AddLine(dl, px, y, px, y + h, col, 1.5)
    ImGui.DrawList_AddText(dl, px + 3, y + 2, col, label)
  end
  vline(ST.th.noise_floor, 0x808080FF, "floor")
  vline(ST.th.gate_db,     0xE05050FF, "gate")
  vline(ST.th.signal_ref,  0x50C878FF, "signal")
end

local function slider(label, key, lo, hi, fmt)
  local rv, v = ImGui.SliderDouble(ctx, label, cfg[key], lo, hi, fmt or "%.1f")
  if rv then cfg[key] = v; ST.dirty = true; recompute() end
  -- One undo point on release rather than one per frame.
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then Config.save(cfg) end
end

local function checkbox(label, key)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then cfg[key] = v; recompute(); Config.save(cfg) end
end

-- One row of the process list: a checkbox, its controls when enabled, and a
-- live count. All five levels read the same way so any one of them can be run
-- on its own and judged in isolation.
local COL_CTRL, COL_COUNT = 150, 400

local function row_head(label, enable_key)
  checkbox(label, enable_key)
  ImGui.SameLine(ctx, COL_CTRL)
  return cfg[enable_key]
end

local function row_count(text)
  ImGui.SameLine(ctx, COL_COUNT)
  ImGui.Text(ctx, text)
end

local function offset_row(label, enable_key, offset_key, class)
  if row_head(label, enable_key) then
    ImGui.SetNextItemWidth(ctx, 200)
    slider("dB##" .. class, offset_key, -24, 6)
  else
    ImGui.TextDisabled(ctx, "not detected")
  end
  row_count(string.format("%d", ST.counts[class] or 0))
end

local function frame()
  ImGui.SeparatorText(ctx, "Source")
  if ImGui.Button(ctx, "Analyze selected item", 200, 0) then analyze() end
  ImGui.SameLine(ctx)
  -- Two steps, because one click would otherwise throw away a tuned setup with
  -- no undo -- ExtState is written straight through.
  if ST.confirm_reset then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0xB04040FF)
    if ImGui.Button(ctx, "Really reset?", 120, 0) then
      cfg = Config.new()
      Config.save(cfg)
      ST.confirm_reset = nil
      ST.migrated = nil
      recompute()
      ST.status = "All settings reset to defaults."
    end
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel", 70, 0) then ST.confirm_reset = nil end
  else
    if ImGui.Button(ctx, "Reset settings", 120, 0) then ST.confirm_reset = true end
  end
  ImGui.SameLine(ctx)
  ImGui.TextWrapped(ctx, ST.status)
  if ST.err then ImGui.TextColored(ctx, 0xE05050FF, ST.err) end

  -- Above the "have we analysed yet" guard: this decides what the NEXT analysis reads, so it
  -- has to be reachable before there is anything to show.
  ImGui.SeparatorText(ctx, "Range")
  -- ValidatePtr2, not just a nil check: the item can have been deleted since it was stored,
  -- and the frame test hands the panel a stub.
  if ST.item and reaper.ValidatePtr2(0, ST.item, "MediaItem*") then
    local pos = reaper.GetMediaItemInfo_Value(ST.item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(ST.item, "D_LENGTH")
    local r, rerr = Timesel.for_item(ST.item, cfg.ignore_time_selection)
    if r then
      ImGui.Text(ctx, Timesel.describe(r, pos, len))
      if r.from_selection and not r.whole then
        ImGui.Text(ctx, "Splits are placed inside the selection only.")
      end
    else
      ImGui.TextColored(ctx, 0xE05050FF, rerr)
    end
  end
  -- Through the helper so the key appears as a string literal for the coverage scan.
  checkbox("Ignore time selection", "ignore_time_selection")

  if not ST.F then return end

  ImGui.SeparatorText(ctx, "Gate")
  local availw = ImGui.GetContentRegionAvail(ctx)
  draw_histogram(availw, 90)

  checkbox("Auto", "gate_auto")
  if cfg.gate_auto then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, string.format("-> %.1f dB   (floor %.1f, ceiling %.0f)",
      ST.th.gate_db, ST.th.noise_floor, cfg.gate_max_db))
    slider("Margin above floor (dB)", "noise_margin_db", 0, 20)
    slider("Ceiling (dB)", "gate_max_db", -60, -20)
  else
    slider("Gate (dB)", "gate_db", -70, -20)
  end
  slider("Min silence (ms)", "min_silence_ms", 20, 500, "%.0f")

  ImGui.SeparatorText(ctx, "Detection")
  checkbox("Auto gap thresholds", "gap_auto")
  if cfg.gap_auto then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, string.format("-> section %.0f ms, phrase %.0f ms",
      ST.th.section_gap_ms, ST.th.phrase_gap_ms))
  else
    slider("Section gap (ms)", "section_gap_ms", 300, 6000, "%.0f")
    slider("Phrase gap (ms)", "phrase_gap_ms", 100, 1500, "%.0f")
  end

  ImGui.SeparatorText(ctx, "Processes")
  -- Switching a level off collapses it into one node spanning its parent, so
  -- whatever is left references the next enabled level up, and ultimately the
  -- whole file. That is what makes running one process at a time meaningful.
  if ImGui.Button(ctx, "All", 50, 0) then
    for _, k in ipairs({ "enable_section", "enable_phrase", "enable_breath",
                         "enable_cons", "enable_sib" }) do cfg[k] = true end
    recompute(); Config.save(cfg)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "None", 50, 0) then
    for _, k in ipairs({ "enable_section", "enable_phrase", "enable_breath",
                         "enable_cons", "enable_sib" }) do cfg[k] = false end
    recompute(); Config.save(cfg)
  end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, string.format(
    "breaths are detected against %s   (whole file = %.1f dB)",
    cfg.enable_phrase and "their phrase"
      or (cfg.enable_section and "their section" or "the whole file"),
    ST.tree and ST.tree.file_ref or 0))

  if row_head("Sections", "enable_section") then
    ImGui.SetNextItemWidth(ctx, 130)
    slider("target dB##sec", "section_target_db", -40, -6)
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 110)
    slider("%##secp", "section_pct", 0, 100, "%.0f")
  else
    ImGui.TextDisabled(ctx, "one section spanning the take")
  end
  row_count(string.format("%d", ST.counts.sections or 0))

  if row_head("Phrases", "enable_phrase") then
    ImGui.SetNextItemWidth(ctx, 200)
    slider("%##phrp", "phrase_pct", 0, 100, "%.0f")
  else
    ImGui.TextDisabled(ctx, "one phrase per section")
  end
  row_count(string.format("%d", ST.counts.phrases or 0))

  -- Element offsets are relative: the clip cut out for one is turned down by
  -- this many dB on top of whatever its phrase got. They do not normalise, so
  -- a quiet breath stays proportionally quiet.
  ImGui.TextDisabled(ctx, "cut out and turned down by:")
  offset_row("Breaths",         "enable_breath", "breath_offset_db", "breath")
  offset_row("Hard consonants", "enable_cons",   "cons_offset_db",   "consonant")
  offset_row("Sibilance",       "enable_sib",    "sib_offset_db",    "sibilance")

  if ST.migrated then
    ImGui.TextWrapped(ctx, ST.migrated)
    if ImGui.SmallButton(ctx, "Dismiss") then ST.migrated = nil end
    ImGui.Separator(ctx)
  end

  ImGui.SeparatorText(ctx, "Refine detection")

  -- "Nothing was detected" is only answerable if the panel can say what was
  -- considered and what stopped it. Breaths are scanned on the frame features,
  -- so the funnel reads: runs the per-frame tests found, those of a plausible
  -- length, and those whose score cleared Sensitivity.
  if ImGui.CollapsingHeader(ctx, "Breaths") then
    slider("Sensitivity", "breath_sensitivity", 0, 100, "%.0f")
    local d = ST.tree and ST.tree.breath_diag
    if d then
      ImGui.TextDisabled(ctx, string.format(
        "%d runs found,  %d the wrong length  ->  %d candidates,  %d taken",
        d.runs, d.bad_dur, d.candidates, d.accepted))
      if d.rejected > 0 then
        local parts = {}
        for k, v in pairs(d.weak) do
          parts[#parts + 1] = string.format("%s (%d)", k, v)
        end
        table.sort(parts)
        ImGui.TextColored(ctx, 0xE0A050FF, string.format(
          "%d scored too low, held back by %s.  Best was %.0f%% -- " ..
          "Sensitivity above %.0f would take it.",
          d.rejected, table.concat(parts, ", "),
          d.best_rejected * 100, (1 - d.best_rejected) * 100))
      elseif d.candidates == 0 and d.runs > 0 then
        ImGui.TextColored(ctx, 0xE05050FF,
          "Runs were found but none was a plausible length -- widen the " ..
          "length limits below, or raise Join if breaths are arriving in " ..
          "fragments.")
      elseif d.runs == 0 then
        ImGui.TextColored(ctx, 0xE05050FF,
          "No run at all: no stretch of audio passed the per-frame tests. " ..
          "Widen the HF band or lower Above room tone -- not Sensitivity, " ..
          "which cannot reach this.")
      end
    end
    ImGui.TextDisabled(ctx, "absolute, per frame -- a run has to pass all of these:")
    slider("Voiced at most", "breath_voice_max", 0.05, 1.0, "%.2f")
    slider("HF content from", "breath_sib_lo", 0, 1, "%.2f")
    slider("HF content to", "breath_sib_hi", 0, 1, "%.2f")
    slider("Above room tone by (dB)", "breath_floor_db", 0, 20, "%.0f")
    slider("Join fragments up to (ms)", "breath_join_ms", 0, 150, "%.0f")
    slider("Length from (ms)##brt", "breath_min_ms", 30, 500, "%.0f")
    slider("Length to (ms)##brt", "breath_max_ms", 200, 2000, "%.0f")
    -- Detection finds the core; these decide how far the clip reaches past it.
    -- Too short and the gain step lands inside the breath.
    ImGui.TextDisabled(ctx, "how far the clip reaches past the detected core:")
    slider("Edge HF fraction", "breath_edge_frac", 0.1, 1.0, "%.2f")
    slider("Edge above room tone (dB)", "breath_edge_db", 0, 12, "%.0f")
    slider("Edge smoothing (ms)", "breath_edge_smooth_ms", 4, 60, "%.0f")
    ImGui.TextDisabled(ctx, "then each end snaps to the bottom of its valley:")
    slider("Look for the bottom within (ms)", "breath_valley_ms", 0, 400, "%.0f")
    slider("Give up once it climbs (dB)", "breath_valley_rise_db", 1, 15, "%.0f")
    ImGui.TextDisabled(ctx, "graded, averaged, compared against Sensitivity:")
    slider("Below the singing from (dB)", "breath_rel_lo_db", -60, -10, "%.0f")
    slider("Below the singing to (dB)", "breath_rel_hi_db", -30, 0, "%.0f")
    slider("Steadiest rise (dB)", "breath_slope_max_db", 0, 30, "%.0f")
  end

  if ImGui.CollapsingHeader(ctx, "Hard consonants") then
    local d = ST.tree and ST.tree.cons_diag
    if d then
      local parts = {}
      for k, v in pairs(d.why) do
        parts[#parts + 1] = string.format("%s (%d)", k, v)
      end
      table.sort(parts)
      ImGui.TextDisabled(ctx, string.format(
        "%d onsets over the rise threshold  ->  %d taken", d.onsets, d.taken))
      if #parts > 0 then
        ImGui.TextDisabled(ctx, "rejected: " .. table.concat(parts, ", "))
      end
    end
    ImGui.TextDisabled(ctx, "bursts -- the plosives, found by their onset:")
    slider("Rise over 10 ms (dB)", "cons_onset_db", 4, 30, "%.0f")
    slider("Closure below the burst (dB)", "cons_closure_drop_db", 2, 30, "%.0f")
    slider("Closure window (ms)", "cons_closure_ms", 10, 120, "%.0f")
    slider("Length from (ms)##cons", "cons_min_ms", 2, 40, "%.0f")
    slider("Length to (ms)##cons", "cons_max_ms", 20, 250, "%.0f")
    slider("Voiced at most##cons", "cons_voice_max", 0.05, 1.0, "%.2f")
    slider("Bridge voiced flicker (ms)", "cons_join_ms", 0, 60, "%.0f")
    -- The other kind of hard consonant has no burst at all and is found by
    -- the sibilance scan below, which files anything shorter than its own
    -- minimum length as a consonant.
    ImGui.TextDisabled(ctx, string.format(
      "releases without a burst are found by the sibilance scan -- anything\n" ..
      "shorter than %.0f ms there is a hard consonant, not a sibilant.",
      cfg.sib_min_ms))
  end

  if ImGui.CollapsingHeader(ctx, "Sibilance") then
    checkbox("Auto threshold", "sib_auto")
    if cfg.sib_auto then
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, string.format("-> %.2f", ST.th and ST.th.sib_thresh or 0))
    else
      slider("Threshold", "sib_thresh", 0.10, 0.95, "%.2f")
    end
    slider("Above the gate by (dB)", "sib_level_db", 0, 30, "%.0f")
    slider("Sibilant from (ms)", "sib_min_ms", 20, 300, "%.0f")
    ImGui.TextDisabled(ctx, "shorter than that and it is filed as a hard consonant")
    slider("Length to (ms)##sib", "sib_max_ms", 50, 800, "%.0f")
    slider("Shortest element (ms)", "element_min_ms", 3, 60, "%.0f")
    slider("Tail stops above room tone (dB)", "sib_floor_db", 0, 20, "%.0f")
    -- Detection finds the core; these two decide how far out of it the clip
    -- reaches. Too short and the gain step lands inside the /s/ and stutters.
    ImGui.TextDisabled(ctx, "how far the clip reaches past the detected core:")
    slider("Follow the tail down (dB)", "sib_extend_db", 6, 40, "%.0f")
    slider("Edge threshold (x)", "sib_edge_frac", 0.20, 1.0, "%.2f")
    local grew, n = 0, 0
    if ST.tree then
      for _, sec in ipairs(ST.tree.sections) do
        for _, phr in ipairs(sec.phrases) do
          for _, el in ipairs(phr.elements) do
            if el.class == "sibilance" and el.core0 then
              n = n + 1
              grew = grew + ((el.sig_i1 - el.sig_i0) - (el.core1 - el.core0))
            end
          end
        end
      end
    end
    if n > 0 and ST.F then
      ImGui.TextDisabled(ctx, string.format(
        "%d sibilants, each clip %.0f ms longer than its core on average",
        n, grew / n * ST.F.acc_frame_dur * 1000))
    end
    slider("Crossfade (ms)##sib", "sib_crossfade_ms", 1, 40, "%.0f")
  end


  ImGui.SeparatorText(ctx, "Edit")
  slider("Crossfade (ms)", "crossfade_ms", 2, 100, "%.0f")
  slider("Tail guard (ms)", "tail_guard_ms", 0, 100, "%.0f")
  slider("Onset guard (ms)", "onset_guard_ms", 0, 100, "%.0f")
  checkbox("Only split where the gain changes", "split_only_on_change")
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, string.format("-> %d items", ST.counts.items or 0))
  checkbox("Colour items by class", "colour_items")

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Mark detection only", 170, 0) then
    local np, nel = Apply.mark(ST.item, ST.tree, ST.F, cfg)
    ST.status = string.format(
      "%d phrase markers and %d element regions written.", np, nel)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Apply", 120, 0) then
    local n = Apply.run(ST.item, ST.spans, cfg, ST.F and ST.F.origin)
    ST.status = string.format("Created %d items.", n)
    ST.F = nil   -- the item is gone; force a re-analyze
  end
end

-- Everything start() does except enter the defer loop. Split out so a test can
-- drive one frame against a stub: the panel is otherwise the only file the
-- suites cannot execute, and it is where a renamed config key lands -- as a
-- nil read that errors the frame and takes the whole panel below it with it.
function M._init(imgui, dir)
  ImGui, script_dir = imgui, dir
  local reset
  cfg, reset = Config.load()
  if #reset > 0 then
    ST.migrated = ("%d saved settings were reset to defaults: %s. They mean " ..
                   "something different now."):format(#reset, table.concat(reset, ", "))
  end
  ctx = ImGui.CreateContext("Vocal Splitter")
  return ST
end

M._frame = function(...) return frame(...) end

function M.start(imgui, dir)
  M._init(imgui, dir)

  local function loop()
    ImGui.SetNextWindowSize(ctx, 520, 720, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Vocal Splitter", true)
    if visible then
      local ok, err = pcall(frame)
      if not ok then ImGui.TextColored(ctx, 0xE05050FF, tostring(err)) end
      ImGui.End(ctx)
    end
    if open then reaper.defer(loop) end
  end
  reaper.defer(loop)
end

return M
