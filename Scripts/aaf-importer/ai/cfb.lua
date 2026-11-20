-- @noindex
-- AAF Importer -- Compound File Binary (CFB, "OLE structured storage") reader.
--
-- An AAF file is a little file system: a header, a FAT of sector chains, a
-- directory of storages (folders) and streams (files), and a second, smaller
-- FAT for the streams under the mini-stream cutoff, which live packed together
-- inside one root stream. Everything AAF stores sits in streams found by path.
--
-- Pure Lua 5.4 (string.unpack), no reaper. The whole file is held as one
-- string; an AAF of a few hundred tracks is a few MB, which is nothing.
--
-- The one fact that makes the directory readable: a storage's children are
-- not a list but a red-black tree threaded through left/right sibling ids,
-- rooted at the storage's `child`. An in-order walk gives them all.

local M = {}

local FREESECT, ENDOFCHAIN = 0xFFFFFFFF, 0xFFFFFFFE
local NOSTREAM = 0xFFFFFFFF

local u32 = function(s, off) return (string.unpack("<I4", s, off + 1)) end

-- UTF-16LE to UTF-8. Surrogate pairs included: Pro Tools track names can hold
-- anything the user typed.
function M.utf16(s, i, j)
  i, j = i or 1, j or #s
  local out, k = {}, i
  while k + 1 <= j do
    local c = string.unpack("<I2", s, k)
    k = k + 2
    if c == 0 then break end
    if c >= 0xD800 and c <= 0xDBFF and k + 1 <= j then
      local lo = string.unpack("<I2", s, k)
      if lo >= 0xDC00 and lo <= 0xDFFF then
        k = k + 2
        c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)
      end
    end
    out[#out + 1] = utf8.char(c)
  end
  return table.concat(out)
end

-- 16 bytes as stored (Data1..3 little-endian) to the canonical lower-case
-- "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" form. AUIDs, CLSIDs and the AAF
-- definition keys all use this layout.
function M.guid(s, off)
  off = off or 0
  if #s < off + 16 then return nil end
  local d1, d2, d3 = string.unpack("<I4I2I2", s, off + 1)
  local b = { s:byte(off + 9, off + 16) }
  return string.format("%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    d1, d2, d3, b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
end

local Node = {}
Node.__index = Node

function Node:child(name)
  return self.kids and self.kids[name]
end

-- In directory order (the red-black in-order walk, i.e. sorted by the CFB
-- name comparison), which is NOT the AAF vector order: vectors are ordered by
-- their index stream.
function Node:children()
  return self.list or {}
end

function Node:is_stream() return self.type == 2 end

-- Opens a CFB image held in `data`. Returns the file object or nil + message.
function M.open(data)
  if #data < 512 or data:sub(1, 8) ~= "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1" then
    return nil, "not a compound file (no CFB signature) -- is this really an AAF?"
  end
  local f = { data = data }
  local byte_order = string.unpack("<I2", data, 0x1C + 1)
  if byte_order ~= 0xFFFE then return nil, "unsupported CFB byte order" end
  local shift = string.unpack("<I2", data, 0x1E + 1)
  local mshift = string.unpack("<I2", data, 0x20 + 1)
  if shift ~= 9 and shift ~= 12 then
    return nil, "unsupported CFB sector size 2^" .. shift
  end
  f.ss = 1 << shift
  f.mss = 1 << mshift
  local nfat = u32(data, 0x2C)
  local dir_start = u32(data, 0x30)
  f.cutoff = u32(data, 0x38)
  local minifat_start = u32(data, 0x3C)
  local difat_start = u32(data, 0x44)
  local ndifat = u32(data, 0x48)

  local function sector_off(n) return (n + 1) * f.ss end

  -- DIFAT: 109 entries in the header, the rest in a chain of DIFAT sectors,
  -- each holding ss/4 - 1 entries plus the pointer to the next.
  local fat_secs = {}
  for i = 0, 108 do
    local s = u32(data, 0x4C + 4 * i)
    if s ~= FREESECT and #fat_secs < nfat then fat_secs[#fat_secs + 1] = s end
  end
  local per = f.ss // 4 - 1
  local d, guard = difat_start, 0
  while d ~= ENDOFCHAIN and d ~= FREESECT and guard < ndifat + 1 and #fat_secs < nfat do
    local base = sector_off(d)
    for i = 0, per - 1 do
      local s = u32(data, base + 4 * i)
      if s ~= FREESECT and #fat_secs < nfat then fat_secs[#fat_secs + 1] = s end
    end
    d = u32(data, base + 4 * per)
    guard = guard + 1
  end

  -- The FAT itself, as one flat array (0-based sector -> next).
  local fat = {}
  local n = 0
  for _, s in ipairs(fat_secs) do
    local base = sector_off(s)
    if base + f.ss > #data then return nil, "FAT sector past the end of the file" end
    for i = 0, f.ss // 4 - 1 do
      fat[n] = u32(data, base + 4 * i)
      n = n + 1
    end
  end
  f.fat = fat

  -- Follows a chain; a cycle or a pointer past the file is a corrupt file, and
  -- must end the read rather than loop.
  local max_sectors = #data // f.ss + 1
  local function chain(start, table_, limit)
    local out, s, count = {}, start, 0
    while s ~= ENDOFCHAIN and s ~= FREESECT and s ~= nil do
      count = count + 1
      if count > limit then error("CFB sector chain does not terminate", 0) end
      out[#out + 1] = s
      s = table_[s]
    end
    return out
  end

  local function read_chain(start, size)
    local parts = {}
    for _, s in ipairs(chain(start, fat, max_sectors)) do
      local base = sector_off(s)
      parts[#parts + 1] = data:sub(base + 1, base + f.ss)
    end
    local s = table.concat(parts)
    if size then s = s:sub(1, size) end
    return s
  end

  -- Directory.
  local dir = read_chain(dir_start)
  local entries = {}
  for i = 0, #dir // 128 - 1 do
    local o = i * 128
    local nlen = string.unpack("<I2", dir, o + 0x40 + 1)
    local typ = dir:byte(o + 0x42 + 1)
    if typ ~= 0 then
      local size = string.unpack("<I4", dir, o + 0x78 + 1)
      if f.ss == 4096 then size = string.unpack("<I8", dir, o + 0x78 + 1) end
      entries[i] = setmetatable({
        id = i,
        name = M.utf16(dir, o + 1, o + math.max(0, nlen - 2)),
        type = typ,
        left = u32(dir, o + 0x44),
        right = u32(dir, o + 0x48),
        child_id = u32(dir, o + 0x4C),
        clsid = M.guid(dir, o + 0x50),
        start = u32(dir, o + 0x74),
        size = size,
      }, Node)
    end
  end
  f.count = 0
  for _ in pairs(entries) do f.count = f.count + 1 end

  local root = entries[0]
  if not root or root.type ~= 5 then return nil, "CFB has no root entry" end
  f.root = root

  -- Mini stream (held by the root entry) and mini FAT.
  f.mini = read_chain(root.start, root.size)
  local minifat = {}
  if minifat_start ~= ENDOFCHAIN and minifat_start ~= FREESECT then
    local mf = read_chain(minifat_start)
    for i = 0, #mf // 4 - 1 do minifat[i] = u32(mf, 4 * i) end
  end
  f.minifat = minifat

  -- Children: in-order walk of each storage's sibling tree. Iterative, with a
  -- visited set, because a damaged tree can point back into itself.
  local seen = {}
  local function attach(parent)
    parent.kids, parent.list = {}, {}
    local stack, cur = {}, parent.child_id
    while true do
      while cur ~= NOSTREAM and entries[cur] and not seen[cur] do
        stack[#stack + 1] = cur
        cur = entries[cur].left
      end
      if #stack == 0 then break end
      local id = table.remove(stack)
      if not seen[id] then
        seen[id] = true
        local e = entries[id]
        e.parent = parent
        parent.kids[e.name] = e
        parent.list[#parent.list + 1] = e
        cur = e.right
      else
        cur = NOSTREAM
      end
    end
    for _, e in ipairs(parent.list) do
      if e.type == 1 then attach(e) end
    end
  end
  seen[0] = true
  attach(root)

  function f.read(node)
    if not node or node.type ~= 2 then return nil end
    if node.size < f.cutoff then
      local parts = {}
      local max_mini = #f.mini // f.mss + 1
      for _, s in ipairs(chain(node.start, minifat, max_mini)) do
        local base = s * f.mss
        parts[#parts + 1] = f.mini:sub(base + 1, base + f.mss)
      end
      return table.concat(parts):sub(1, node.size)
    end
    return read_chain(node.start, node.size)
  end

  -- "a/b/c" from the root.
  function f.find(path)
    local node = root
    for part in path:gmatch("[^/]+") do
      node = node:child(part)
      if not node then return nil end
    end
    return node
  end

  return f
end

function M.open_file(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, "cannot open " .. tostring(path) .. ": " .. tostring(err) end
  local data = fh:read("a")
  fh:close()
  return M.open(data)
end

return M
