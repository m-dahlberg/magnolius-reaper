-- @noindex
-- AAF Importer -- from AAF objects to a list of tracks with volume and pan.
--
-- Pure Lua, no reaper: the walker only calls the object methods ai/aaf.lua
-- provides (class, string, i64, rational, weak, auid, indirect, ref, refs),
-- so the headless suite can hand it synthetic objects for the cases no real
-- export covers.
--
-- What Pro Tools writes, decoded from a real export (test/fixtures):
--
--   CompositionMob
--     TimelineMobSlot  "Track name", edit rate 48000/1
--       Sequence
--         OperationGroup  MonoAudioGain, length L
--           Parameter Amplitude = VaryingValue, Linear
--             ControlPoint  Time = fraction of L (a Rational), Value = gain
--           InputSegments[1] = SourceClip
--         Filler
--
-- The fact the timeline rests on: a ControlPoint's time is a FRACTION of its
-- OperationGroup's length, not an edit-unit position. So each point lands at
-- group_start + time * group_length, and automation exists only under the
-- groups -- under clips. A Filler carries none.

local AAF = require "ai.aaf"

local M = {}

-- Definitions, as AUIDs.
M.OP_GAIN         = "9d2ea894-0968-11d3-8a38-0050040ef7d2"  -- MonoAudioGain
M.OP_PAN          = "9d2ea893-0968-11d3-8a38-0050040ef7d2"  -- MonoAudioPan
M.PARAM_AMPLITUDE = "e4962321-2267-11d3-8a4c-0050040ef7d2"
M.PARAM_PAN       = "e4962322-2267-11d3-8a4c-0050040ef7d2"
M.INTERP_NONE     = "5b6c85a3-0ede-11d3-80a9-006008143e6f"
M.INTERP_LINEAR   = "5b6c85a4-0ede-11d3-80a9-006008143e6f"
M.INTERP_CONSTANT = "5b6c85a5-0ede-11d3-80a9-006008143e6f"

-- Data definitions: the legacy AUIDs (what Pro Tools writes) and the SMPTE
-- ones (what newer writers use).
local SOUND = {
  ["78e1ebe1-6cef-11d2-807d-006008143e6f"] = true,
  ["01030202-0200-0000-060e-2b3404010101"] = true,
}
local TIMECODE = {
  ["7f275e81-77e5-11d2-807f-006008143e6f"] = true,
  ["01030201-0100-0000-060e-2b3404010101"] = true,
}

-- REAPER envelope shapes.
M.SHAPE_LINEAR, M.SHAPE_SQUARE = 0, 1

-- Pids used below.
local P = {
  LENGTH = 0x0202, DATADEF = 0x0201,
  COMPONENTS = 0x1001,
  OPDEF = 0x0B01, INPUTS = 0x0B02, PARAMS = 0x0B03,
  PARAMDEF = 0x4C01, CONST_VALUE = 0x4D01,
  INTERP = 0x4E01, POINTS = 0x4E02,
  CP_VALUE = 0x1A02, CP_TIME = 0x1A03,
  TC_START = 0x1501, TC_FPS = 0x1502, TC_DROP = 0x1503,
  MOB_NAME = 0x4402, SLOTS = 0x4403,
  SLOT_ID = 0x4801, SLOT_NAME = 0x4802, SLOT_SEGMENT = 0x4803, TRACK_NO = 0x4804,
  EDIT_RATE = 0x4B01, ORIGIN = 0x4B02,
  CONTENT = 0x3B03, IDENT = 0x3B06, MOBS = 0x1901,
  COMPANY = 0x3C01, PRODUCT = 0x3C02, VERSION = 0x3C04,
}
M.P = P

local function len_of(o) return o:i64(P.LENGTH) or 0 end

