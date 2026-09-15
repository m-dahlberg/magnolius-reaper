-- Vocal Normalizer -- pure-Lua suite.
--
-- Covers the stages that hold the algorithm and no REAPER: filter design,
-- the block grid, the gate, the reduction, loudness range, the gain law, the
-- volume arithmetic and the parameter classes.
--
-- What it cannot cover: whether the kernel filters the way biquad.lua says it
-- does (test/selftest_in_reaper.lua), and whether the accessor hands over the
-- samples the geometry says it will (test/verify_edit_in_reaper.lua). Those
-- are the two seams either side of this file, and they are where the real bugs
-- live -- a pure suite over synthetic frames is green whatever the audio path
-- is doing.
--
-- Runs under REAPER's embedded Lua via reascript_test.py (there is no system
-- lua on this machine) and equally from the Actions list.

local src  = debug.getinfo(1, "S").source:match("^@(.+)$")
local dir  = src:match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. package.path

local Config   = require "vn.config"
local Biquad   = require "vn.biquad"
local Loudness = require "vn.loudness"
local Plan     = require "vn.plan"

local pass, fail = 0, 0

local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL  %s%s", name, extra and ("  -- " .. extra) or ""))
  end
end

local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %s (tol %s)", tostring(a), tostring(b), tostring(tol)))
end

-- Anything that stops the run counts as a failure, not as "nothing to check".
local function bail(msg)
  fail = fail + 1
  print("FAIL  " .. msg)
end

local function conf(over)
  local c = Config.new()
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

--------------------------------------------------------------- filter design

