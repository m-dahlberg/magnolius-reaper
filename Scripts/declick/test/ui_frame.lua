-- Drive one panel frame against a stub ImGui.
--
-- The panel needs a ReaImGui context and a defer loop, so no suite can run it
-- for real. What it does not need is a real ImGui to *fail*: every way a panel
-- like this breaks is a Lua error inside frame() -- a config key renamed out
-- from under a slider, a field that moved, an unbalanced Begin/End -- and all
-- of those raise against a stub just as well.
--
-- The one thing this stub does that a naive one does not: `changed` makes every
-- control report that it was moved. A stub whose sliders always return false
-- never executes the code behind them, which is precisely where this panel's
-- worst bug lived -- `cfg[key] = v (on_change or mark_dirty)()` parsed as a
-- call on a number, so touching any control killed the script, and a frame
-- rendered with nothing moved was perfectly happy.

local M = {}

local function make_stub(log, clicks, changed)
  local stub = {}
  for k, v in pairs({ Cond_FirstUseEver = 1, Col_Text = 0,
                      SliderFlags_Logarithmic = 32 }) do stub[k] = v end

  local returns = {
    Begin            = function() return true, true end,
    CollapsingHeader = function() return true end,
    Button           = function(_, label) return clicks[label] == true end,
    SmallButton      = function(_, label) return clicks[label] == true end,
    -- `changed` flips these to "the user just moved this", which is the path
    -- that matters. The returned value is the current one, so a frame rendered
    -- this way is a no-op on cfg even though every callback fires.
    Checkbox     = function(_, _, v) return changed, v end,
    SliderDouble = function(_, _, v) return changed, v end,
    SliderInt    = function(_, _, v) return changed, v end,
    InputDouble  = function(_, _, v) return changed, v end,
    Combo        = function(_, _, v) return changed, v end,
    IsItemDeactivatedAfterEdit = function() return changed end,
    IsItemClicked         = function() return false end,
    GetMousePos           = function() return 0, 0 end,
    GetContentRegionAvail = function() return 500, 400 end,
    GetCursorScreenPos    = function() return 0, 0 end,
    GetWindowDrawList     = function() return {} end,
    CreateContext         = function() return {} end,
    CreateFunctionFromEEL = function() return {} end,
    GetBuiltinPath        = function() return "." end,
  }

  return setmetatable(stub, {
    __index = function(_, key)
      local fn = returns[key]
      if fn then return fn end
      return function(...)
        if key == "PushStyleColor" then log.push = log.push + 1 end
        if key == "PopStyleColor"  then log.pop  = log.pop  + 1 end
        if key == "BeginDisabled"  then log.dis  = log.dis  + 1 end
        if key == "EndDisabled"    then log.dis  = log.dis  - 1 end
        return nil
      end
    end,
  })
end

-- A kernel that answers the four questions recompute() asks, so a frame can be
-- rendered in the populated state without an item, an accessor or the EEL.
function M.stub_kernel(opts)
  opts = opts or {}
  local nb = opts.nbands or 12
  local wavb = opts.wavb or 64
  local k = { nsteps = 2000, stepsz = 240, nbands = nb, wavb = wavb,
              heap_mb = 6, nhist = 260, hist_lo = -5, hist_bin = 0.25,
              nlhist = 140, lhist_lo = -140, lhist_bin = 1 }
  function k:detect(_, sens, abs_floor_db)
    local n = math.max(0, math.floor(400 - sens * 12))
    -- an absolute floor can only ever remove candidates
    if abs_floor_db and abs_floor_db < 0 then n = math.floor(n * 0.8) end
    return { events = n, kept = n, cut_steps = n * 2, nsteps = self.nsteps,
             sens_db = sens }
  end
  -- The file's own step-level distribution: a silence island at the bottom of
  -- the axis, a wide dead gap, then the material. The shape Silence.floor
  -- exists to read, so the panel's silence report is exercised too.
  function k:level_histogram()
    local counts = {}
    for b = 0, 139 do counts[b] = 0 end
    for b = 58, 64 do counts[b] = 300 end        -- -82 .. -76 dBFS: the silence
    for b = 85, 130 do counts[b] = 120 end       -- -55 .. -10 dBFS: the material
    return { counts = counts, n = 140, lo = -140, bin = 1 }
  end
  function k:histogram()
    local counts = {}
    for b = 0, 259 do
      local db = -5 + (b + 0.5) * 0.25
      local taper = db < 0 and 0 or 4000 * math.exp(-0.5 * db)
      local bump = 60 * math.exp(-((db - 30) ^ 2) / 18)
      counts[b] = math.floor(taper + bump + 0.5)
    end
    return { counts = counts, n = 260, lo = -5, bin = 0.25 }
  end
  function k:waveform()
    local mn, mx, ck = {}, {}, {}
    for i = 1, wavb do
      mn[i], mx[i] = -0.4, 0.4
      ck[i] = (i % 9 == 0) and (10 + i % 20) or 0
    end
    return mn, mx, ck
  end
  function k:bands()
    local c, sum = {}, {}
    for b = 1, nb do c[b], sum[b] = b * 3, -b * 4.0 end
    return c, sum
  end
  function k:events(n)
    local t = {}
    for i = 1, math.min(n or 0, 5) do
      t[i] = { pos = i * 4800, over_db = 12 + i, width = 2, bands = 7 }
    end
    return t
  end
  function k:get() return 0 end
  return k
end

-- Renders one frame. `prepare(ST, cfg)` may populate state first.
-- Returns ok, err, log, ST.
function M.run(UI, dir, prepare, clicks, changed)
  local log = { push = 0, pop = 0, dis = 0 }
  local stub = make_stub(log, clicks or {}, changed and true or false)
  local ST, cfg = UI._init(stub, dir)
  if prepare then prepare(ST, cfg) end
  local ok, err = pcall(UI._frame)
  return ok, err, log, ST
end

return M
