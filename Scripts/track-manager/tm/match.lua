-- @noindex
-- Track Manager -- pattern text into a matcher.
--
-- Pure Lua, no reaper dependency, so the whole matching language is testable
-- headlessly. Everything downstream asks this file two questions and nothing
-- else: parse this slot's text, and does this track name match.
--
-- The language is deliberately small, because it is typed into a field 150 px
-- wide with no room for a syntax reminder:
--
--   drums              substring   -- finds "Drums OH", "Room drums"
--   drums*             anchored    -- names STARTING with drums
--   *bus               anchored    -- names ENDING with bus
--   gtr*, perc*        several terms, any of them may match
--   gtr*, -gtr ref     a leading - excludes, and exclusion always wins
--
-- The substring/anchored split is the one judgement call. A term with no
-- wildcard in it is almost always someone naming a group they can see in the
-- TCP -- "drums" meaning the drum tracks, not a track called exactly that --
-- so bare terms are substrings. The moment a `*` appears the user is being
-- explicit about position, and then the pattern anchors at both ends: `drums*`
-- has to mean starts-with or it is indistinguishable from `drums`.

local M = {}

-- The Lua pattern magic set. `*` and `?` are in here too: they get escaped
-- along with everything else and are un-escaped afterwards, which is what
-- makes a name like "Gtr (DI)" safe to type as a pattern.
local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

-- One term -> a Lua pattern. Anchored when the term carried a wildcard.
local function term_pattern(term)
  local glob = term:find("[*?]") ~= nil
  local body = term:gsub(MAGIC, "%%%0")
  body = body:gsub("%%%*", ".*"):gsub("%%%?", ".")
  if glob then return "^" .. body .. "$" end
  return body
end

-- Splits on , and ;, trims, sorts terms into include and exclude.
--
-- `empty` is not the same as "no include terms": a slot holding only `-vox`
-- means every track except the vocals, and a slot holding nothing at all means
-- nothing. The panel disables a button whose slot is empty, so the difference
-- has to survive parsing.
function M.parse(text)
  local p = { include = {}, exclude = {}, empty = true }
  for raw in tostring(text or ""):gmatch("[^,;]+") do
    local term = raw:match("^%s*(.-)%s*$")
    local neg = false
    if term:sub(1, 1) == "-" then
      neg, term = true, term:sub(2):match("^%s*(.-)%s*$")
    end
    if term ~= "" then
      local pat = term_pattern(term:lower())
      local into = neg and p.exclude or p.include
      into[#into + 1] = pat
      p.empty = false
    end
  end
  return p
end

function M.matches(p, name)
  if p.empty then return false end
  local n = tostring(name or ""):lower()
  for _, pat in ipairs(p.exclude) do
    if n:find(pat) then return false end
  end
  if #p.include == 0 then return true end
  for _, pat in ipairs(p.include) do
    if n:find(pat) then return true end
  end
  return false
end

-- A track name back into the slot language, for the import button.
--
-- The language has no escape, deliberately, so the characters that mean
-- something in it cannot be quoted -- they have to be spent. `,` and `;`
-- separate terms and a leading `-` negates, and that last one is the reason
-- this function exists: a track called "-Room" imported verbatim would give a
-- slot quietly meaning *everything except* that track. `?` is one character of
-- anything, so it stands in for all three and the term still matches the name
-- it came from. It anchors the term as well, which only makes the import
-- tighter than the substring a typed name would have given.
function M.literal(name)
  local s = tostring(name or ""):match("^%s*(.-)%s*$")
  s = s:gsub("[,;]", "?")
  if s:sub(1, 1) == "-" then s = "?" .. s:sub(2) end
  return s
end

return M
