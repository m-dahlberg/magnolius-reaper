-- Headless tests for the detection stages.
--
-- Stages 2-4 are pure Lua, so they can be driven from a synthetic frame table
-- with known ground truth -- no REAPER, no audio. Stage 1 (the EEL kernel) is
-- not covered here; it needs REAPER and is checked by the null test.
--
--   lua test/headless.lua

-- Resolve against this file, not the working directory: under the REAPER
-- runner the cwd is REAPER's own.
local here = debug.getinfo(1, "S").source:match("^@(.+)$")
local root = here and (here:match("^(.*[/\\])"):gsub("test[/\\]$", "")) or "./"
package.path = root .. "?.lua;./?.lua;" .. package.path

local Config     = require "vs.config"
local AutoThresh = require "vs.autothresh"
local Hierarchy  = require "vs.hierarchy"
local Levels     = require "vs.levels"

local fails, checks = 0, 0
local function check(ok, msg, extra)
  checks = checks + 1
  if not ok then
    fails = fails + 1
    print(("  FAIL  %s%s"):format(msg, extra and ("  (" .. extra .. ")") or ""))
  else
    print(("  ok    %s"):format(msg))
  end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end

local Fixture = require "test.fixture"
local FLOOR = Fixture.FLOOR

------------------------------------------------------------------------- run

local function pipeline(cfg, F)
  local th = AutoThresh.gate(F, cfg)
  th.sib_thresh = AutoThresh.sib_threshold(F, th.gate_db, cfg)
  local _, gaps = Hierarchy.gate(F, th.gate_db, cfg)
  local gt = AutoThresh.gap_thresholds(gaps, cfg)
  th.section_gap_ms, th.phrase_gap_ms = gt.section_gap_ms, gt.phrase_gap_ms
  local tree, err = Hierarchy.build(F, th, cfg)
  assert(tree, err)
  Levels.cascade(tree, cfg)
  return th, tree, Hierarchy.spans(F, tree, cfg)
end

local function count(tree)
  local c = { phrase = 0, breath = 0, consonant = 0, sibilance = 0, phrases = 0 }
  for _, sec in ipairs(tree.sections) do
    c.phrases = c.phrases + #sec.phrases
    for _, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do c[el.class] = c[el.class] + 1 end
    end
  end
  c.sections = #tree.sections
  return c
end

local F = Fixture.build()
local cfg = Config.new()
cfg.gap_auto = false          -- fixture uses known gap lengths
cfg.section_gap_ms = 1500
cfg.phrase_gap_ms  = 350

print("\n== structure ==")
local th, tree, spans = pipeline(cfg, F)
print(("  gate %.1f dB (floor %.1f)  sib_thresh %.2f")
      :format(th.gate_db, th.noise_floor, th.sib_thresh))
local c = count(tree)
print(("  sections %d  phrases %d  breaths %d  consonants %d  sibilance %d")
      :format(c.sections, c.phrases, c.breath, c.consonant, c.sibilance))

check(c.sections == 2, "two sections", "got " .. c.sections)
check(c.phrases == 6, "six phrases", "got " .. c.phrases)
check(c.breath == 6, "six breaths", "got " .. c.breath)
check(c.sibilance == 6, "six sibilants", "got " .. c.sibilance)
check(c.consonant == 6, "six consonants", "got " .. c.consonant)

print("\n== gate sits between the lobes ==")
check(th.gate_db > FLOOR and th.gate_db < -30,
      "gate above room tone, below signal", ("%.1f"):format(th.gate_db))

print("\n== guard rails: no cut or its crossfade touches audio ==")
local bad = 0
for _, cut in ipairs(tree.cuts) do
  if cut.gap then
    local a, b = cut.t - cut.cf / 2, cut.t + cut.cf / 2
    if a < cut.gap.t0 or b > cut.gap.t1 then bad = bad + 1 end
  end
end
check(bad == 0, "every crossfade lies inside its gap", bad .. " violations")

print("\n== one cut per silence ==")
local per_gap = {}
for _, cut in ipairs(tree.cuts) do
  if cut.gap then per_gap[cut.gap] = (per_gap[cut.gap] or 0) + 1 end
