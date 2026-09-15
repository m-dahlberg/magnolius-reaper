-- Detection, scored against real audio with known ground truth.
--
--   lua test/detection.lua
--
-- The synthetic fixtures in test/headless.lua prove the stages behave as
-- specified. They cannot prove the specification matches a voice, and that is
-- where every detection bug in this script has actually lived: a "breath" at
-- sib_ratio 0.78, a burst peak read off the following vowel, six ANDed windows
-- that each looked reasonable. This suite runs the same stages over the frame
-- features of "VocalSplit test.wav" and checks every element Magnus counted by
-- ear is found, in the right class, and that nothing else is.
--
-- Consonant timestamps are his. Sibilants follow by elimination: he counted
-- six, the scan found eight, and two of the eight are in his consonant list.
-- Breaths are the four the scan found, and the count matches his.

-- Resolve paths against this file, not the working directory: run through
-- REAPER the cwd is REAPER's own, and the fixture is read with io.open.
local here = debug.getinfo(1, "S").source:match("^@(.+)$")
local root = here and (here:match("^(.*[/\\])"):gsub("test[/\\]$", "")) or "./"
package.path = root .. "?.lua;./?.lua;" .. package.path

local Config     = require "vs.config"
local AutoThresh = require "vs.autothresh"
local Hierarchy  = require "vs.hierarchy"
local Levels     = require "vs.levels"
local Frames     = require "test.frames"

local TRUTH = {
  { "consonant", { 2.66, 7.31, 8.31, 14.25, 14.98, 17.81, 21.46, 25.54, 27.69 } },
  { "sibilance", { 1.46, 8.40, 15.59, 17.06, 18.37, 24.09 } },
  { "breath",    { 4.73, 11.08, 16.71, 21.94 } },
}

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

local F = Frames.load(root .. "test/vocalsplit_frames.tsv")
local cfg = Config.new()
local th = AutoThresh.gate(F, cfg)
th.sib_thresh = AutoThresh.sib_threshold(F, th.gate_db, cfg)
local _, gaps = Hierarchy.gate(F, th.gate_db, cfg)
local gt = AutoThresh.gap_thresholds(gaps, cfg)
th.section_gap_ms, th.phrase_gap_ms = gt.section_gap_ms, gt.phrase_gap_ms
local tree, err = Hierarchy.build(F, th, cfg)
assert(tree, err)
Levels.cascade(tree, cfg)

