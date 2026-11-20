-- @noindex
-- AAF Importer -- the AAF object layer over the compound file.
--
-- Every AAF object is a storage holding a `properties` stream:
--
--   byte  'L' (little-endian; 'B' would be big-endian and is refused)
--   byte  format version
--   u16   property count
--   count x (u16 pid, u16 stored form, u16 length), then the values in order
--
-- Its class is the storage's CLSID. A property's stored form says what its
-- value is: plain data, or the NAME of a child storage holding the referenced
-- object(s). Vectors and sets name a "<name> index" stream listing local keys
-- and children called "<name>{hexkey}". A weak reference is a tag plus the
-- referenced definition's key, which for every definition we care about is
-- its 16-byte AUID -- so weak references are resolved to that AUID string and
-- never chased.
--
-- Pure Lua, no reaper. Objects are loaded lazily and cached per storage.

local CFB = require "ai.cfb"

local M = {}

-- Stored forms (OMStoredForm).
M.SF_DATA          = 0x82
M.SF_STRONG        = 0x22
M.SF_STRONG_VECTOR = 0x32
M.SF_STRONG_SET    = 0x3A
M.SF_WEAK          = 0x02
M.SF_WEAK_VECTOR   = 0x12
M.SF_WEAK_SET      = 0x1A

-- Classes are 0d010101-0101-XX00-060e-2b3402060101; XX names the class.
local CLASS_BY_CODE = {
  [0x01] = "InterchangeObject", [0x02] = "Component", [0x03] = "Segment",
  [0x04] = "EdgeCode", [0x05] = "EssenceGroup", [0x06] = "Event",
  [0x07] = "GPITrigger", [0x08] = "CommentMarker", [0x09] = "Filler",
  [0x0A] = "OperationGroup", [0x0B] = "NestedScope", [0x0C] = "Pulldown",
  [0x0D] = "ScopeReference", [0x0E] = "Selector", [0x0F] = "Sequence",
  [0x10] = "SourceReference", [0x11] = "SourceClip", [0x12] = "TextClip",
  [0x13] = "HTMLClip", [0x14] = "Timecode", [0x15] = "TimecodeStream",
  [0x16] = "TimecodeStream12M", [0x17] = "Transition",
  [0x18] = "ContentStorage", [0x19] = "ControlPoint",
  [0x2F] = "Header", [0x30] = "Identification",
  [0x34] = "Mob", [0x35] = "CompositionMob", [0x36] = "MasterMob",
  [0x37] = "SourceMob", [0x38] = "MobSlot", [0x39] = "EventMobSlot",
  [0x3A] = "StaticMobSlot", [0x3B] = "TimelineMobSlot",
  [0x3C] = "Parameter", [0x3D] = "ConstantValue", [0x3E] = "VaryingValue",
  [0x3F] = "TaggedValue",
}

function M.class_name(clsid)
  if not clsid then return "?" end
  local code = clsid:match("^0d010101%-0101%-(%x%x)00%-060e%-2b3402060101$")
  if code then return CLASS_BY_CODE[tonumber(code, 16)] or ("class " .. code) end
  return clsid
end

-- Type AUIDs of the indirect values we decode (the SMPTE type ULs in AUID
-- byte order).
local TYPE_RATIONAL = "03010100-0000-0000-060e-2b3401040101"
local TYPE_INT8     = "01010500-0000-0000-060e-2b3401040101"
local TYPE_INT16    = "01010600-0000-0000-060e-2b3401040101"
local TYPE_INT32    = "01010700-0000-0000-060e-2b3401040101"
local TYPE_INT64    = "01010800-0000-0000-060e-2b3401040101"
local TYPE_UINT8    = "01010100-0000-0000-060e-2b3401040101"
local TYPE_UINT16   = "01010200-0000-0000-060e-2b3401040101"
local TYPE_UINT32   = "01010300-0000-0000-060e-2b3401040101"

-- Decodes an indirect value: byte order, the type's AUID, then the value.
-- Returns a number (rationals divided out), or nil + the type when the type is
-- not a numeric one we know.
function M.indirect(s)
  if not s or #s < 17 then return nil, "short indirect value" end
  if s:byte(1) ~= 0x4C then return nil, "big-endian indirect value" end
  local t = CFB.guid(s, 1)
  local v = s:sub(18)
  if t == TYPE_RATIONAL and #v >= 8 then
    local n, d = string.unpack("<i4i4", v)
    if d == 0 then return nil, "rational with zero denominator" end
    return n / d
  elseif t == TYPE_INT32 and #v >= 4 then return (string.unpack("<i4", v))
  elseif t == TYPE_UINT32 and #v >= 4 then return (string.unpack("<I4", v))
  elseif t == TYPE_INT16 and #v >= 2 then return (string.unpack("<i2", v))
  elseif t == TYPE_UINT16 and #v >= 2 then return (string.unpack("<I2", v))
  elseif t == TYPE_INT8 and #v >= 1 then return (string.unpack("<i1", v))
  elseif t == TYPE_UINT8 and #v >= 1 then return (string.unpack("<I1", v))
  elseif t == TYPE_INT64 and #v >= 8 then return (string.unpack("<i8", v))
  end
  return nil, t
