-- AutoTilt -- one panel frame against a stub ImGui.
--
-- The panel needs a real context and a defer loop to run for real, so no suite
-- can drive it properly. What it does not need is a real ImGui to *fail*:
-- every way a panel like this has broken is a Lua error inside frame() -- a
-- config key renamed out from under a slider, a diagnostic field that moved,
-- an unbalanced stack -- and all of those raise against a stub just as well.
--
-- The one thing that makes it worth having is the `changed` flag. A stub whose
-- sliders always return false never executes the code behind them, which is
-- exactly where the worst bug these panels have had lived. Every state is
-- rendered twice: once quiet, once with every control reporting "just moved".

local Config   = require "at.config"
local Spectrum = require "at.spectrum"

local M = {}

local function make_stub(log, clicks, changed)
  local stub = {}
  for k, v in pairs({
    Cond_FirstUseEver = 1, Col_Text = 0, SliderFlags_Logarithmic = 32,
  }) do stub[k] = v end

  local returns = {
    Begin            = function() return true, true end,
    CollapsingHeader = function() return true end,
    Button           = function(_, label) return clicks[label] == true end,
    SmallButton      = function(_, label) return clicks[label] == true end,
    Checkbox     = function(_, _, v) return changed, v end,
    SliderDouble = function(_, _, v) return changed, v end,
    SliderInt    = function(_, _, v) return changed, v end,
    InputDouble  = function(_, _, v) return changed, v end,
    InputInt     = function(_, _, v) return changed, v end,
    Combo        = function(_, _, v) return changed, v end,
    -- The track pickers. BeginCombo must open, or the dropdown body -- where the role is
    -- actually written -- is never executed, and a picker that assigned the wrong key would
    -- pass. Selectable follows `changed` for the same reason the sliders do.
    BeginCombo = function() return true end,
    Selectable = function() return changed end,
    InputText  = function(_, _, v) return changed, v end,
    IsItemDeactivatedAfterEdit = function() return changed end,
    IsItemHovered         = function() return false end,
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

-- An analysis record with the shape the panel reads, built through the real
-- Spectrum.build so the test cannot disagree with the thing it is testing
-- about what a cube looks like.
--
-- `tilt_db_oct` shapes the synthetic spectrum: 0 is white, -3 is pink.
function M.stub_ana(fft_size, rate, tilt_db_oct, nframes, loud_lev)
  fft_size = fft_size or 256
  rate = rate or 48000
  local nbins = fft_size // 2 + 1
  local nlev = Config.NLEV
  local rows, counts = {}, {}
  for lev = 0, nlev - 1 do counts[lev] = 0 end

  -- Two occupied buckets: a loud one holding the material and a quiet one
  -- holding "room tone", so a gate has something to exclude.
  -- A row is the SUM over the frames in its bucket, the way the kernel
  -- accumulates it, not one frame's spectrum.
  local function row(per_frame, n)
    local r = {}
    for k = 0, nbins - 1 do
      local f = (k == 0) and 1 or k * rate / fft_size
      r[k + 1] = per_frame * n *
        10 ^ ((tilt_db_oct or -3) * math.log(f / 1000, 2) / 10)
    end
    return r
  end
  loud_lev = loud_lev or 90
  nframes = nframes or 200
  rows[loud_lev] = row(1.0, nframes)
  counts[loud_lev] = nframes
  rows[loud_lev - 45] = row(1e-5, 60)
  counts[loud_lev - 45] = 60

  local ana = Spectrum.build(rows, counts, nbins, nlev, Config.LEV0)
  ana.rate, ana.fft_size, ana.nchan, ana.clips = rate, fft_size, 1, 1
  return ana
end

-- Renders one frame and reports whether it raised.
--
-- Config.save is stubbed out for the duration: the `changed` flag makes every
-- control report an edit, and a real save would write this test's cfg over the
-- user's stored settings.
-- The panel persists on edit, and in the `changed` pass every control reports as edited -- so
-- a run would write fixture track GUIDs into the user's saved roles. Snapshot and restore.
local ROLE_SUFFIXES = { "_guid", "_name", "_override" }

local function role_keys(Config)
  local out = {}
  for k in pairs(Config.defaults or {}) do
    for _, suffix in ipairs(ROLE_SUFFIXES) do
      if k:sub(-#suffix) == suffix then out[#out + 1] = k end
    end
  end
  return out
end

function M.snapshot_roles(Config, section)
  local saved = {}
  for _, k in ipairs(role_keys(Config)) do
    saved[k] = reaper.GetExtState(section, k)
  end
  return saved
end

function M.restore_roles(saved, section)
  for k, v in pairs(saved or {}) do
    reaper.SetExtState(section, k, v, true)
  end
end

function M.run(UI, dir, prepare, clicks, changed)
  local log = { push = 0, pop = 0, dis = 0 }
  local stub = make_stub(log, clicks or {}, changed and true or false)
  local ST, cfg = UI._init(stub, dir)

  local real_save = Config.save
  Config.save = function() end
  if prepare then prepare(ST, cfg) end
  local ok, err = pcall(UI._frame)
  Config.save = real_save

  return ok, err, log, ST, cfg
end

return M