end
local multi = 0
for _, v in pairs(per_gap) do if v > 1 then multi = multi + 1 end end
check(multi == 0, "no gap has more than one cut", multi .. " gaps with extras")

print("\n== section normalisation closes the 6 dB gap ==")
local s1, s2 = tree.sections[1], tree.sections[2]
print(("  L_s1 %.1f -> %+.1f dB    L_s2 %.1f -> %+.1f dB")
      :format(s1.level.db, s1.gain, s2.level.db, s2.gain))
check(near(s1.level.db + s1.gain, cfg.section_target_db, 0.5),
      "section 1 lands on target")
check(near(s2.level.db + s2.gain, cfg.section_target_db, 0.5),
      "section 2 lands on target")

print("\n== cascade independence: section target must not move the balance ==")
local function gains_of(target)
  local c2 = Config.new()
  c2.gap_auto = false; c2.section_gap_ms = 1500; c2.phrase_gap_ms = 350
  c2.section_target_db = target
  local _, t2 = pipeline(c2, F)
  local g = {}
  for _, sec in ipairs(t2.sections) do
    for _, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do g[#g + 1] = el.total_gain end
    end
  end
  return g
end
local ga, gb = gains_of(-18), gains_of(-8)
local ok_ind, worst = true, 0
for i = 1, #ga do
  local d = math.abs((gb[i] - ga[i]) - 10)
  worst = math.max(worst, d)
  if d > 1e-6 then ok_ind = false end
end
check(ok_ind, "every element shifts by exactly the target delta",
      ("worst deviation %.2e dB"):format(worst))

print("\n== an element offset is applied literally ==")
-- The offset is a relative attenuation of the clip that was cut out, not a
-- level to drive the element to. So the gain is the number the user typed --
-- independent of how loud the element itself was.
local OFF = { breath = cfg.breath_offset_db, consonant = cfg.cons_offset_db,
              sibilance = cfg.sib_offset_db }
local wrong, n_el, quietest = 0, 0, nil
for _, sec in ipairs(tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class ~= "phrase" then
        n_el = n_el + 1
        if math.abs(el.gain - OFF[el.class]) > 1e-9 then wrong = wrong + 1 end
        if math.abs(el.total_gain - (phr.total_gain + OFF[el.class])) > 1e-9 then
          wrong = wrong + 1
        end
        local below = phr.level.db - el.level_db
        if el.class == "breath" and (not quietest or below > quietest.below) then
          quietest = { el = el, phr = phr, below = below }
        end
      end
    end
  end
end
check(wrong == 0, ("every element gets exactly its offset (%d elements)")
      :format(n_el), wrong .. " wrong")

-- The regression this replaces: a breath sits ~20 dB under its phrase, so the
-- old "drive it to phrase + offset" was a boost, and the attenuate-only cap
-- turned that into 0 dB. The breath was cut out and then left alone.
check(quietest ~= nil, "found a breath to check")
if quietest then
  print(("  breath %.1f dB is %.1f dB under its phrase, gain %+.2f dB")
        :format(quietest.el.level_db, quietest.below, quietest.el.gain))
  check(quietest.below > 12, "and it is well below the phrase",
        ("%.1f dB"):format(quietest.below))
  check(near(quietest.el.gain, cfg.breath_offset_db, 1e-9),
        "a breath far below its phrase is still turned down by the offset",
        ("%.2f dB"):format(quietest.el.gain))
end

print("\n== the residual is never turned down ==")
-- Map every frame to the element that owns it, then check each span applies
-- that element's gain and no other. Frames below the gate are pauses: a cut has
-- to land somewhere inside one, so the room tone either side of a breath
-- necessarily travels with it. Audible material must not.
local owner_gain, owner_class = {}, {}
for _, sec in ipairs(tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      for i = el.sig_i0, el.sig_i1 do
        owner_gain[i], owner_class[i] = el.total_gain, el.class
      end
    end
  end
end
local leaked, audible, worst = 0, 0, 0
for _, s in ipairs(spans) do
  local i0 = math.max(1, math.floor(s.t0 / F.acc_frame_dur) + 1)
  local i1 = math.min(F.n, math.ceil(s.t1 / F.acc_frame_dur))
  for i = i0, i1 do
    if F.level_db[i] > th.gate_db and owner_gain[i] then
      audible = audible + 1
      local d = math.abs(s.gain_db - owner_gain[i])
      if d > 1e-6 then
        leaked = leaked + 1
        worst = math.max(worst, d)
      end
    end
  end
end
-- A frame or two at each boundary is the cut falling mid-frame, not a leak.
check(leaked <= #spans, ("audible audio keeps its own gain (%d frames, %d at a boundary)")
      :format(audible, leaked), ("worst %.1f dB"):format(worst))

-- The other half, and the requirement in its own words: a clip cut out for a
-- detected element must contain that element and nothing else. Attribution is
-- by content, not by midpoint -- a cut sits inside a pause, so the midpoint of
-- a breath's span lands wherever the surrounding silence puts it.
local impure, el_spans = 0, 0
for _, s2 in ipairs(spans) do
  if s2.class ~= "phrase" then
    el_spans = el_spans + 1
    local i0 = math.max(1, math.floor(s2.t0 / F.acc_frame_dur) + 1)
    local i1 = math.min(F.n, math.ceil(s2.t1 / F.acc_frame_dur) - 1)
    for i = i0, i1 do
      if F.level_db[i] > th.gate_db and owner_class[i]
         and owner_class[i] ~= s2.class then
        impure = impure + 1
      end
    end
  end
end
check(impure <= el_spans,
      ("an element clip holds only that element (%d clips)"):format(el_spans),
      impure .. " foreign audible frames")

print("\n== spans tile the item with no gaps or overlaps ==")
local prev, tile_ok = 0, true
for _, s in ipairs(spans) do
  if math.abs(s.t0 - prev) > 1e-9 then tile_ok = false end
  prev = s.t1
end
check(tile_ok and near(prev, F.item_len, 1e-6), "spans are contiguous",
      ("end %.4f vs %.4f"):format(prev, F.item_len))

-- Each level can be disabled to run one process on its own. Disabling
-- collapses that level into a single node spanning its parent, so the
-- reference a lower level measures against falls back automatically.
print("\n== reference falls back when a level is disabled ==")

local function isolated(sections_on, phrases_on)
  local c = Config.new()
  c.gap_auto = false; c.section_gap_ms = 1500; c.phrase_gap_ms = 350
  c.enable_section, c.enable_phrase = sections_on, phrases_on
  local _, t = pipeline(c, F)
  local nsec, nphr = #t.sections, 0
  for _, sec in ipairs(t.sections) do nphr = nphr + #sec.phrases end
  local refs, breaths = {}, 0
  for _, sec in ipairs(t.sections) do
    for _, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do
        if el.class == "breath" then
          breaths = breaths + 1
          refs[#refs + 1] = phr.level.db
        end
      end
    end
  end
  return { nsec = nsec, nphr = nphr, refs = refs, breaths = breaths,
           tree = t, cfg = c }
end

-- Whole-file reference, measured the same way a node is.
local file_ref = Levels.measure(F, 1, F.n, Config.new(),
                                AutoThresh.gate(F, Config.new()).gate_db).db
print(("  whole-file reference %.2f dB"):format(file_ref))

local both = isolated(true, true)
check(both.nsec == 2 and both.nphr == 6, "both on: 2 sections, 6 phrases",
      ("%d / %d"):format(both.nsec, both.nphr))

local no_sec = isolated(false, true)
check(no_sec.nsec == 1, "sections off collapses to one section",
      "got " .. no_sec.nsec)
check(no_sec.nphr == 6, "phrases still detected", "got " .. no_sec.nphr)

local no_phr = isolated(true, false)
check(no_phr.nsec == 2 and no_phr.nphr == 2,
      "phrases off gives one phrase per section",
      ("%d / %d"):format(no_phr.nsec, no_phr.nphr))

local neither = isolated(false, false)
check(neither.nsec == 1 and neither.nphr == 1,
      "both off collapses to a single node")
check(math.abs(neither.refs[1] - file_ref) < 0.01,
      "with both off, the reference is the whole file",
      ("%.2f vs %.2f"):format(neither.refs[1] or -99, file_ref))

print("\n== breaths survive with phrases disabled ==")
check(neither.breaths == 6, "all six breaths still found",
      "got " .. neither.breaths)
check(no_phr.breaths == 6, "and with sections on, phrases off",
      "got " .. no_phr.breaths)

print("\n== a disabled level contributes no gain ==")
local zero_sec, zero_phr = true, true
for _, sec in ipairs(no_sec.tree.sections) do
  if math.abs(sec.gain) > 1e-9 then zero_sec = false end
end
for _, sec in ipairs(no_phr.tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    if math.abs(phr.gain) > 1e-9 then zero_phr = false end
  end
end
check(zero_sec, "sections off -> zero section gain")
check(zero_phr, "phrases off -> zero phrase gain")

print("\n== an isolated element process only moves that element ==")
-- With sections and phrases both off there is no normalisation at all, so a
-- breath must come out at exactly its own level plus the offset, and every
-- other clip must be left at unity. This is the "run one process on its own"
-- case the panel is built around.
local br, bphr
for _, sec in ipairs(neither.tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class == "breath" and not br then br, bphr = el, phr end
    end
  end
end
check(br ~= nil, "found a breath with everything else disabled")
if br then
  local final = bphr.total_gain + br.gain + br.level_db
  local want = br.level_db + neither.cfg.breath_offset_db
  print(("  breath %.1f dB -> %.1f dB (want %.1f %+.0f = %.1f)")
        :format(br.level_db, final, br.level_db,
                neither.cfg.breath_offset_db, want))
  check(near(final, want, 1e-9), "breath is turned down by exactly the offset",
        ("off by %.2f dB"):format(final - want))
  check(near(bphr.total_gain, 0, 1e-9),
        "and nothing else was normalised", ("%.2f dB"):format(bphr.total_gain))
end

local moved = 0
for _, sec in ipairs(neither.tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class == "phrase" and math.abs(el.total_gain) > 1e-9 then
        moved = moved + 1
      end
    end
  end
end
check(moved == 0, "the residual between elements stays at unity",
      moved .. " residual pieces moved")

----------------------------------------------------------------- the hard case

-- Fixture.build_hard() carries the two things the defaults used to fail on:
-- sibilants whose edges fade well below half their own peak ratio, and breaths
-- recorded close enough to sit only 8 dB under the phrase.
print("\n== hard case: sibilance extent spans the whole sound ==")
local HF = Fixture.build_hard()
local hcfg = Config.new()
hcfg.gap_auto = false; hcfg.section_gap_ms = 1500; hcfg.phrase_gap_ms = 350
local hth, htree, hspans = pipeline(hcfg, HF)

local sibs = {}
for _, sec in ipairs(htree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class == "sibilance" then sibs[#sibs + 1] = el end
    end
  end
end
check(#sibs == #HF.marks.sib0, ("every sibilant found (%d of %d)")
      :format(#sibs, #HF.marks.sib0))

local worst_cover, grew_start, grew_end = 1, 0, 0
for k, el in ipairs(sibs) do
  local t0, t1 = HF.marks.sib0[k], HF.marks.sib1[k] - 1
  local lo = math.max(el.sig_i0, t0)
  local hi = math.min(el.sig_i1, t1)
  worst_cover = math.min(worst_cover, (hi - lo + 1) / (t1 - t0 + 1))
  if el.sig_i0 < el.core0 then grew_start = grew_start + 1 end
  if el.sig_i1 > el.core1 then grew_end = grew_end + 1 end
end
print(("  sibilant 1: true %d..%d, core %d..%d, clip %d..%d")
      :format(HF.marks.sib0[1], HF.marks.sib1[1] - 1,
              sibs[1].core0, sibs[1].core1, sibs[1].sig_i0, sibs[1].sig_i1))
check(worst_cover > 0.95, "the clip covers the whole fricative",
      ("worst coverage %.0f%%"):format(worst_cover * 100))
check(grew_start == #sibs, "the extent grew backwards past the core",
      ("%d of %d"):format(grew_start, #sibs))
check(grew_end == #sibs, "and forwards past it",
      ("%d of %d"):format(grew_end, #sibs))

-- The core is what detection alone would have cut to, and it is short at both
-- ends. That gap is the stutter: a gain step part way through the /s/.
local core_cover = 1
for k, el in ipairs(sibs) do
  local t0, t1 = HF.marks.sib0[k], HF.marks.sib1[k] - 1
  core_cover = math.min(core_cover, (el.core1 - el.core0 + 1) / (t1 - t0 + 1))
end
check(core_cover < 0.85, "and the detected core alone would have been short",
      ("core covers %.0f%%"):format(core_cover * 100))

-- No clip may start or end inside the loud part of the sound: that is what is
-- actually heard as a jump.
local inside = 0
for _, sp in ipairs(hspans) do
  for _, edge in ipairs({ sp.t0, sp.t1 }) do
    local i = math.floor(edge / HF.acc_frame_dur) + 1
    if i > 1 and i < HF.n then
      for k = 1, #sibs do
        local el = sibs[k]
        if i > el.core0 and i <= el.core1 then inside = inside + 1 end
      end
    end
  end
end
check(inside == 0, "no clip boundary falls inside a fricative's core",
      inside .. " boundaries inside")

print("\n== hard case: close-mic'd breaths are found, and can be steered ==")
local last_tree
local function breaths_at(sens)
  local c = Config.new()
  c.gap_auto = false; c.section_gap_ms = 1500; c.phrase_gap_ms = 350
  c.breath_sensitivity = sens
  local _, t = pipeline(c, HF)
  last_tree = t
  local n = 0
  for _, sec in ipairs(t.sections) do
    for _, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do
        if el.class == "breath" then n = n + 1 end
      end
    end
  end
  return n, t.breath_diag
end

local n_def, d_def = breaths_at(Config.defaults.breath_sensitivity)
print(("  %d runs -> %d candidates -> %d breaths at the default sensitivity")
      :format(d_def.runs, d_def.candidates, d_def.accepted))
check(n_def == 3, "all three breaths detected at the default", "got " .. n_def)

local n_strict, d_strict = breaths_at(0)
check(n_strict < n_def, "sensitivity 0 is stricter",
      ("%d vs %d"):format(n_strict, n_def))
check(d_strict.rejected > 0 and next(d_strict.weak) ~= nil,
      "and the panel is told which feature held them back")
if d_strict.rejected > 0 then
  local names = {}
  for k, v in pairs(d_strict.weak) do names[#names + 1] = k .. "=" .. v end
  table.sort(names)
  print(("  at sensitivity 0: %d rejected, weakest %s, best score %.2f")
        :format(d_strict.rejected, table.concat(names, " "), d_strict.best_rejected))
end
check(breaths_at(100) >= n_def, "sensitivity 100 is no stricter")

-- The hard tests are not negotiable at any sensitivity: a sung phrase is not a
-- breath however permissive the score threshold gets. Voicing, the HF band and
-- prominence over the local floor are applied per frame, so a sung phrase
-- never becomes a run in the first place -- which is why this asserts that no
-- run covers voiced audio rather than counting rejections.
local voiced_run = false
for _, r in ipairs(d_def.list) do
  for i = r.core0, r.core1 do
    if HF.voice_ratio[i] > Config.defaults.breath_voice_max then
      voiced_run = true
    end
  end
end
check(not voiced_run, "no candidate core covers voiced audio")

-- The clip has to hold the whole breath, not just the part that passed the
-- per-frame tests. The fixture's breaths are rectangles, so the extent can
-- only equal the core there; what this asserts is that the extent is never
-- *narrower* than the core -- the failure mode being a growth rule that
-- somehow trims.
breaths_at(Config.defaults.breath_sensitivity)
local narrow = 0
for _, b in ipairs(last_tree.breaths or {}) do
  if b.i0 > b.core0 or b.i1 < b.core1 then narrow = narrow + 1 end
end
check(narrow == 0, "no breath clip is narrower than its own core", narrow)

print("\n== the gate cannot see these breaths, and the scan must ==")
-- The regression this whole stage exists for. Detection is a feature scan, so
-- neither of these depends on the gate resolving a segment.
local GF = Fixture.build_gateless()
local gcfg = Config.new()
gcfg.gap_auto = false
gcfg.section_gap_ms = 1500
gcfg.phrase_gap_ms  = 350
gcfg.gate_auto = false
gcfg.gate_db   = -40          -- above the breaths, where room tone forces it
local gth, gtree, gspans = pipeline(gcfg, GF)

-- Both breaths really are invisible to the gate: assert that before asserting
-- they were found, or the test could pass for the wrong reason.
local segs = Hierarchy.gate(GF, gth.gate_db, gcfg)
local truth = {}
for k = 1, #GF.marks.breath0 do
  truth[k] = { i0 = GF.marks.breath0[k], i1 = GF.marks.breath1[k] - 1 }
end
local covered = 0
for _, t in ipairs(truth) do
  for _, sg in ipairs(segs) do
    if sg.i0 <= t.i0 and sg.i1 >= t.i1 then covered = covered + 1 end
  end
end
check(covered == 0, "neither breath is a gate segment", covered .. " were")

local found = {}
for _, sec in ipairs(gtree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class == "breath" then found[#found + 1] = el end
    end
  end
end
check(#found == 2, "both breaths are found anyway", "got " .. #found)

for k, t in ipairs(truth) do
  local hit = nil
  for _, el in ipairs(found) do
    if el.sig_i1 >= t.i0 and el.sig_i0 <= t.i1 then hit = el end
  end
  check(hit ~= nil, ("breath %d is found where the fixture put it"):format(k))
  if hit then
    local cover = (math.min(hit.sig_i1, t.i1) - math.max(hit.sig_i0, t.i0) + 1)
                / (t.i1 - t.i0 + 1)
    check(cover > 0.8, ("breath %d's clip covers the breath"):format(k),
          ("%.0f%%"):format(cover * 100))
  end
end

-- And the gain actually lands on it. A breath below the gate is exactly the
-- case where span attribution used to hand the clip back to its phrase: the
-- span held no frame above the gate, so it read as a pause and took the
-- phrase's gain, leaving the breath at unity after all the work of finding it.
local gonly = Config.new()
for _, k in ipairs({ "enable_section", "enable_phrase", "enable_cons",
                     "enable_sib" }) do gonly[k] = false end
gonly.gap_auto = false
gonly.section_gap_ms, gonly.phrase_gap_ms = 1500, 350
gonly.gate_auto, gonly.gate_db = false, -40
local _, _, ospans = pipeline(gonly, GF)
local moved = 0
for _, sp in ipairs(ospans) do
  if sp.class == "breath" then
    moved = moved + 1
    check(near(sp.gain_db, gonly.breath_offset_db, 1e-9),
          "the sub-gate breath clip carries the offset",
          ("%.2f dB"):format(sp.gain_db))
  end
end
check(moved == 2, "and both breath clips exist as spans", "got " .. moved)

-- ExtState is stubbed for every panel test below. Under the REAPER runner
-- `reaper` is real, and the panel writes settings straight through on any
-- click -- Reset, but also All and None -- so without this the suite quietly
-- resets the user's own settings every time it runs. It did, twice, before the
-- stub covered the whole section rather than just the control that was
-- obviously dangerous.
local _es_set, _es_get, _es_has
if reaper then
  _es_set, _es_get, _es_has =
    reaper.SetExtState, reaper.GetExtState, reaper.HasExtState
  reaper.SetExtState = function() end
  reaper.GetExtState = function() return "" end
  reaper.HasExtState = function() return false end
end


-- Every span must be at least as long as the crossfades that meet in it.
--
-- Each fade eats half its length off either side of its cut, and REAPER
-- expresses a crossfade by moving the right-hand item *earlier* -- so a fade
-- longer than the item to its left moves that item's neighbour past it and the
-- timeline stops being ordered. A 5.3 ms span with a 5 ms fade on one side and
-- a 20 ms fade on the other opened a 2.2 second hole in the middle of a take.
print("\n== no span is shorter than the crossfades that meet in it ==")
local crushed = {}
for _, sp in ipairs(spans) do
  local need = (sp.cf_in + sp.cf_out) / 2
  if sp.t1 - sp.t0 < need - 1e-9 then
    crushed[#crushed + 1] = ("%.3f-%.3f is %.1f ms but needs %.1f")
      :format(sp.t0, sp.t1, (sp.t1 - sp.t0) * 1000, need * 1000)
  end
end
check(#crushed == 0, "every span outlasts its own fades",
      table.concat(crushed, ", "))

print("\n== reliable means the estimate that was used, not any estimate ==")
do
  -- Plenty of audio above the gate, almost none of it voiced. In voiced mode
  -- the measurement falls back to the gated mean, which is not a voiced
  -- reference -- so the node must inherit rather than normalise toward it.
  -- The old test asked only whether *some* count cleared the threshold and
  -- said yes on the gated one.
  local U = Fixture.builder()
  U.emit(0.02, -30, 0.90, 0.05)     -- a few voiced frames
  U.emit(0.60, -30, 0.05, 0.60)     -- a lot of unvoiced audio, same level
  U.finish()

  local c = Config.new()
  local voiced = Levels.measure(U, 1, U.n, c, -60)
  check(voiced.voiced_frames < c.min_voiced_frames
        and voiced.gated_frames >= c.min_voiced_frames,
        "the fixture is the awkward shape",
        ("voiced %d, gated %d"):format(voiced.voiced_frames, voiced.gated_frames))
  check(not voiced.from_voiced, "voiced mode falls back to the gated mean")
  check(not voiced.reliable, "and reports the fallback as unreliable")

  local c2 = Config.new()
  c2.level_mode = "above_gate"
  local gated = Levels.measure(U, 1, U.n, c2, -60)
  check(gated.reliable, "above_gate mode is reliable on the same frames")
end

print("\n== a phrase that is nothing but a breath is not normalised ==")
do
  local BF = Fixture.build_breath_phrase()
  local c = Config.new()
  c.gap_auto = false
  c.section_gap_ms, c.phrase_gap_ms = 1500, 350
  c.gate_auto, c.gate_db = false, -56   -- above the room, below the singing
  local bth, btree = pipeline(c, BF)

  local own, holder, holder_i = nil, nil, nil
  for si, sec in ipairs(btree.sections) do
    for pi, phr in ipairs(sec.phrases) do
      for _, el in ipairs(phr.elements) do
        if el.class == "breath" then own, holder, holder_i = el, phr, si end
      end
    end
  end
  check(own ~= nil, "the breath is detected")

  -- The setup only means anything if the gate really did give the breath a
  -- phrase to itself, so assert that before assering what happens to it.
  local alone = holder and true or false
  if holder then
    for _, el in ipairs(holder.elements) do
      if el.class == "phrase" then alone = false end
    end
  end
  check(alone, "and the gate gave it a phrase of its own")

  if holder then
    check(not holder.level.reliable,
          "that phrase has no reference of its own to normalise to",
          ("voiced %d, gated %d, level %.1f dB")
          :format(holder.level.voiced_frames, holder.level.gated_frames,
                  holder.level.db))
    check(near(holder.gain, 0, 1e-9), "so it is not normalised",
          ("%.2f dB"):format(holder.gain))
    local sec = btree.sections[holder_i]
    check(near(own.total_gain, sec.gain + c.breath_offset_db, 1e-9),
          "and the breath gets its section's gain plus the offset, nothing more",
          ("%.2f vs %.2f"):format(own.total_gain, sec.gain + c.breath_offset_db))
    check(own.total_gain < 0 or own.total_gain < sec.gain + 0.001,
          "which is never a boost relative to the audio around it",
          ("breath %.2f dB, section %.2f dB"):format(own.total_gain, sec.gain))
  end
end

print("\n== the panel renders a frame without throwing ==")
do
  local UI = require "vs.ui"
  local UIFrame = require "test.ui_frame"

  -- Before analysis: the panel returns early, and must survive doing so.
  local ok, err, log = UIFrame.run(UI, root)
  check(ok, "an empty panel renders", not ok and tostring(err) or nil)
  check(log.push == log.pop, "style colours are balanced",
        ("%d pushed, %d popped"):format(log.push, log.pop))
  check(log.dis == 0, "BeginDisabled/EndDisabled are balanced", log.dis)

  -- With results: every collapsing panel, every slider, every diagnostic
  -- read. This is the pass that catches a renamed config key or a diagnostic
  -- field that moved.
  local pcfg = Config.new()
  pcfg.gap_auto = false
  pcfg.section_gap_ms, pcfg.phrase_gap_ms = 1500, 350
  local pth, ptree, pspans = pipeline(pcfg, F)
  local ok2, err2, log2, st = UIFrame.run(UI, root, function(ST)
    ST.F, ST.th, ST.tree, ST.spans = F, pth, ptree, pspans
    ST.item = true
    ST.counts = { phrase = 0, breath = 0, consonant = 0, sibilance = 0, items = #pspans }
    ST.migrated = "a migration notice, so its branch is rendered too"
    ST.confirm_reset = true      -- and the reset confirmation branch
  end)
  check(ok2, "a full panel renders", not ok2 and tostring(err2) or nil)
  check(log2.push == log2.pop, "style colours are balanced with results",
        ("%d pushed, %d popped"):format(log2.push, log2.pop))
  check(log2.dis == 0, "BeginDisabled/EndDisabled are balanced with results", log2.dis)
end

-- Reset is the one control with no undo behind it -- it writes ExtState
-- straight through -- so both of its steps are exercised, not just drawn.
do
  local UI = require "vs.ui"
  local UIFrame = require "test.ui_frame"


  local ok3, err3, _, st3 = UIFrame.run(UI, root, nil,
    { ["Reset settings"] = true })
  check(ok3, "the reset button renders", not ok3 and tostring(err3) or nil)
  check(st3.confirm_reset == true, "one click only arms the confirmation")

  local ok4, err4, _, st4 = UIFrame.run(UI, root,
    function(ST) ST.confirm_reset = true end,
    { ["Really reset?"] = true })
  check(ok4, "confirming resets without throwing",
        not ok4 and tostring(err4) or nil)
  check(st4.confirm_reset == nil, "and disarms the confirmation")
  check(st4.status and st4.status:find("reset", 1, true) ~= nil,
        "and says so", tostring(st4.status))

  local ok5, _, _, st5 = UIFrame.run(UI, root,
    function(ST) ST.confirm_reset = true end, { Cancel = true })
  check(ok5 and st5.confirm_reset == nil, "cancel disarms it too")

end

print("\n== every panel control names a real setting ==")
-- The panel is the one file the headless tests cannot execute -- it needs a
-- ReaImGui context and a defer loop. But its controls are all `slider(label,
-- key, ...)` and `checkbox(label, key)`, so the keys can be read out of the
-- source and checked against the defaults. This is the failure that follows
-- every rename in config.lua: the control reads cfg[key] as nil, the frame
-- errors, and the whole panel below it disappears behind one red line.
local uif = assert(io.open(root .. "vs/ui.lua", "r"))
local usrc = uif:read("a")
uif:close()
local bad, seen = {}, 0
for key in usrc:gmatch('slider%s*%(%s*"[^"]*"%s*,%s*"([%w_]+)"') do
  seen = seen + 1
  if Config.defaults[key] == nil then bad[#bad + 1] = "slider " .. key end
end
for key in usrc:gmatch('checkbox%s*%(%s*"[^"]*"%s*,%s*"([%w_]+)"') do
  seen = seen + 1
  if Config.defaults[key] == nil then bad[#bad + 1] = "checkbox " .. key end
end
check(seen > 20, ("the panel was scanned (%d controls)"):format(seen))
check(#bad == 0, "every control names a key that exists",
      table.concat(bad, ", "))

-- And the reverse, as a reminder rather than a rule: a setting with no
-- control can only be reached by editing ExtState by hand.
local hidden = {}
for k in pairs(Config.defaults) do
  if not usrc:find('"' .. k .. '"', 1, true) then hidden[#hidden + 1] = k end
end
table.sort(hidden)
if #hidden > 0 then
  print(("  note  %d settings have no panel control: %s")
        :format(#hidden, table.concat(hidden, ", ")))
end

if reaper then
  reaper.SetExtState, reaper.GetExtState, reaper.HasExtState =
    _es_set, _es_get, _es_has
end

print(("\n%d/%d checks passed"):format(checks - fails, checks))
os.exit(fails == 0 and 0 or 1)