end

local Obj = {}
Obj.__index = Obj

-- Raw value of a data property, or nil.
function Obj:raw(pid)
  local p = self.props[pid]
  return p and p.value
end

function Obj:string(pid)
  local v = self:raw(pid)
  return v and CFB.utf16(v) or nil
end

function Obj:u32(pid)
  local v = self:raw(pid)
  return (v and #v >= 4) and (string.unpack("<I4", v)) or nil
end

function Obj:u16(pid)
  local v = self:raw(pid)
  return (v and #v >= 2) and (string.unpack("<I2", v)) or nil
end

function Obj:u8(pid)
  local v = self:raw(pid)
  return (v and #v >= 1) and v:byte(1) or nil
end

function Obj:i64(pid)
  local v = self:raw(pid)
  return (v and #v >= 8) and (string.unpack("<i8", v)) or nil
end

-- num, den -- kept separate: an edit rate of 30000/1001 must not be rounded.
function Obj:rational(pid)
  local v = self:raw(pid)
  if not v or #v < 8 then return nil end
  return string.unpack("<i4i4", v)
end

function Obj:auid(pid)
  local v = self:raw(pid)
  return v and CFB.guid(v) or nil
end

function Obj:indirect(pid)
  return M.indirect(self:raw(pid))
end

-- The AUID a weak reference points at: tag u16, key pid u16, key size u8, key.
function Obj:weak(pid)
  local p = self.props[pid]
  if not p or p.form ~= M.SF_WEAK then return nil end
  local v = p.value
  if #v < 5 then return nil end
  local ksize = v:byte(5)
  if ksize ~= 16 or #v < 5 + 16 then return nil end
  return CFB.guid(v, 5)
end

-- A single strong reference: the object, or nil.
function Obj:ref(pid)
  local p = self.props[pid]
  if not p or p.form ~= M.SF_STRONG then return nil end
  return self.file:object(self.node:child(CFB.utf16(p.value)))
end

-- A strong reference vector or set: a list of objects, in vector order (the
-- index stream's order, which for a set is arbitrary but stable).
function Obj:refs(pid)
  local p = self.props[pid]
  if not p or (p.form ~= M.SF_STRONG_VECTOR and p.form ~= M.SF_STRONG_SET) then
    return {}
  end
  local name = CFB.utf16(p.value)
  local idx = self.file.cfb.read(self.node:child(name .. " index"))
  if not idx or #idx < 12 then return {} end
  local count = string.unpack("<I4", idx, 1)
  local keys = {}
  if p.form == M.SF_STRONG_VECTOR then
    for i = 0, count - 1 do
      local off = 12 + 4 * i
      if off + 4 > #idx then break end
      keys[#keys + 1] = string.unpack("<I4", idx, off + 1)
    end
  else
    -- Set: u16 key pid and u8 key size after the 12-byte header, then
    -- (local key u32, reference count u32, key) per element.
    if #idx < 15 then return {} end
    local ksize = idx:byte(15)
    local stride = 8 + ksize
    for i = 0, count - 1 do
      local off = 15 + stride * i
      if off + 4 > #idx then break end
      keys[#keys + 1] = string.unpack("<I4", idx, off + 1)
    end
  end
  local out = {}
  for _, k in ipairs(keys) do
    local o = self.file:object(self.node:child(string.format("%s{%x}", name, k)))
    if o then out[#out + 1] = o end
  end
  return out
end

local File = {}
File.__index = File

-- The object stored in a CFB storage node (cached), or nil.
function File:object(node)
  if not node or node.type == 2 then return nil end
  local cached = self.cache[node]
  if cached then return cached end
  local o = setmetatable({ file = self, node = node, props = {},
                           clsid = node.clsid,
                           class = M.class_name(node.clsid) }, Obj)
  self.cache[node] = o
  local s = self.cfb.read(node:child("properties"))
  if s and #s >= 4 then
    if s:byte(1) ~= 0x4C then
      error("big-endian AAF objects are not supported", 0)
    end
    local n = string.unpack("<I2", s, 3)
    local hdr = 4
    local off = hdr + 6 * n
    for i = 0, n - 1 do
      local pid, form, len = string.unpack("<I2I2I2", s, hdr + 6 * i + 1)
      o.props[pid] = { form = form, value = s:sub(off + 1, off + len) }
      off = off + len
    end
  end
  return o
end

-- Header object (the root's "Header-2" storage).
function File:header()
  for _, n in ipairs(self.cfb.root:children()) do
    if n.type == 1 and M.class_name(n.clsid) == "Header" then
      return self:object(n)
    end
  end
  -- Some writers leave the CLSID off the header; fall back on the name.
  return self:object(self.cfb.find("Header-2"))
end

function M.open(data)
  local cfb, err = CFB.open(data)
  if not cfb then return nil, err end
  return setmetatable({ cfb = cfb, cache = {} }, File)
end

function M.open_file(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, "cannot open " .. tostring(path) .. ": " .. tostring(err) end
  local data = fh:read("a")
  fh:close()
  return M.open(data)
end

return M
