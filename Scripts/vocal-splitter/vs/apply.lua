-- @noindex
-- Vocal Splitter -- stage 5: turn spans into split, gained, crossfaded items.
--
-- The only module that touches the project.

local Config = require "vs.config"

local M = {}

local function set(item, k, v) reaper.SetMediaItemInfo_Value(item, k, v) end
local function get(item, k) return reaper.GetMediaItemInfo_Value(item, k) end

local function colour_for(class)
  local c = Config.class_colour[class]
  if not c then return 0 end
  local r = math.floor(c[1] * 255)
  local g = math.floor(c[2] * 255)
  local b = math.floor(c[3] * 255)
  return reaper.ColorToNative(r, g, b) | 0x1000000
end

-- Overlap a boundary so REAPER's auto-crossfade slot has something to draw
-- into. The fade is centred on the cut: the left item's tail is extended by
-- cf/2 and the right item's head pulled back by cf/2, giving an overlap of
-- exactly cf straddling the cut point.
--
-- Centred is not cosmetic. hierarchy.place_cut clamps cf to twice the distance
-- from the cut to the nearer edge of the safe zone, which is only the correct
-- clamp if the fade extends cf/2 each way. A one-sided overlap would reach
-- twice as far in one direction and could land in usable audio -- exactly the
-- invariant the guard rails exist to protect.
--
-- Two further details are the usual source of bugs here:
--
--   1. D_STARTOFFS shifts by the overlap * D_PLAYRATE, not the overlap. Without
--      the playrate factor the audio desyncs on any time-stretched take.
--
--      This is the one place in the script that still scales by the playrate,
--      and it stayed right when the frame geometry was fixed. The two are
--      different questions: `half` is project seconds off the timeline, and
--      D_STARTOFFS is measured in the SOURCE file, which advances playrate
--      times faster -- so moving an item `half` earlier moves its read point
--      `half * playrate` earlier in the source. The frame table's times, by
--      contrast, come out of the accessor, whose audio is already stretched
--      and whose timeline is item time, so they need no scaling at all.
--      test/verify_edit_in_reaper.lua pins it: on every resulting item,
--      D_STARTOFFS - D_POSITION * playrate must come out the same.
--   2. Overlapping items use D_FADEINLEN_AUTO / D_FADEOUTLEN_AUTO. Setting the
--      manual D_FADEINLEN on an overlap does not render as a crossfade at all.
--
-- Fades are linear (shape 0, dir 0) on purpose: both sides of the overlap are
-- the same source material, so equal-gain sums to unity and reconstructs the
-- original exactly. Equal-power would put a +3 dB bump at every join.
local function crossfade(left, right, cf)
  if cf <= 0 then return end
  local rtake = reaper.GetActiveTake(right)
  if not rtake then return end

  local rpos  = get(right, "D_POSITION")
  local rlen  = get(right, "D_LENGTH")
  local rsnap = get(right, "D_SNAPOFFSET")
  local rate  = reaper.GetMediaItemTakeInfo_Value(rtake, "D_PLAYRATE")
  if rate <= 0 then rate = 1 end
  local roffs = reaper.GetMediaItemTakeInfo_Value(rtake, "D_STARTOFFS")

  -- Never pull the source read before the start of the media. roffs / rate is
  -- the same conversion running the other way: how many seconds of *timeline*
  -- the source offset is worth.
  local half = math.min(cf / 2, rpos, roffs / rate)
  if half <= 0 then return end

  set(right, "D_POSITION", rpos - half)
  set(right, "D_LENGTH",   rlen + half)
  set(right, "D_SNAPOFFSET", rsnap + half)
  reaper.SetMediaItemTakeInfo_Value(rtake, "D_STARTOFFS", roffs - half * rate)

  set(left, "D_LENGTH", get(left, "D_LENGTH") + half)

  local ov = half * 2
  set(right, "D_FADEINLEN_AUTO", ov)
  set(right, "C_FADEINSHAPE", 0)
  set(right, "D_FADEINDIR", 0)

  set(left, "D_FADEOUTLEN_AUTO", ov)
  set(left, "C_FADEOUTSHAPE", 0)
  set(left, "D_FADEOUTDIR", 0)
end

