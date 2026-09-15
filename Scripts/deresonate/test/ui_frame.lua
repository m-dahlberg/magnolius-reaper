-- A stub ImGui, so one panel frame can be rendered and asserted without a real
-- context or a defer loop.
--
-- The panel needs a real context and a defer cycle to RUN, but it does not
-- need a real ImGui to FAIL: every way a panel like this has broken is a Lua
-- error inside frame() -- a config key renamed out from under a slider, a
-- state field that moved, an unbalanced stack -- and all of those raise against
-- a stub just as well.
--
-- The one thing that makes it worth having is the `changed` flag: with it every
-- control reports "the user just moved this", so the code BEHIND each control
-- actually executes. A stub whose sliders always return false never runs that
-- code, which is exactly where the worst bug these panels have had lived.

local M = {}

function M.stub(changed)
  local S = { push = 0, dis = 0, log = {} }
  local real = {
    CreateContext = function() return {} end,
    Begin = function() return true, true end,
    GetContentRegionAvail = function() return 600, 400 end,
    GetCursorScreenPos = function() return 0, 0 end,
    GetWindowDrawList = function() return {} end,
    CollapsingHeader = function() return true end,
    Button = function() return false end,
    SmallButton = function() return false end,
    SliderDouble = function(_, _, v) return changed, v end,
    SliderInt = function(_, _, v) return changed, v end,
    Checkbox = function(_, _, v) return changed, v end,
    -- Real ReaImGui REJECTS an item list that is not NUL-terminated, and the
    -- \31-separated form its docs mention is not accepted here. That error
    -- raises inside frame(), unbalances the disabled stack, and then
    -- ImGui.End raises over the top of it -- so the panel dies with no usable
    -- message and only the GUI ever sees the real one. A stub that shrugs at
    -- its arguments cannot catch that, so this one does not shrug.
    Combo = function(_, label, v, items)
      if type(items) ~= "string" or items:sub(-1) ~= "\0" then
        error("ImGui_Combo: items must be null-terminated (" ..
              tostring(label) .. ")", 2)
      end
      return changed, v
    end,
    RadioButton = function() return changed end,
    InputDouble = function(_, _, v) return changed, v end,
    IsItemDeactivatedAfterEdit = function() return changed end,
    InvisibleButton = function() return false end,
    Cond_FirstUseEver = function() return 0 end,
  }
  local mt = {
    __index = function(t, k)
      if real[k] then return real[k] end
      if k == "PushStyleColor" then
        return function() S.push = S.push + 1 end
      elseif k == "PopStyleColor" then
        return function() S.push = S.push - 1 end
      elseif k == "BeginDisabled" then
        return function() S.dis = S.dis + 1 end
      elseif k == "EndDisabled" then
        return function() S.dis = S.dis - 1 end
      elseif k == "Text" or k == "TextColored" then
        return function(_, a, b) S.log[#S.log + 1] = tostring(b or a) end
      end
      return function() end
    end,
  }
  return setmetatable({}, mt), S
end

-- Render one frame. `prepare(ST, cfg)` may seed analysis state first.
function M.run(UI, dir, prepare, changed)
  local stub, S = M.stub(changed and true or false)
  local ST, cfg = UI._init(stub, dir)
  -- never let a test write the user's settings
  local Config = require "dr.config"
  local saved = Config.save
  Config.save = function() end
  if prepare then prepare(ST, cfg) end
  local ok, err = pcall(UI._frame)
  Config.save = saved
  return ok, err, S, ST, cfg
end

-- A fake analysed state, built through the REAL pure stages so the test cannot
-- disagree with the thing it is testing.
function M.stub_state(ST, cfg)
  local Spectrum = require "dr.spectrum"
  local Config   = require "dr.config"
  local Kernel   = require "dr.kernel"
  local nb = 512
  local bin = Config.bin_hz(cfg)
  ST.hz = Spectrum.hz_axis(nb, bin)
  ST.p20, ST.p90, ST.occ = {}, {}, {}
  for i = 1, nb do
    ST.p20[i] = -85.0 + 6.0 * math.exp(-((ST.hz[i] - 476) / 120) ^ 2)
    ST.p90[i] = ST.p20[i] + 30.0
    ST.occ[i] = 0.1
  end
  ST.env = Spectrum.smooth_power(ST.p20, ST.hz, 1 / cfg.smooth_oct)
  ST.rhz, ST.times, ST.ridx = { 100, 200, 400, 800 }, { 0.2, 0.2, 0.2, 0.2 }, { 1, 1, 1, 1 }
  ST.ring_p50, ST.nring_bands = 0.2, 4
  -- through the real estimator, so the populated frame exercises the auto
  -- branch rather than the "could not measure" one
  local Auto = require "dr.auto"
  ST.pinned = false
  -- the decay cube's readout, and the path auto mode actually takes
  ST.edc_med, ST.edc_bands, ST.edc_gaps = 0.55, 28, 17
  ST.auto, ST.auto_why = Auto.from_decay(ST.edc_med, ST.edc_bands, ST.pinned)
  ST.F = { n = 100, modal_frames = 50, f0 = {}, aper = {}, level_db = {} }
  for i = 1, 100 do ST.F.f0[i] = 200; ST.F.aper[i] = 0.05; ST.F.level_db[i] = -20 end
  ST.voiced_frac, ST.f0_p50, ST.f0_p95 = 0.8, 200, 260
  ST.geo = { item_len = 30, nchan = 1, rate = 48000, rate_known = true }
  -- The gate's suggestion, through the REAL estimator, and the stage switched
  -- ON: with it off the panel's populated branches and the threshold overlay
  -- in draw_spectrum never execute, and a frame that renders nothing proves
  -- nothing about them.
  local Gate = require "dr.gate"
  local ghz, gp, gv, gf, gt, gn = {}, {}, {}, {}, {}, {}
  for i = 1, 60 do
    ghz[i] = 30 * 2 ^ ((i - 1) / 12)       -- 30 Hz .. ~1.9 kHz, as the ring pass
    gp[i], gv[i], gf[i], gt[i], gn[i] = -70.0, -30.0, -95.0, 0.45, 400
  end
  ST.gate, ST.gate_why, ST.gate_nmeas =
    Gate.suggest(gp, gv, gf, ghz, gt, 60, false, gn)
  cfg.gate_on = true

  local Detect = require "dr.detect"
  local Broad  = require "dr.broad"
  ST.cands = Detect.run(ST.p20, ST.hz, ST.occ, function() return 1.0 end, cfg, bin)
  ST.humps = Broad.humps(ST.p90, ST.p20, ST.hz, cfg, 300)
  ST.broad_lo = 300
end

return M