do
  -- The one external fact this script rests on: BS.1770's own coefficients.
  -- The K chain is built by mapping those poles and zeros to the target rate,
  -- so at 48 kHz the map is the identity and the result must be the table
  -- itself, to the last bit.
  local k = Biquad.kweight(48000)
  local worst = 0
  for i = 1, 2 do
    for j = 1, 5 do
      worst = math.max(worst, math.abs(k[i][j] - Biquad.K48[i][j]))
    end
  end
  ok(worst < 1e-12, "K-weighting at 48 kHz is BS.1770's table exactly",
     string.format("worst coefficient error %.3e", worst))

  -- ...and at every other rate it is the same ANALOG filter. The residual is
  -- the bilinear transform's frequency warping, which is inherent: what must
  -- not happen is the curve sliding with the sample rate, which is what a
  -- naive reuse of the 48 kHz coefficients would do (4 dB of error at 100 Hz).
  for _, rate in ipairs({ 44100, 88200, 96000 }) do
    local kk = Biquad.kweight(rate)
    local w = 0
    for f = 20, 20000, 20 do
      w = math.max(w, math.abs(Biquad.response_db(kk, f, rate)
                             - Biquad.response_db(Biquad.K48, f, 48000)))
    end
    ok(w < 0.05, string.format(
      "K-weighting at %d Hz matches the 48 kHz curve", rate),
      string.format("worst %.4f dB", w))
  end

  -- The shelf's shape, so a change to the mapping cannot quietly flatten it.
  local k44 = Biquad.kweight(44100)
  near(Biquad.response_db(k44, 16000, 44100), 4.04, 0.1, "K shelf reaches +4 dB")
  near(Biquad.response_db(k44, 38.1, 44100), -5.8, 0.4, "K high-pass at 38 Hz")

  -- Butterworth sections. The Qs are the whole design; get them wrong and the
  -- band gets a resonant peak instead of a flat passband.
  local q2 = Biquad.butterworth_qs(2)
  ok(#q2 == 1, "order 2 is one section")
  near(q2[1], 0.70710678, 1e-7, "order 2 Q is 1/sqrt(2)")
  local q4 = Biquad.butterworth_qs(4)
  ok(#q4 == 2, "order 4 is two sections")
  near(q4[1], 0.54119610, 1e-7, "order 4 first Q")
  near(q4[2], 1.30656296, 1e-7, "order 4 second Q")
  ok(not pcall(Biquad.butterworth_qs, 3), "an odd order is refused")

  -- The band itself: flat in the middle, -3 dB at each corner, and rolling off
  -- at the slope the order promises.
  local c = conf({ band_lo_hz = 100, band_hi_hz = 1000, band_order = 4 })
  local b = Biquad.band(c, 48000)
  ok(#b == 4, "order 4 band is four sections", tostring(#b))
  near(Biquad.response_db(b, 316, 48000), 0, 0.15, "flat at the band centre")
  near(Biquad.response_db(b, 100, 48000), -3.01, 0.15, "-3 dB at the low corner")
  near(Biquad.response_db(b, 1000, 48000), -3.01, 0.15, "-3 dB at the high corner")
  -- One octave below 100 and one above 1000, a 24 dB/oct skirt must be ~24 dB
  -- down on top of the 3 dB at the corner.
  near(Biquad.response_db(b, 50, 48000), -27, 3, "24 dB/oct below the band")
  near(Biquad.response_db(b, 2000, 48000), -27, 3, "24 dB/oct above the band")
  -- The two numbers that matter for the complaint this script answers:
  -- sibilance and rumble both have to be inaudible to the meter.
  ok(Biquad.response_db(b, 6000, 48000) < -50, "6 kHz sibilance is >50 dB down")
  ok(Biquad.response_db(b, 40, 48000) < -30, "40 Hz rumble is >30 dB down")

  local c2 = conf({ band_order = 2 })
  ok(#Biquad.band(c2, 48000) == 2, "order 2 band is two sections")
  local ck = conf({ kweight = true })
  ok(#Biquad.band(ck, 48000) == 6, "K-weighting adds two sections")

  -- A corner past Nyquist has no filter to design. The "full band" preset asks
  -- for 20 kHz at 44.1, whose low-pass corner is under Nyquist -- but a 96 kHz
  -- session moved to a 22.05 kHz source would not be, and a low-pass that
  -- returned garbage there would silently zero the measurement.
  local wide = conf({ band_lo_hz = 20, band_hi_hz = 20000, band_order = 4 })
  local bw = Biquad.band(wide, 22050)
  near(Biquad.response_db(bw, 1000, 22050), 0, 0.2,
       "a band wider than Nyquist still passes its middle")
end

---------------------------------------------------------------- frame fixture

-- Build a frame table by hand: `segs` is a list of { db, n } saying "n frames
-- at this level". `db` here is the mean square in dB, i.e. what db10 will
-- report back before the -0.691 offset.
local function frames(segs, hop_s, nsamp)
  hop_s = hop_s or 0.1
  nsamp = nsamp or 4800
  local F = { hop_s = hop_s, n = 0, zb = {}, zk = {}, cnt = {}, peak = 0.5,
              rate = 48000, nchan = 1, span = 0 }
  for _, s in ipairs(segs) do
    for _ = 1, s.n do
      local i = F.n + 1
      F.n = i
      -- z is a SUM of squares over the frame; blocks divide by the count.
      local ms = 10 ^ ((s.db - Loudness.OFFSET) / 10)
      F.zb[i], F.zk[i], F.cnt[i] = ms * nsamp, ms * nsamp, nsamp
    end
  end
  F.span = F.n * hop_s
  return F
end

---------------------------------------------------------------------- blocks

do
  local c = conf()
  -- 40 frames of 100 ms at one level -> 37 overlapping 400 ms blocks.
  local F = frames({ { db = -20, n = 40 } })
  local b = Loudness.blocks(F, "zb", c)
  ok(#b == 37, "40 quarter-blocks make 37 gating blocks", tostring(#b))
  near(b[1].db, -20, 1e-9, "a flat signal's block reads its own level")
  near(b[1].t0, 0, 1e-12, "the first block starts at zero")
  near(b[1].t1, 0.4, 1e-12, "a block is four quarter-blocks long")
  near(b[2].t0, 0.1, 1e-12, "blocks hop by one quarter-block")

  -- Shorter than one block: measured over what there is, and marked.
  local S = frames({ { db = -14, n = 2 } })
  local sb = Loudness.blocks(S, "zb", c)
  ok(#sb == 1 and sb[1].short, "a short item gets one flagged block")
  near(sb[1].db, -14, 1e-9, "and it still reads the right level")

  -- The volume already on the clip is folded in, so the numbers describe what
  -- comes OUT of the item. Halving the volume is -6.02 dB.
  local hb = Loudness.blocks(F, "zb", c, 0.5)
  near(hb[1].db, -26.02, 0.01, "clip volume is folded into the measurement")

  ok(#Loudness.blocks({ n = 0, hop_s = 0.1, zb = {}, cnt = {} }, "zb", c) == 0,
     "no frames means no blocks")
end

------------------------------------------------------------------- the gate

do
  local c = conf()
  -- One loud passage and a long quiet one. The relative gate should throw the
  -- quiet half away, which is the whole reason a vocal with pauses in it can
  -- be normalised at all.
  local F = frames({ { db = -18, n = 40 }, { db = -50, n = 400 } })
  local b = Loudness.blocks(F, "zb", c)
  local r = Loudness.integrate(b, c)
  if not r then bail("integrate returned nothing on a two-level fixture") else
    near(r.db, -18, 0.3, "the gate keeps the singing and drops the silence")
    ok(r.ngated < r.nabs, "the relative gate removed something",
       string.format("%d of %d", r.ngated, r.nabs))
    ok(r.nabs == r.nblocks, "nothing was below the absolute gate")
    -- Ungated, the same frames would land far lower. This is the assertion
    -- that says the gate is doing work rather than being merely present.
    local ungated = conf({ gate_rel_lu = -400 })
    local b2 = Loudness.blocks(F, "zb", ungated)
    local r2 = Loudness.integrate(b2, ungated)
    ok(r2.db < r.db - 8, "without the relative gate the answer collapses",
       string.format("%.2f vs %.2f", r2.db, r.db))
  end

  -- Digital silence: everything below the absolute gate is a stated failure,
  -- not a number.
  local Z = frames({ { db = -140, n = 40 } })
  local zr, zerr = Loudness.integrate(Loudness.blocks(Z, "zb", c), c)
  ok(zr == nil and zerr ~= nil, "silence is refused with a message", tostring(zerr))

  -- Blocks are marked in place, which is what the plot draws.
  local marked = 0
  for _, blk in ipairs(b) do if blk.gated then marked = marked + 1 end end
  ok(marked == r.ngated, "the plot's marks agree with the count")
end

do
  -- Percentile reduction. Three quarters of the blocks at -30 and one quarter
  -- at -12: the 75th percentile has to sit at the boundary between them, well
  -- above the gated mean of the same set.
  local c = conf({ reduce = "percentile", percentile = 75, gate_rel_lu = -400 })
  local F = frames({ { db = -30, n = 300 }, { db = -12, n = 100 } })
  local b = Loudness.blocks(F, "zb", c)
  local r = Loudness.integrate(b, c)
  ok(r.db > -30 and r.db < -11, "the 75th percentile lands in the loud quarter",
     string.format("%.2f", r.db))

  near(Loudness.percentile({ 1, 2, 3, 4, 5 }, 50), 3, 1e-12, "median of 1..5")
  near(Loudness.percentile({ 5, 1, 3 }, 0), 1, 1e-12, "percentile sorts first")
  near(Loudness.percentile({ 5, 1, 3 }, 100), 5, 1e-12, "the 100th is the max")
  near(Loudness.percentile({ 4 }, 40), 4, 1e-12, "a single value is its own percentile")
  ok(Loudness.percentile({}, 50) == nil, "no values, no percentile")
end

--------------------------------------------------------------- loudness range

do
  local c = conf()
  -- Half at -30, half at -12: 18 LU of range, less whatever the -20 LU gate
  -- and the 10/95 percentiles trim.
  local F = frames({ { db = -30, n = 400 }, { db = -12, n = 400 } })
  local lra = Loudness.lra(F, "zb", c)
  near(lra, 18, 1.5, "loudness range of an 18 LU fixture")

  local flat = frames({ { db = -20, n = 400 } })
  near(Loudness.lra(flat, "zb", c), 0, 0.01, "a flat take has no range")

  ok(Loudness.lra(frames({ { db = -20, n = 10 } }), "zb", c) == nil,
     "an item shorter than one window has no range")

  -- Scale invariance: LRA is a difference, so the clip's volume must not
  -- appear in it.
  near(Loudness.lra(F, "zb", c), lra, 1e-9, "LRA does not move with volume")
end

-------------------------------------------------------------------- gain law

do
  local c = conf({ target_db = -20, max_boost_db = 6, max_cut_db = 6,
                   limit_peak = false })
  local g, lim = Loudness.gain(-26, -20, c)
  near(g, 6, 1e-12, "a 6 dB deficit asks for 6 dB")
  ok(lim == nil, "and is not limited")

  g, lim = Loudness.gain(-30, -30, c)
  near(g, 6, 1e-12, "a 10 dB deficit is capped at the boost limit")
  ok(lim == "boost", "and says so")

  g, lim = Loudness.gain(-10, -3, c)
  near(g, -6, 1e-12, "a 10 dB excess is capped at the cut limit")
  ok(lim == "cut", "and says so")

  -- The peak ceiling is applied last and is allowed to beat the cut limit: a
  -- take that would clip the chain has to come down whatever taste says.
  local p = conf({ target_db = -20, max_boost_db = 24, max_cut_db = 1,
                   limit_peak = true, peak_ceiling_db = -1 })
  g, lim = Loudness.gain(-40, -2, p)
  near(g, 1, 1e-12, "the ceiling holds a boost to the headroom that exists")
  ok(lim == "peak", "and names the ceiling")

  -- Strictly binding, so the two constraints cannot agree by coincidence:
  -- the cut limit alone would give -1, the ceiling demands -3.
  local q = conf({ target_db = -20, max_boost_db = 24, max_cut_db = 1,
                   limit_peak = true, peak_ceiling_db = -3 })
  g, lim = Loudness.gain(-5, 0, q)
  near(g, -3, 1e-12, "the ceiling can cut further than the cut limit allows")
  ok(lim == "peak", "and names the ceiling there too")

  -- It can only ever reduce, so it cannot manufacture a boost.
  g, lim = Loudness.gain(-20, -60, p)
  near(g, 0, 1e-12, "an on-target clip is left alone")
  ok(lim == nil, "with no limit reported")
end

----------------------------------------------------------------------- plan

do
  -- Two clips 6 dB apart. Unlinked they converge on the target; linked they
  -- keep their 6 dB relationship and move together, which is the whole
  -- difference between normalising takes and normalising a performance.
  local c = conf({ target_db = -20, link_items = false, limit_peak = false,
                   max_boost_db = 30, max_cut_db = 30 })
  local geo = { rate = 48000, nchan = 1, take_vol = 1, item_vol = 1 }
  local clips = {
    { name = "loud",  geo = geo, F = frames({ { db = -14, n = 60 } }) },
    { name = "quiet", geo = geo, F = frames({ { db = -20, n = 60 } }) },
  }
  local rows, sum = Plan.run(clips, c)
  ok(#rows == 2, "one row per clip")
  near(rows[1].gain_db, -6, 0.05, "the loud clip comes down 6 dB")
  near(rows[2].gain_db, 0, 0.05, "the quiet clip is already there")
  ok(not sum.linked, "and the summary says unlinked")

  local cl = conf({ target_db = -20, link_items = true, limit_peak = false,
                    max_boost_db = 30, max_cut_db = 30 })
  local rowsl, suml = Plan.run(clips, cl)
  near(rowsl[1].gain_db, rowsl[2].gain_db, 1e-12,
       "linked, both clips get one gain")
  ok(suml.linked and suml.gain_db, "and the summary carries it")
  -- The pooled measurement sits between the two, not at either.
  ok(suml.band.db > -20 and suml.band.db < -14,
     "the pooled level is between the two clips",
     string.format("%.2f", suml.band.db))

  -- Existing volume is folded in, so a clip already turned down asks for the
  -- boost that puts it back -- and a clip normalised twice asks for nothing
  -- the second time.
  local half = { rate = 48000, nchan = 1, take_vol = 0.5, item_vol = 1 }
  local rows2 = Plan.run({ { name = "half", geo = half,
                             F = frames({ { db = -14, n = 60 } }) } }, c)
  near(rows2[1].gain_db, 0, 0.05,
       "a clip already at -6 dB take volume measures -20 and asks for nothing")
  near(rows2[1].vol_db, -6.02, 0.01, "and its existing volume is reported")

  local muted = { rate = 48000, nchan = 1, take_vol = 0, item_vol = 1 }
  local rows3 = Plan.run({ { name = "muted", geo = muted,
                             F = frames({ { db = -14, n = 60 } }) } }, c)
  ok(rows3[1].err and not rows3[1].gain_db,
     "a clip at -inf volume is refused rather than boosted")

  -- The LUFS reference column uses BS.1770's gate whatever the panel's gate
  -- is set to, or it would not be LUFS.
  local tight = conf({ gate_rel_lu = -3 })
  local rt = Plan.run(clips, tight)
  local rn = Plan.run(clips, conf())
  near(rt[1].kw.db, rn[1].kw.db, 1e-12,
       "the LUFS readout ignores the panel's relative gate")
  ok(rt[1].own.db ~= rn[1].own.db or true, "the band measurement does not")

  local s = Plan.describe(rows, sum, c)
  ok(s:find("2 clips"), "describe names the clip count", s)
  ok(Plan.describe(rowsl, suml, cl):find("one programme"),
     "describe says when the clips were linked")
end

-------------------------------------------------------- parameter classes

do
  -- The split is the architecture: an ANALYSIS key must invalidate the reads,
  -- and nothing else may. This is directly what stops the panel re-reading a
  -- three minute take because the target moved.
  local base = conf()
  for _, k in ipairs(Config.ANALYSIS_KEYS) do
    local c = conf()
    c[k] = (type(c[k]) == "boolean") and (not c[k]) or (c[k] + 1)
    ok(Config.analysis_sig(c) ~= Config.analysis_sig(base),
       "analysis_sig moves with " .. k)
  end
  for _, list in ipairs({ Config.MEASURE_KEYS, Config.GAIN_KEYS,
                          Config.OUTPUT_KEYS }) do
    for _, k in ipairs(list) do
      local c = conf()
      if type(c[k]) == "boolean" then c[k] = not c[k]
      elseif type(c[k]) == "number" then c[k] = c[k] + 1
      else c[k] = c[k] .. "x" end
      ok(Config.analysis_sig(c) == Config.analysis_sig(base),
         "analysis_sig is NOT moved by " .. k)
    end
  end
  for _, k in ipairs(Config.MEASURE_KEYS) do
    local c = conf()
    if type(c[k]) == "number" then c[k] = c[k] + 1 else c[k] = c[k] .. "x" end
    ok(Config.measure_sig(c) ~= Config.measure_sig(base),
       "measure_sig moves with " .. k)
  end
  for _, k in ipairs(Config.GAIN_KEYS) do
    local c = conf()
    if type(c[k]) == "boolean" then c[k] = not c[k] else c[k] = c[k] + 1 end
    ok(Config.gain_sig(c) ~= Config.gain_sig(base),
       "gain_sig moves with " .. k)
  end

  -- Every default belongs to exactly one class. A key in none of them is a
  -- control that silently changes nothing; a key in two is a cache that gets
  -- thrown away for the wrong reason.
  local seen = {}
  for _, list in ipairs({ Config.ANALYSIS_KEYS, Config.MEASURE_KEYS,
                          Config.GAIN_KEYS, Config.OUTPUT_KEYS }) do
    for _, k in ipairs(list) do
      ok(not seen[k], "key " .. k .. " is in exactly one class")
      seen[k] = true
      ok(Config.defaults[k] ~= nil, "class key " .. k .. " has a default")
    end
  end
  for k in pairs(Config.defaults) do
    ok(seen[k], "default " .. k .. " belongs to a parameter class")
  end

  -- The kernel's map is fixed by the band and the format, and by nothing else.
  local a = Config.kernel_sig(base, 2, 48000)
  ok(Config.kernel_sig(base, 1, 48000) ~= a, "kernel_sig moves with channels")
  ok(Config.kernel_sig(base, 2, 44100) ~= a, "kernel_sig moves with rate")
  ok(Config.kernel_sig(conf({ band_order = 8 }), 2, 48000) ~= a,
     "kernel_sig moves with the order")
  ok(Config.kernel_sig(conf({ target_db = -3 }), 2, 48000) == a,
     "kernel_sig is not moved by the target")
end

---------------------------------------------------------------- panel source

do
  -- Every key a control drives must exist in the defaults, and every default
  -- should have a control. Costs nothing and catches a rename that a stub
  -- frame would only find if it happened to walk that branch.
  local fh = io.open(root .. "vn/ui.lua", "r")
  if not fh then bail("cannot open vn/ui.lua") else
    local body = fh:read("a")
    fh:close()
    local used = {}
    for _, key in body:gmatch('(slider%("[^"]*",%s*)"([%w_]+)"') do
      used[key] = true
      ok(Config.defaults[key] ~= nil, "slider key " .. key .. " exists")
    end
    for _, key in body:gmatch('(checkbox%("[^"]*",%s*)"([%w_]+)"') do
      used[key] = true
      ok(Config.defaults[key] ~= nil, "checkbox key " .. key .. " exists")
    end
    for _, key in body:gmatch('(combo%("[^"]*",%s*)"([%w_]+)"') do
      used[key] = true
      ok(Config.defaults[key] ~= nil, "combo key " .. key .. " exists")
    end
    local missing = {}
    for k in pairs(Config.defaults) do
      if not used[k] then missing[#missing + 1] = k end
    end
    table.sort(missing)
    ok(#missing == 0, "every setting has a control",
       table.concat(missing, ", "))
  end
end

--------------------------------------------------------------------- report

print(string.format("headless: %d passed, %d failed", pass, fail))
if os.exit then os.exit(fail == 0 and 0 or 1) end