local els = {}
for _, sec in ipairs(tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class ~= "phrase" then
        el.t0 = Hierarchy.ftime(F, el.sig_i0)
        el.t1 = Hierarchy.ftime(F, el.sig_i1 + 1)
        els[#els + 1] = el
      end
    end
  end
end
table.sort(els, function(a, b) return a.t0 < b.t0 end)

-- A mark counts as found if the clip contains it, give or take one frame's
-- worth of where the sound is judged to begin.
local TOL = 0.06
local matched = {}

print(("\n%d frames, gate %.1f dB, sib threshold %.2f")
      :format(F.n, th.gate_db, th.sib_thresh))
for _, group in ipairs(TRUTH) do
  local class, marks = group[1], group[2]
  print("\n" .. class)
  for _, t in ipairs(marks) do
    local best
    for i, el in ipairs(els) do
      if t >= el.t0 - TOL and t <= el.t1 + TOL then
        if not best or el.class == class then best = i end
      end
    end
    local el = best and els[best]
    if best then matched[best] = true end
    check(el ~= nil and el.class == class,
          ("%.2f s"):format(t),
          el and ("found as " .. el.class) or "nothing detected there")
  end
end

print("\nnothing else is detected")
local spurious = {}
for i, el in ipairs(els) do
  if not matched[i] then
    spurious[#spurious + 1] = ("%s %.3f-%.3f"):format(el.class, el.t0, el.t1)
  end
end
check(#spurious == 0, "no element is detected where none was counted",
      table.concat(spurious, ", "))

-- The clip has to hold the whole sound. A gain step inside a breath or an /s/
-- is heard as a stutter, and truncation is the failure these classes keep
-- coming back to -- both were found on their cores alone at some point.
print("\nclips are not truncated to the core")
local MIN_MS = { breath = 200, sibilance = 100, consonant = 20 }
local short = {}
for _, el in ipairs(els) do
  local ms = (el.t1 - el.t0) * 1000
  if ms < MIN_MS[el.class] then
    short[#short + 1] = ("%s %.3f (%.0f ms)"):format(el.class, el.t0, ms)
  end
end
check(#short == 0, "every clip is a plausible length for its class",
      table.concat(short, ", "))

-- A breath is a smooth ramp up out of one pause and back down into the next,
-- so both of its ends belong at the bottom of the valley beside it. Stopping
-- part way down the slope is the visible failure -- the clip covers the loud
-- middle and the gain step lands where the ear can hear it -- and it is the
-- failure this class keeps returning to, so it is asserted directly: no frame
-- just outside a breath clip may be meaningfully quieter than its edge.
print("\nbreath clips end at the bottom of the valley")
local sm = math.max(1, math.floor(0.016 / F.acc_frame_dur + 0.5))
local function smooth_db(i)
  local a, b = math.max(1, i - sm), math.min(F.n, i + sm)
  local acc = 0
  for k = a, b do acc = acc + F.ms[k] end
  return Frames.db(acc / (b - a + 1))
end

local LOOK = math.floor(0.060 / F.acc_frame_dur + 0.5)   -- 60 ms either side
local TOL  = 2                                           -- dB
local slopes = {}
for _, b in ipairs(tree.breaths or {}) do
  local head, tail = smooth_db(b.i0), smooth_db(b.i1)
  local t0 = Hierarchy.ftime(F, b.i0)
  for k = math.max(1, b.i0 - LOOK), b.i0 - 1 do
    if smooth_db(k) < head - TOL then
      slopes[#slopes + 1] = ("%.3f head is %.1f dB up the slope")
                            :format(t0, head - smooth_db(k))
      break
    end
  end
  for k = b.i1 + 1, math.min(F.n, b.i1 + LOOK) do
    if smooth_db(k) < tail - TOL then
      slopes[#slopes + 1] = ("%.3f tail is %.1f dB up the slope")
                            :format(t0, tail - smooth_db(k))
      break
    end
  end
end
check(#slopes == 0, "no breath clip stops part way down a slope",
      table.concat(slopes, ", "))

-- Every pause that separates two phrases or two sections has to end up with a
-- boundary. The failure this replaces was silent: cuts were placed from the
-- gap list before the elements existed, and any that landed inside one were
-- *dropped* rather than moved, so the boundary simply disappeared. Three of
-- seven went that way on this take, including a section boundary.
print("\nevery structural pause has a boundary")
local missing = {}
for _, g in ipairs(tree.gaps or {}) do
  local ms = g.dur * 1000
  if ms >= th.phrase_gap_ms and not g.cut then
    missing[#missing + 1] = ("%.3f-%.3f (%.0f ms)"):format(g.t0, g.t1, ms)
  end
end
check(#missing == 0, "no phrase or section boundary was lost",
      table.concat(missing, ", "))

-- And none of them may land inside a detected element: a boundary there splits
-- the sound instead of the pause, and no crossfade is short enough to hide it.
print("\nno boundary lands inside a detected element")
local inside = {}
for _, c in ipairs(tree.cuts) do
  if c.gap then
    for _, el in ipairs(els) do
      if c.t > el.t0 + 1e-9 and c.t < el.t1 - 1e-9 then
        inside[#inside + 1] = ("%.3f inside %s %.3f-%.3f")
                              :format(c.t, el.class, el.t0, el.t1)
      end
    end
  end
end
check(#inside == 0, "every structural cut is in silence, not in a sound",
      table.concat(inside, ", "))

-- A node with no reference of its own must inherit, never normalise. The
-- shape that breaks this is a breath the gate isolated into a segment: it
-- becomes a phrase, measures itself, and is driven up to its section. On this
-- take that was +20.3 dB of phrase gain, putting a breath 24 dB up while
-- everything around it moved 9.
print("\nnothing is normalised toward its own breath")
local bad_norm, unref = {}, 0
for _, sec in ipairs(tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    if phr.level.voiced_frames < cfg.min_voiced_frames then
      unref = unref + 1
      if math.abs(phr.gain) > 1e-9 then
        bad_norm[#bad_norm + 1] = ("%.3f-%.3f gained %.2f dB from a reference "
          .. "of %d voiced frames"):format(phr.t0, phr.t1, phr.gain,
                                           phr.level.voiced_frames)
      end
    end
  end
end
check(unref > 0, "this take has a phrase with no reference of its own",
      ("%d"):format(unref))
check(#bad_norm == 0, "and it inherits rather than normalising",
      table.concat(bad_norm, ", "))

-- The consequence, stated as the thing you would actually hear.
local loudest_phrase = -math.huge
for _, sec in ipairs(tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    if phr.level.reliable then
      loudest_phrase = math.max(loudest_phrase, phr.total_gain)
    end
  end
end
local shouty = {}
for _, sec in ipairs(tree.sections) do
  for _, phr in ipairs(sec.phrases) do
    for _, el in ipairs(phr.elements) do
      if el.class ~= "phrase" and el.total_gain > loudest_phrase then
        shouty[#shouty + 1] = ("%s at %.3f gets %.2f dB, more than any phrase (%.2f)")
          :format(el.class, Hierarchy.ftime(F, el.sig_i0), el.total_gain,
                  loudest_phrase)
      end
    end
  end
end
check(#shouty == 0, "no element is turned up past the loudest phrase",
      table.concat(shouty, ", "))


-- Every span must be at least as long as the crossfades that meet in it.
--
-- Each fade eats half its length off either side of its cut, and REAPER
-- expresses a crossfade by moving the right-hand item *earlier* -- so a fade
-- longer than the item to its left moves that item's neighbour past it and the
-- timeline stops being ordered. A 5.3 ms span with a 5 ms fade on one side and
-- a 20 ms fade on the other opened a 2.2 second hole in the middle of a take.
print("\nno span is shorter than the crossfades that meet in it")
local crushed = {}
for _, sp in ipairs(Hierarchy.spans(F, tree, cfg)) do
  local need = (sp.cf_in + sp.cf_out) / 2
  if sp.t1 - sp.t0 < need - 1e-9 then
    crushed[#crushed + 1] = ("%.3f-%.3f is %.1f ms but needs %.1f")
      :format(sp.t0, sp.t1, (sp.t1 - sp.t0) * 1000, need * 1000)
  end
end
check(#crushed == 0, "every span outlasts its own fades",
      table.concat(crushed, ", "))

print(("\n%d/%d checks passed"):format(checks - fails, checks))
if os.exit then os.exit(fails == 0 and 0 or 1) end