-- Consecutive spans inside one phrase share a gain by construction, so
-- suppressing equal-gain cuts collapses most of them without changing a thing
-- audibly. On a three minute vocal this is the difference between ~800 items
-- and ~150.
local function merge_equal(spans, enabled)
  if not enabled then return spans end
  local out = {}
  for _, s in ipairs(spans) do
    local p = out[#out]
    if p and p.class == s.class
       and math.abs(p.gain_db - s.gain_db) < 1e-6 then
      p.t1 = s.t1
      p.cf_out = s.cf_out
    else
      out[#out + 1] = {
        t0 = s.t0, t1 = s.t1, cf_in = s.cf_in, cf_out = s.cf_out,
        class = s.class, gain_db = s.gain_db,
      }
    end
  end
  return out
end

-- spans are in seconds from the START OF THE ANALYSED SPAN, which is the item start with no
-- time selection and the selection's start with one. `origin` carries that; without it a run
-- over a selection would cut at the head of the item instead.
function M.run(item, spans, cfg, origin)
  spans = merge_equal(spans, cfg.split_only_on_change)
  if #spans == 0 then return 0 end

  local item_pos = origin or get(item, "D_POSITION")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- REAPER's own "auto-crossfade on split" would add an overlap and a fade to
  -- every split before we get to place ours, leaving the lengths wrong and the
  -- fades doubled. Turn it off for the duration and put it back.
  local auto_xfade = reaper.GetToggleCommandState(40912) == 1
  if auto_xfade then reaper.Main_OnCommand(40912, 0) end

  -- Split back to front. SplitMediaItem returns the right-hand piece and
  -- leaves `item` as the left one, so descending order keeps every remaining
  -- position valid with no bookkeeping.
  local right = {}
  for k = #spans, 2, -1 do
    local t = item_pos + spans[k].t0
    local r = reaper.SplitMediaItem(item, t)
    right[k] = r or nil
  end

  local items = { item }
  for k = 2, #spans do items[k] = right[k] end

  -- Numeric loop, not ipairs: SplitMediaItem returns nil if a split point
  -- falls outside the item, and ipairs would stop at that hole and silently
  -- leave every later item ungained.
  local n = 0
  for k = 1, #spans do
    local s = items[k]
    if s then
      n = n + 1
      local span = spans[k]
      reaper.SetMediaItemInfo_Value(s, "D_VOL", 10 ^ (span.gain_db / 20))
      if cfg.colour_items then
        reaper.SetMediaItemInfo_Value(s, "I_CUSTOMCOLOR", colour_for(span.class))
      end
      reaper.GetSetMediaItemInfo_String(s, "P_EXT:vsplit_class", span.class, true)
      reaper.GetSetMediaItemInfo_String(s, "P_EXT:vsplit_gain",
                                        string.format("%.3f", span.gain_db), true)
      local take = reaper.GetActiveTake(s)
      if take then
        local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME",
          nm .. " [" .. span.class .. "]", true)
      end
    end
  end

  -- Crossfades last: overlapping earlier would move positions the splits
  -- above still depend on.
  for k = 2, #spans do
    if items[k] and items[k - 1] then
      crossfade(items[k - 1], items[k], spans[k].cf_in)
    end
  end

  if auto_xfade then reaper.Main_OnCommand(40912, 0) end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Vocal splitter", -1)
  return n
end

-- Marker-only output for checking detection without touching audio.
--
-- Elements go down as *regions*, not markers. A breath or an /s/ is a span
-- with a start and an end, and both ends are the thing under judgement: the
-- complaint that sends you here is either "it did not find that" or "the clip
-- is shorter than the sound". A point marker can only answer the first.
function M.mark(item, tree, F, cfg)
  -- Same origin rule as M.run: F knows where its frame 0 sits.
  local item_pos = (F and F.origin)
                   or reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local colour = {
    breath    = reaper.ColorToNative(140,  90, 155) | 0x1000000,
    consonant = reaper.ColorToNative(165, 130,  65) | 0x1000000,
    sibilance = reaper.ColorToNative(165,  75,  75) | 0x1000000,
  }
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local idx = 0
  local nel = 0
  for si, sec in ipairs(tree.sections) do
    reaper.AddProjectMarker2(0, false, item_pos + sec.t0, 0,
      string.format("S%d  %.1f dB", si, sec.level.db), -1,
      reaper.ColorToNative(200, 120, 60) | 0x1000000)
    for pi, phr in ipairs(sec.phrases) do
      idx = idx + 1
      reaper.AddProjectMarker2(0, false, item_pos + phr.t0, 0,
        string.format("  P%d.%d  %.1f dB", si, pi, phr.level.db), -1,
        reaper.ColorToNative(80, 120, 180) | 0x1000000)

      if F then
        for _, el in ipairs(phr.elements) do
          local c = colour[el.class]
          if c then
            nel = nel + 1
            -- hierarchy.ftime, inlined: item-relative project seconds, so the
            -- item position is all that has to be added to reach the timeline.
            local t0 = item_pos + (el.sig_i0 - 1) * F.acc_frame_dur
            local t1 = item_pos + el.sig_i1 * F.acc_frame_dur
            reaper.AddProjectMarker2(0, true, t0, t1,
              string.format("%s %.1f dB", el.class, el.level_db), -1, c)
          end
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Vocal splitter: mark hierarchy", -1)
  return idx, nel
end

return M
