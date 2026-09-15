-- @noindex
-- Track Manager -- folder expansion, over a plain list.
--
-- Pure Lua: `list` is an array of tables carrying a `depth` field, which is
-- whatever I_FOLDERDEPTH said, and nothing here knows or cares what else is on
-- them. That is what lets the awkward cases -- nesting, a -2 that closes two
-- folders at once, a folder left unclosed at the end of the project -- be
-- tested without a project.
--
-- REAPER stores folder structure as a running delta, not as parent pointers:
-- +1 opens a folder, 0 is an ordinary track, -n closes n folders. So a
-- folder's extent is found by walking forward from it summing depths until the
-- sum returns to zero, and nesting falls out of that for free -- a child
-- folder's own +1 pushes the level back up, and its children are swept in
-- without a second pass.

local M = {}

-- `hit` is a set of 1-based indices. Returns a new set: every hit, plus every
-- descendant of every hit that opens a folder.
function M.expand_folders(list, hit, n)
  n = n or #list
  local out = {}
  for i, v in pairs(hit) do out[i] = v end

  for i = 1, n do
    if hit[i] and (list[i].depth or 0) >= 1 then
      local level = list[i].depth
      local j = i + 1
      -- j <= n is not just tidiness: a project whose last track is a folder
      -- start has no closing -1 anywhere, and without the bound this walks off
      -- the end of the list forever.
      while j <= n and level > 0 do
        out[j] = true
        level = level + (list[j].depth or 0)
        j = j + 1
      end
    end
  end
  return out
end

-- Nesting level per track, 1-based: a top-level track or a top-level folder
-- parent is 1, the tracks directly inside that folder are 2, tracks inside a
-- subfolder of it are 3.
--
-- The level is read BEFORE the track's own depth is applied, which is what
-- puts a folder parent on the same level as its siblings rather than on its
-- children's. The clamp at zero is for a project whose deltas do not balance
-- -- a stray -1 from a hand-edited RPP would otherwise push every track after
-- it a level too shallow, and there is no level below 1.
function M.levels(list, n)
  n = n or #list
  local out, cur = {}, 0
  for i = 1, n do
    out[i] = cur + 1
    cur = cur + (list[i].depth or 0)
    if cur < 0 then cur = 0 end
  end
  return out
end

function M.max_level(list, n)
  local lv, max = M.levels(list, n), 0
  for i = 1, #lv do
    if lv[i] > max then max = lv[i] end
  end
  return max
end

-- Several index lists -> one, deduplicated and in project order. The blunt
-- instruments in Solo/Mute mode work over the union of the nine slots, and
-- slots are allowed to overlap, so the dedup is the point.
function M.union(lists, n)
  local set = {}
  for _, l in ipairs(lists) do
    for _, i in ipairs(l) do set[i] = true end
  end
  return M.to_list(set, n)
end

-- Set -> sorted array, so callers iterate in project order.
function M.to_list(set, n)
  local out = {}
  for i = 1, n do
    if set[i] then out[#out + 1] = i end
  end
  return out
end

return M
