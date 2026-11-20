-- AAF Importer -- headless suite. Pure Lua, no REAPER API.
--
-- Run through reascript_test.py (REAPER's embedded Lua stands in for the
-- missing system interpreter), or from the Actions list.
--
-- Three layers, each checked against something independent of this code:
--
--   * the compound-file reader, against stream sizes and checksums taken from
--     olefile (a separate CFB implementation) on the same fixture;
--   * the AAF model, against the values a Python decode of the fixture's raw
--     properties gave -- a real Pro Tools 25.6 export;
--   * the walker paths no real export covers yet (pan, constant values,
--     constant interpolation, nesting, transitions, clips with gaps), against
--     hand-built objects with known answers.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local test_dir = src:match("^(.*[/\\])")
local script_dir = test_dir:gsub("test[/\\]$", "")
package.path = script_dir .. "?.lua;" .. test_dir .. "?.lua;" .. package.path
for k in pairs(package.loaded) do if k:match("^ai%.") then package.loaded[k] = nil end end

local saved_reaper = reaper
reaper = nil                      -- prove the pure stages need none of it
local CFB    = require "ai.cfb"
local AAF    = require "ai.aaf"
local Model  = require "ai.model"
local Config = require "ai.config"
local Apply  = require "ai.apply"
reaper = saved_reaper

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function report()
  say(string.format("headless: %d passed, %d failed", pass, fail))
  local text = table.concat(out, "\n") .. "\n"
  if reaper and reaper.ShowConsoleMsg then reaper.ShowConsoleMsg(text) else print(text) end
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end
local function ok(cond, name, extra)
  if cond then pass = pass + 1 say("  ok    " .. name)
  else fail = fail + 1 say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or "")) end
end
local function near(a, b, tol, name)
  ok(type(a) == "number" and math.abs(a - b) <= tol, name,
     string.format("%.12g vs %.12g (tol %.3g)", tonumber(a) or 0 / 0, b, tol))
end
local function db(g) return Model.db(g) end

local FIX = test_dir .. "fixtures/"