local function warn(ctx, msg)
  if not ctx.warned[msg] then
    ctx.warned[msg] = true
    ctx.warnings[#ctx.warnings + 1] = msg
  end
end

-- One parameter's points, appended to ctx.lane[kind] in edit units.
local function collect(prm, kind, pos, len, ctx)
  local lane = ctx.lane[kind]
  local conv = kind == "pan" and function(v) return 2 * v - 1 end
                              or function(v) return v end
  if prm.class == "VaryingValue" then
    local interp = prm:weak(P.INTERP)
    local shape = (interp == M.INTERP_CONSTANT or interp == M.INTERP_NONE)
                  and M.SHAPE_SQUARE or M.SHAPE_LINEAR
    for _, cp in ipairs(prm:refs(P.POINTS)) do
      local v, why = cp:indirect(P.CP_VALUE)
      local tn, td = cp:rational(P.CP_TIME)
      if v and tn and td and td ~= 0 then
        lane.raw = lane.raw + 1
        lane.pts[#lane.pts + 1] = { eu = pos + (tn / td) * len, v = conv(v),
                                    shape = shape, seq = #lane.pts }
      else
        warn(ctx, "skipped a control point whose value could not be read ("
                  .. tostring(why or "no time") .. ")")
      end
    end
  elseif prm.class == "ConstantValue" then
    local v, why = prm:indirect(P.CONST_VALUE)
    if v then
      lane.raw = lane.raw + 1
      lane.pts[#lane.pts + 1] = { eu = pos, v = conv(v), shape = M.SHAPE_LINEAR, seq = #lane.pts }
      lane.pts[#lane.pts + 1] = { eu = pos + len, v = conv(v), shape = M.SHAPE_LINEAR, seq = #lane.pts }
    else
      warn(ctx, "skipped a constant value that could not be read (" .. tostring(why) .. ")")
    end
  end
end

-- Walks one segment starting at `pos` (edit units).
local function walk(seg, pos, ctx, depth)
  if not seg or depth > 64 then return end
  local cls = seg.class
  if cls == "Sequence" then
    local p = pos
    for _, c in ipairs(seg:refs(P.COMPONENTS)) do
      if c.class == "Transition" then
        -- A transition overlaps its neighbours: the next segment starts at
        -- the transition's start, not after it.
        p = p - len_of(c)
      else
        walk(c, p, ctx, depth + 1)
        p = p + len_of(c)
      end
    end
  elseif cls == "OperationGroup" then
    local len = len_of(seg)
    local op = seg:weak(P.OPDEF)
    local kind = (op == M.OP_GAIN and "volume") or (op == M.OP_PAN and "pan") or nil
    if kind then
      local want = kind == "volume" and M.PARAM_AMPLITUDE or M.PARAM_PAN
      local params = seg:refs(P.PARAMS)
      local used = false
      for _, prm in ipairs(params) do
        if prm:auid(P.PARAMDEF) == want then
          collect(prm, kind, pos, len, ctx)
          used = true
        end
      end
      if not used and #params == 1 then
        collect(params[1], kind, pos, len, ctx)
      end
    elseif op then
      warn(ctx, "ignored an effect this script does not import (" .. op .. ")")
    end
    -- A gain group wraps what it applies to; nested groups (gain over pan)
    -- start where this one starts.
    local inputs = seg:refs(P.INPUTS)
    if inputs[1] then walk(inputs[1], pos, ctx, depth + 1) end
  end
  -- SourceClip, Filler and anything else: nothing to collect.
end

-- Points sharing one time: the first and last carry the step; anything in
-- between would only be a zero-length zig-zag in REAPER. Pro Tools also
-- repeats a group's last point exactly (same time, same value), and two
-- adjacent groups meet at one time -- both handled here.
function M.clean(pts)
  table.sort(pts, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a.seq < b.seq
  end)
  local out = {}
  local i = 1
  while i <= #pts do
    local j = i
    while j < #pts and math.abs(pts[j + 1].t - pts[i].t) < 1e-9 do j = j + 1 end
    out[#out + 1] = pts[i]
    if j > i then out[#out + 1] = pts[j] end
    i = j + 1
  end
  -- Exact repeats (same time, same value) say nothing.
  local res = {}
  for _, p in ipairs(out) do
    local q = res[#res]
    if not (q and math.abs(q.t - p.t) < 1e-9 and q.v == p.v) then res[#res + 1] = p end
  end
  return res
end

function M.db(g)
  if not g or g <= 0 then return -math.huge end
  return 20 * math.log(g, 10)
end

-- A lane is static when every point is within `tol` of the first: 0.01 dB
-- for volume, 0.001 (0.1 %) for pan.
local function is_static(pts, kind)
  if #pts == 0 then return false end
  local v0 = pts[1].v
  for _, p in ipairs(pts) do
    if kind == "volume" then
      if math.abs(M.db(p.v) - M.db(v0)) > 0.01 then return false end
    elseif math.abs(p.v - v0) > 0.001 then
      return false
    end
  end
  return true
end

local function finish_lane(lane, kind, rnum, rden, origin)
  if #lane.pts == 0 then return nil end
  for _, p in ipairs(lane.pts) do p.t = (p.eu - origin) * rden / rnum end
  local pts = M.clean(lane.pts)
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pts) do
    p.eu, p.seq = nil, nil
    if p.v < lo then lo = p.v end
    if p.v > hi then hi = p.v end
  end
  return {
    points = pts,
    raw = lane.raw,
    first = pts[1].v,
    static = is_static(pts, kind) and pts[1].v or nil,
    t0 = pts[1].t, t1 = pts[#pts].t,
    min = lo, max = hi,
  }
end

-- One timeline slot to a track, or nil when the slot is not audio.
function M.track_from_slot(slot, ctx)
  local seg = slot:ref(P.SLOT_SEGMENT)
  if not seg or not SOUND[seg:weak(P.DATADEF) or ""] then return nil end
  local rnum, rden = slot:rational(P.EDIT_RATE)
  if not rnum or rnum <= 0 or not rden or rden <= 0 then
    warn(ctx, "a slot without a usable edit rate was skipped")
    return nil
  end
  ctx.lane = { volume = { pts = {}, raw = 0 }, pan = { pts = {}, raw = 0 } }
  walk(seg, 0, ctx, 0)
  local origin = slot:i64(P.ORIGIN) or 0
  return {
    name = slot:string(P.SLOT_NAME) or "",
    slot_id = slot:u32(P.SLOT_ID),
    track_no = slot:u32(P.TRACK_NO),
    rate_num = rnum, rate_den = rden,
    length_s = len_of(seg) * rden / rnum,
    volume = finish_lane(ctx.lane.volume, "volume", rnum, rden, origin),
    pan = finish_lane(ctx.lane.pan, "pan", rnum, rden, origin),
  }
end

-- The composition's start timecode: a Timecode segment, directly in its slot
-- or first in a Sequence there.
local function timecode_of(slot)
  local seg = slot:ref(P.SLOT_SEGMENT)
  if not seg or not TIMECODE[seg:weak(P.DATADEF) or ""] then return nil end
  if seg.class == "Sequence" then
    for _, c in ipairs(seg:refs(P.COMPONENTS)) do
      if c.class == "Timecode" then seg = c break end
    end
  end
  if seg.class ~= "Timecode" then return nil end
  local start, fps = seg:i64(P.TC_START), seg:u16(P.TC_FPS)
  if not start or not fps or fps == 0 then return nil end
  local drop = (seg:u8(P.TC_DROP) or 0) ~= 0
  local ff = start % fps
  local s = start // fps
  return {
    frames = start, fps = fps, drop = drop,
    -- Nominal seconds: the timecode's own reading of itself, which is what a
    -- REAPER project start set to the same timecode means.
    seconds = start / fps,
    label = string.format("%02d:%02d:%02d%s%02d", s // 3600, (s // 60) % 60, s % 60,
                          drop and ";" or ":", ff),
  }
end

-- Everything the panel needs from a file object.
function M.read(file)
  local ctx = { warnings = {}, warned = {} }
  local hdr = file:header()
  if not hdr then return nil, "no AAF header -- is this really an AAF?" end
  local content = hdr:ref(P.CONTENT)
  if not content then return nil, "the AAF has no content storage" end

  local res = { tracks = {}, warnings = ctx.warnings, comps = 0 }
  local ids = hdr:refs(P.IDENT)
  local last = ids[#ids]
  if last then
    res.tool = {
      company = last:string(P.COMPANY),
      product = last:string(P.PRODUCT),
      version = last:string(P.VERSION),
    }
  end

  for _, mob in ipairs(content:refs(P.MOBS)) do
    if mob.class == "CompositionMob" then
      res.comps = res.comps + 1
      local mob_name = mob:string(P.MOB_NAME) or ""
      for _, slot in ipairs(mob:refs(P.SLOTS)) do
        if slot.class == "TimelineMobSlot" then
          local tc = timecode_of(slot)
          if tc then
            res.tc = res.tc or tc
          else
            local tr = M.track_from_slot(slot, ctx)
            if tr then
              tr.mob = mob_name
              tr.index = #res.tracks + 1
              res.tracks[#res.tracks + 1] = tr
            end
          end
        end
      end
      res.name = res.name or mob_name
    end
  end
  if res.comps == 0 then
    return nil, "the AAF holds no composition (no CompositionMob) -- nothing to import"
  end
  return res
end

function M.load(path)
  local file, err = AAF.open_file(path)
  if not file then return nil, err end
  local ok, res, err2 = pcall(M.read, file)
  if not ok then return nil, "could not read the AAF: " .. tostring(res) end
  if not res then return nil, err2 end
  res.path = path
  return res
end

-- Display helpers ----------------------------------------------------------

function M.fmt_db(g)
  local d = M.db(g)
  if d == -math.huge then return "-inf dB" end
  return string.format("%+.1f dB", d)
end

-- REAPER D_PAN units, -1 = left.
function M.fmt_pan(p)
  if math.abs(p) < 0.005 then return "C" end
  return string.format("%.0f%%%s", math.abs(p) * 100, p < 0 and "L" or "R")
end

function M.describe(lane, kind)
  if not lane then return "--" end
  local f = kind == "pan" and M.fmt_pan or M.fmt_db
  if lane.static then return "static " .. f(lane.static) end
  return string.format("auto, %d pts, %s .. %s", #lane.points, f(lane.min), f(lane.max))
end

return M