---------------------------------------------------------------- compound file
say("compound file reader")
do
  local fh = assert(io.open(FIX .. "automation_import.aaf", "rb"))
  local data = fh:read("a")
  fh:close()
  local f, err = CFB.open(data)
  ok(f ~= nil, "opens the fixture", err)
  if f then
    -- olefile lists 2405 entries below the root.
    ok(f.count == 2406, "directory holds 2405 entries plus the root", tostring(f.count))
    ok(f.ss == 512, "512-byte sectors")

    local function sums(s)
      local a, b = 0, 0
      for i = 1, #s do
        local c = s:byte(i)
        a = (a + c) % 2^32
        b = (b + (i - 1) * c) % 2^32
      end
      return math.floor(a), math.floor(b)
    end
    -- Two below the 4096 cutoff (mini stream) and one above it (FAT chain).
    local want = {
      { "Header-2/Content-3b03/Mobs-1901 index", 415, 20892, 4618486 },
      { "Header-2/Content-3b03/Mobs-1901{9}/properties", 258, 11315, 1547603 },
      { "Header-2/Content-3b03/Mobs-1901{1}/EssenceDescription-4701/properties", 4193, 7451, 17383083 },
    }
    for _, w in ipairs(want) do
      local s = f.read(f.find(w[1]))
      local a, b = sums(s or "")
      ok(s and #s == w[2] and a == w[3] and b == w[4],
         string.format("%s: %d bytes, same checksum as olefile", w[1]:match("[^/]+/[^/]+$"), w[2]),
         string.format("%s bytes, sums %d %d", s and #s or "nil", a, b))
    end
    ok(f.find("Header-2").clsid == "0d010101-0101-2f00-060e-2b3402060101",
       "storage CLSIDs are read (Header)")
    ok(AAF.class_name(f.find("Header-2").clsid) == "Header", "and mapped to AAF class names")
  end

  local bad = CFB.open(string.rep("x", 1024))
  ok(bad == nil, "a non-AAF file is refused, not misread")
  ok(CFB.utf16("A\0\xE5\0B\0\0\0Z\0") == "A\xC3\xA5B", "UTF-16 names decode to UTF-8 and stop at NUL")
end

------------------------------------------------------------- the real export
say("model: Pro Tools 25.6 export with volume automation")
local full, ferr = Model.load(FIX .. "automation_import.aaf")
ok(full ~= nil, "loads", ferr)
if full then
  local T = full.tracks
  ok(#T == 4, "four audio tracks, the timecode track excluded", tostring(#T))
  local names = {}
  for i, t in ipairs(T) do names[i] = t.name end
  ok(table.concat(names, "|") == "Volume automation|Volume automation|Mono Audio 1|Mono Audio 2",
     "track names in slot order", table.concat(names, "|"))
  ok(full.tc and full.tc.label == "00:59:50:00" and full.tc.fps == 24,
     "start timecode 00:59:50:00 at 24 fps", full.tc and full.tc.label)
  near(full.tc and full.tc.seconds, 3590, 1e-9, "timecode in seconds")
  ok(full.tool and full.tool.product == "ProTools" and full.tool.version == "25.6.0.282",
     "identifies the writer")
  ok(T[1].rate_num == 48000 and T[1].rate_den == 1, "edit rate 48000/1")
  ok(#full.warnings == 0, "no warnings", table.concat(full.warnings, "; "))

  local V1 = T[1].volume
  ok(V1 and V1.raw == 234, "track 1: 234 control points read", V1 and tostring(V1.raw))
  ok(V1 and #V1.points == 233, "two identical end points collapse to one", V1 and tostring(#V1.points))
  if V1 then
    near(db(V1.points[1].v), -1.0, 0.005, "track 1 opens at -1.0 dB")
    near(V1.points[1].t, 0, 1e-9, "at 0 s")
    near(V1.t1, 12779473 / 48000, 1e-6, "and its last point is at the group's end, 266.239 s")
    near(db(V1.min), -1.3, 0.05, "lowest -1.3 dB")
    near(db(V1.max), 7.3, 0.05, "highest +7.3 dB")
    ok(not V1.static, "is automation, not static")
    ok(V1.points[1].shape == Model.SHAPE_LINEAR, "linear interpolation -> REAPER linear shape")
    -- Pro Tools' step pairs (12227 and 12228 samples) survive as two points.
    near(V1.points[2].t, 12227 / 48000, 1e-9, "a step's first sample")
    near(V1.points[3].t, 12228 / 48000, 1e-9, "and its second, one sample later")
  end

  local V3 = T[3].volume
  ok(V3 and V3.raw == 6 and #V3.points == 5, "track 3: 6 points read, 5 kept",
     V3 and string.format("%d / %d", V3.raw, #V3.points))
  if V3 then
    local L = 11337999 / 48000        -- the gain group covers the clip only
    near(V3.points[2].t, 6461153 / 11337999 * L, 1e-6, "time = fraction of the group's length")
    near(db(V3.points[2].v), -10.6, 0.005, "-10.6 dB at 134.6 s")
    near(db(V3.points[3].v), -23.2, 0.005, "-23.2 dB at 224.3 s")
    near(V3.points[3].t, 224.3425, 1e-3, "at 224.34 s")
    -- The end is a step: -18.8 dB one sample before the clip's end, then
    -- -15.3 dB twice AT the end (Pro Tools' value past the clip, clamped to
    -- it), of which one is a repeat and goes.
    near(V3.points[4].t, (11337999 - 1) / 48000, 1e-9, "-18.8 dB one sample before the clip's end")
    near(db(V3.points[4].v), -18.8, 0.005, "holds -18.8 dB")
    near(V3.points[5].t, L, 1e-9, "the last point is exactly at the clip's end")
    near(db(V3.points[5].v), -15.3, 0.005, "and holds -15.3 dB")
    ok(V3.t1 < T[3].length_s - 20, "no automation past the clip: the Filler carries none")
  end
  local V4 = T[4].volume
  near(V4 and db(V4.points[#V4.points].v), -5.6, 0.005, "track 4 ends at -5.6 dB")
  ok(T[1].pan == nil and T[3].pan == nil, "no pan in this export")
end

say("model: an export with names only")
local names_only, nerr = Model.load(FIX .. "names_only.aaf")
ok(names_only ~= nil, "loads", nerr)
if names_only then
  ok(#names_only.tracks == 4, "four tracks")
  ok(names_only.tracks[3].name == "Static pan and volume", "names come through")
  local any = false
  for _, t in ipairs(names_only.tracks) do any = any or t.volume ~= nil or t.pan ~= nil end
  ok(not any, "and no lanes, without an error")
end

local missing = Model.load(FIX .. "does_not_exist.aaf")
ok(missing == nil, "a missing file is an error, not an empty list")

---------------------------------------------------------- synthetic objects
say("walker: cases no real export covers yet")

local Mock = {}
Mock.__index = Mock
local function get(self, pid) return self.p[pid] end
Mock.i64, Mock.string, Mock.u32, Mock.u16, Mock.u8 = get, get, get, get, get
Mock.weak, Mock.auid, Mock.ref = get, get, get
function Mock:indirect(pid) return self.p[pid] end
function Mock:rational(pid) local r = self.p[pid] if r then return r[1], r[2] end end
function Mock:refs(pid) return self.p[pid] or {} end
local function O(class, p) return setmetatable({ class = class, p = p or {} }, Mock) end

local P = Model.P
local SOUND = "78e1ebe1-6cef-11d2-807d-006008143e6f"
local function clip(len) return O("SourceClip", { [P.LENGTH] = len }) end
local function filler(len) return O("Filler", { [P.LENGTH] = len }) end
local function varying(paramdef, pts, interp)
  local cps = {}
  for _, q in ipairs(pts) do
    cps[#cps + 1] = O("ControlPoint", { [P.CP_TIME] = { q[1], q[2] }, [P.CP_VALUE] = q[3] })
  end
  return O("VaryingValue", { [P.PARAMDEF] = paramdef, [P.POINTS] = cps,
                             [P.INTERP] = interp or Model.INTERP_LINEAR })
end
local function constant(paramdef, v)
  return O("ConstantValue", { [P.PARAMDEF] = paramdef, [P.CONST_VALUE] = v })
end
local function group(op, len, params, input)
  return O("OperationGroup", { [P.LENGTH] = len, [P.OPDEF] = op, [P.PARAMS] = params,
                               [P.INPUTS] = { input } })
end
local function seq(len, comps)
  return O("Sequence", { [P.LENGTH] = len, [P.COMPONENTS] = comps, [P.DATADEF] = SOUND })
end
local function slot(seg, name)
  return O("TimelineMobSlot", { [P.SLOT_SEGMENT] = seg, [P.SLOT_NAME] = name or "T",
                                [P.EDIT_RATE] = { 48000, 1 }, [P.ORIGIN] = 0 })
end
local function run(seg)
  local ctx = { warnings = {}, warned = {} }
  return Model.track_from_slot(slot(seg), ctx), ctx.warnings
end
local AMP, PANP = Model.PARAM_AMPLITUDE, Model.PARAM_PAN

do -- two clips with a gap: points at their own offsets, nothing in the gap
  local s = seq(120000, {
    group(Model.OP_GAIN, 48000, { varying(AMP, { { 0, 1, 0.5 }, { 1, 1, 1.0 } }) }, clip(48000)),
    filler(24000),
    group(Model.OP_GAIN, 48000, { varying(AMP, { { 0, 2, 0.25 }, { 1, 2, 0.25 }, { 2, 2, 1.0 } }) }, clip(48000)),
  })
  local tr = run(s)
  local t = {}
  for i, q in ipairs(tr.volume.points) do t[i] = string.format("%.3f", q.t) end
  ok(table.concat(t, " ") == "0.000 1.000 1.500 2.000 2.500",
     "two gain groups across a Filler land at their own offsets", table.concat(t, " "))
  near(db(tr.volume.points[3].v), db(0.25), 1e-9, "second group's values are its own")
  near(tr.length_s, 2.5, 1e-9, "sequence length in seconds")
end

do -- pan as a ConstantValue: static, 0..1 mapped to REAPER -1..1
  local tr = run(seq(48000, { group(Model.OP_PAN, 48000, { constant(PANP, 0.25) }, clip(48000)) }))
  ok(tr.pan and tr.pan.static, "a ConstantValue pan is static")
  near(tr.pan and tr.pan.static, -0.5, 1e-12, "AAF 0.25 is REAPER 50% left (-0.5)")
  ok(tr.volume == nil, "and there is no volume lane")
end

do -- constant interpolation -> square shape
  local tr = run(seq(48000, { group(Model.OP_GAIN, 48000,
    { varying(AMP, { { 0, 1, 0.5 }, { 1, 2, 1.0 } }, Model.INTERP_CONSTANT) }, clip(48000)) }))
  ok(tr.volume.points[1].shape == Model.SHAPE_SQUARE, "constant interpolation -> square shape")
end

do -- gain over pan, nested: both lanes, both from the same start
  local inner = group(Model.OP_PAN, 48000, { varying(PANP, { { 0, 1, 0 }, { 1, 1, 1 } }) }, clip(48000))
  local outer = group(Model.OP_GAIN, 48000, { varying(AMP, { { 0, 1, 1 }, { 1, 1, 0.5 } }) }, inner)
  local tr = run(seq(72000, { filler(24000), outer }))
  ok(tr.volume and tr.pan, "nested gain over pan yields both lanes")
  near(tr.pan.points[1].t, 0.5, 1e-9, "the inner group starts where the outer one does")
  near(tr.pan.points[1].v, -1, 1e-12, "AAF pan 0 = hard left")
  near(tr.pan.points[2].v, 1, 1e-12, "AAF pan 1 = hard right")
end

do -- a transition overlaps: the next segment starts at the transition's start
  local s = seq(84000, {
    clip(48000),
    O("Transition", { [P.LENGTH] = 12000 }),
    group(Model.OP_GAIN, 48000, { varying(AMP, { { 0, 1, 0.5 }, { 1, 1, 0.5 } }) }, clip(48000)),
  })
  local tr = run(s)
  near(tr.volume.points[1].t, 36000 / 48000, 1e-9, "a Transition pulls the next segment back by its length")
end

do -- an effect we do not import is reported, not silently dropped
  local tr, warns = run(seq(48000, { group("12345678-0000-0000-0000-000000000000", 48000, {}, clip(48000)) }))
  ok(tr.volume == nil and #warns == 1, "an unknown effect is reported", table.concat(warns, "; "))
end

do -- a non-audio slot is not a track
  local s = seq(48000, { clip(48000) })
  s.p[P.DATADEF] = "05e7a84d-6cef-11d2-807d-006008143e6f"   -- legacy picture
  local tr = run(s)
  ok(tr == nil, "a picture slot is not listed")
end

say("clean-up and static detection")
do
  local pts = {
    { t = 0, v = 1, seq = 1 }, { t = 1, v = 0.5, seq = 2 }, { t = 1, v = 0.6, seq = 3 },
    { t = 1, v = 0.7, seq = 4 }, { t = 2, v = 0.7, seq = 5 }, { t = 2, v = 0.7, seq = 6 },
  }
  local c = Model.clean(pts)
  local s = {}
  for i, q in ipairs(c) do s[i] = string.format("%g@%g", q.v, q.t) end
  ok(table.concat(s, " ") == "1@0 0.5@1 0.7@1 0.7@2",
     "a stack keeps first and last; exact repeats go", table.concat(s, " "))

  local flat = run(seq(48000, { group(Model.OP_GAIN, 48000,
    { varying(AMP, { { 0, 4, 0.5 }, { 1, 4, 0.5 }, { 3, 4, 0.5 }, { 4, 4, 0.5 } }) }, clip(48000)) }))
  ok(flat.volume.static ~= nil, "a lane that never moves is static")
  local g = 0.5 * 10 ^ (0.02 / 20)
  local moving = run(seq(48000, { group(Model.OP_GAIN, 48000,
    { varying(AMP, { { 0, 4, 0.5 }, { 1, 4, 0.5 }, { 3, 4, g }, { 4, 4, 0.5 } }) }, clip(48000)) }))
  ok(moving.volume.static == nil, "one point 0.02 dB off makes it automation")
end

say("import plan")
do
  local cfg = Config.new()
  local static_tr = { name = "Vox", volume = { static = 0.5, first = 0.5, points = { { t = 0, v = 0.5 } } } }
  local p = Apply.plan(static_tr, cfg)
  ok(p.name == "Vox" and p.vol == 0.5 and p.vol_pts == nil,
     "static volume goes to the fader, no envelope")

  local pts = { { t = 0, v = 0.5, shape = 0 }, { t = 1, v = 1, shape = 0 } }
  local auto_tr = { name = "Vox", volume = { first = 0.5, points = pts },
                    pan = { first = -0.2, points = { { t = 0, v = -0.2 }, { t = 1, v = 0.3 } } } }
  p = Apply.plan(auto_tr, cfg)
  ok(p.vol_pts == pts and p.vol == 1.0, "automation + volume: envelope, fader at 0 dB")
  ok(p.pan_pts and p.pan == 0, "automation + pan: envelope, pan centred")

  cfg.imp_automation = false
  p = Apply.plan(auto_tr, cfg)
  ok(p.vol_pts == nil and p.vol == 0.5, "volume only: the automation's opening value")
  ok(p.pan_pts == nil and p.pan == -0.2, "pan only: likewise")

  cfg.imp_automation, cfg.imp_volume, cfg.imp_pan, cfg.imp_name = true, false, false, false
  p = Apply.plan(auto_tr, cfg)
  ok(p.vol_pts and p.vol == nil and p.pan == nil and p.name == nil,
     "automation only: envelopes, fader and name untouched")

  cfg.imp_automation = false
  p = Apply.plan(auto_tr, cfg)
  ok(p.empty, "nothing ticked: an empty plan")
end

say("config")
do
  local c = Config.new()
  ok(c.placement == "zero", "default placement: AAF start at project start")
  ok(Config.placement_index(c) == 1, "placement index")
  for _, k in ipairs(Config.PLACEMENTS) do
    ok(Config.PLACEMENT_LABELS[k] ~= nil, "placement " .. k .. " has a label")
  end
  -- Every checkbox in the panel must name a real setting.
  local fh = io.open(script_dir .. "ai/ui.lua", "r")
  local ui = fh and fh:read("a") or ""
  if fh then fh:close() end
  local n = 0
  for key in ui:gmatch('checkbox%("[^"]*",%s*"([%w_]+)"%)') do
    n = n + 1
    ok(Config.defaults[key] ~= nil, "panel checkbox key '" .. key .. "' is a setting")
  end
  ok(n == 4, "the panel has the four import checkboxes", tostring(n))
end

report()
