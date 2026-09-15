-- AutoTilt -- the whole pipeline, on a fixture this suite builds itself.
--
-- Accessor -> cube -> measure -> solve -> render -> WAV -> take, and then the
-- result read back through the accessor and measured again. The assertion that
-- matters is the last one: after applying, the target's balance has to equal
-- the reference's. Every stage in between can be individually plausible and
-- still add up to nothing, and this is the only suite that would notice.
--
-- Two cases, every run: playrate 1.0 and playrate 1.25. At playrate 1 every
-- quantity in the take geometry is the same number, so every scaling mistake
-- passes -- the stretched case is the one that can fail. The fixture is built
-- on temporary tracks and deleted afterwards with the item selection restored,
-- so the suite needs no selection and cannot silently skip anything.

local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
local script_dir = src_path:match("^(.*[/\\])"):gsub("test[/\\]$", "")

local out, pass, fail = {}, 0, 0
local function say(s) out[#out + 1] = s end
local function section(s) say("-- " .. s) end

local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    say("  ok    " .. name)
  else
    fail = fail + 1
    say("  FAIL  " .. name .. (extra and ("  -- " .. extra) or ""))
  end
end

local function near(a, b, tol, name)
  ok(a and math.abs(a - b) <= tol, name,
     string.format("%s vs %s (tol %s)", tostring(a), tostring(b), tostring(tol)))
end

local cleanup = {}
local function report()
  for i = #cleanup, 1, -1 do pcall(cleanup[i]) end
  say(string.format("\nverify: %d passed, %d failed", pass, fail))
  reaper.ShowConsoleMsg(table.concat(out, "\n") .. "\n")
  if os.exit then os.exit(fail == 0 and 0 or 1) end
end

local function bail(msg)
  fail = fail + 1
  say("  FAIL  " .. msg)
  report()
end

if not reaper.ImGui_GetBuiltinPath then bail("ReaImGui is not installed") return end
package.path = script_dir .. "?.lua;" .. script_dir .. "test/?.lua;"
            .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui    = require "imgui" "0.9"
local Config   = require "at.config"
local Select   = require "at.select"
local Kernel   = require "at.kernel"
local Analyze  = require "at.analyze"
local Spectrum = require "at.spectrum"
local Solve    = require "at.solve"
local Render   = require "at.render"
local Apply    = require "at.apply"
local Wav      = require "at.wav"

local RATE, SECS, AMP = 48000, 5.0, 0.25
local PRE_TILT = -4.0            -- the target is the reference, tilted by this

local ctx = ImGui.CreateContext("AutoTilt verify")

------------------------------------------------------------------- fixture ----

local sep = package.config:sub(1, 1)
local tmpdir = (os.getenv("TMPDIR") or "/tmp") .. sep .. "autotilt-verify"
os.execute('mkdir -p "' .. tmpdir .. '"')

-- Deterministic white noise: the same file every run, so a failure is
-- reproducible rather than a coin flip.
local function noise_gen(seed)
  local s = seed
  return function()
    s = (1103515245 * s + 12345) % 2147483648
    return (s / 1073741824 - 1) * AMP
  end
end

-- Transposed direct form II, matching the kernel's arithmetic, so the fixture
-- is tilted by exactly the curve the solver is going to be asked to undo.
local function biquad(c)
  local z1, z2 = 0, 0
  return function(x)
    local y = c[1] * x + z1
    z1 = c[2] * x - c[4] * y + z2
    z2 = c[3] * x - c[5] * y
    return y
  end
end

local function write_wav(path, nsamp, gen)
  local w, err = Wav.create(path, 1, RATE)
  if not w then return nil, err end
  local CH = 4096
  local done = 0
  while done < nsamp do
    local n = math.min(CH, nsamp - done)
    local t = {}
    for i = 1, n do t[i] = gen() end
    w:write(t, 1, n)
    done = done + n
  end
  w:close()
  return true
end

local nsamp = math.floor(RATE * SECS)
local ref_path = tmpdir .. sep .. "autotilt-ref.wav"
local tgt_path = tmpdir .. sep .. "autotilt-tgt.wav"

do
  local okw, werr = write_wav(ref_path, nsamp, noise_gen(20260831))
  if not okw then bail("could not write the reference fixture: " .. tostring(werr)) return end

  -- The same noise, pre-tilted by a known amount through the real shelf pair.
  local tcfg = Config.new()
  local lo, hi = Solve.pair(tcfg, RATE, PRE_TILT)
  local f1, f2 = biquad(lo), biquad(hi)
  local g = noise_gen(20260831)
  local okw2, werr2 = write_wav(tgt_path, nsamp, function() return f2(f1(g())) end)
  if not okw2 then bail("could not write the target fixture: " .. tostring(werr2)) return end
end
cleanup[#cleanup + 1] = function()
  os.remove(ref_path)
  os.remove(tgt_path)
end

-- Save the user's selection before touching anything.
do
  local saved = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    saved[#saved + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  cleanup[#cleanup + 1] = function()
    reaper.SelectAllMediaItems(0, false)
    for _, it in ipairs(saved) do
      pcall(reaper.SetMediaItemSelected, it, true)
    end
    reaper.UpdateArrange()
  end
end

local function add_clip(track_idx, path, playrate)
  reaper.InsertTrackAtIndex(track_idx, false)
  local tr = reaper.GetTrack(0, track_idx)
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  local src = reaper.PCM_Source_CreateFromFile(path)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 12.5)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", SECS / playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
  reaper.SetMediaItemSelected(item, true)
  return tr, item, take
end

-- Read a whole take through the accessor, on the main thread.
local function read_take(take, rate, nchan)
  local geo = Analyze.geometry(take)
  local total = math.floor(geo.item_len * rate + 0.5)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local buf = reaper.new_array(8192 * nchan)
  local all, done = {}, 0
  while done < total do
    local n = math.min(8192, total - done)
    buf.clear(0)
    local got = reaper.GetAudioAccessorSamples(aa, rate, nchan, done / rate, n, buf)
    if got == nil then reaper.DestroyAudioAccessor(aa) return nil end
    local t = buf.table(1, n * nchan)
    for i = 1, n * nchan do all[done * nchan + i] = t[i] end
    done = done + n
  end
  reaper.DestroyAudioAccessor(aa)
  return all
end

-- Our own 32-bit float WAV, read straight back as numbers.
local function read_wav_f32(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local data = fh:read("a")
  fh:close()
  local pos = data:find("data", 13, true)
  if not pos then return nil end
  local n = string.unpack("<I4", data, pos + 4)
  local base = pos + 8
  local t = {}
  for i = 1, n // 4 do
    t[i] = string.unpack("<f", data, base + (i - 1) * 4)
  end
  return t
end

--------------------------------------------------------------------- a case ----

local function run_case(playrate)
  section(string.format("playrate %.2f", playrate))

  reaper.SelectAllMediaItems(0, false)
  local rtr, ritem, rtake = add_clip(0, ref_path, playrate)   -- track 1: reference
  local ttr, titem, ttake = add_clip(1, tgt_path, playrate)   -- track 2: target
  local made = { rtr, ttr }
  local written = {}
  local function drop()
    for _, tr in ipairs(made) do pcall(reaper.DeleteTrack, tr) end
    for _, p in ipairs(written) do os.remove(p) end
    reaper.UpdateArrange()
  end
  cleanup[#cleanup + 1] = drop

  local cfg = Config.new()
  cfg.fft_size, cfg.ana_hop = 2048, 512

  local sel = Select.resolve(cfg)
  ok(not sel.err, "the selection resolves", sel.err)
  if sel.err then drop() return end
  ok(#sel.target == 1 and sel.target[1].take == ttake,
     "the target is the clip on the higher-numbered track")
  ok(#sel.refs == 1 and sel.refs[1].take == rtake,
     "and the reference is the one on the lower")

  local geo = Analyze.geometry(ttake)
  near(geo.rate, RATE, 0, "the source rate is read correctly")
  ok(geo.rate_known, "and it did not have to be guessed")
  near(geo.item_len, SECS / playrate, 0.01, "the item length is the stretched span")

  local k, kerr = Kernel.build(ImGui, ctx, script_dir, geo.nchan, cfg)
  if not k then ok(false, "the kernel builds", kerr) drop() return end
  k:set_hop(Config.hop(cfg))

  local res, aerr = Analyze.drive(function()
    return Analyze.run(sel, cfg, k, geo)
  end)
  ok(res ~= nil, "analysis completes", aerr)
  if not res then drop() return end

  -- The canary. A job that read its own audio from inside a coroutine would
  -- get silence and every frame would bucket at the floor -- which looks
  -- exactly like a working analysis of an empty file.
  ok(res.target.lev_max ~= nil and
     Spectrum.level_db(res.target, res.target.lev_max) > -60,
     "analysis saw audio, not silence",
     res.target.lev_max and
       string.format("loudest bucket %.0f dBFS",
                     Spectrum.level_db(res.target, res.target.lev_max)) or "none")

  local mt = Spectrum.measure(res.target, cfg, geo.rate, k.fft_size)
  local mr = Spectrum.measure(res.ref, cfg, geo.rate, k.fft_size)
  ok(mt.ratio and mr.ratio, "both clips measure", mt.err or mr.err)
  if not (mt.ratio and mr.ratio) then drop() return end
  say(string.format("        reference %+.2f dB, target %+.2f dB, difference %+.2f dB",
      mr.ratio, mt.ratio, mr.ratio - mt.ratio))

  local sv = Solve.solve(mt.spec, cfg, geo.rate, mt.band, mr.ratio)
  ok(not sv.clamped, "the solve is inside the limit")
  say(string.format("        solved %+.3f dB (fixture was pre-tilted %+.1f dB)",
      sv.gain or 0 / 0, PRE_TILT))

  -- At playrate 1 the fixture's shelf corner is still at the pivot, so the
  -- solved gain has to be the exact negation of the pre-tilt. Stretched, the
  -- corner has moved with the audio and only the balance can be asserted.
  if playrate == 1.0 then
    near(sv.gain, -PRE_TILT, 0.15, "the solved gain undoes the pre-tilt")
  end

  --------------------------------------------------------------- the render --
  local claimed = {}
  local path = Render.output_path(ttake, cfg, claimed)
  written[#written + 1] = path
  local plan = Solve.plan(mt.spec, cfg, geo.rate, sv.gain, k.fft_size, geo.rate)
  local rres, rerr = Analyze.drive(function()
    return Render.run(ttake, cfg, k, plan, path, 0, 1)
  end)
  ok(rres ~= nil, "the render completes", rerr)
  if not rres then drop() return end
  near(rres.samples, math.floor(geo.item_len * geo.rate + 0.5), 1,
       "the file covers exactly the span the item uses")
  near(rres.rate, RATE, 0, "and is written at the source rate")

  local added, apperr = Apply.run(
    { { item = titem, take = ttake, result = rres } }, cfg, sv.gain)
  ok(added == 1, "apply adds one take", apperr)
  if added ~= 1 then drop() return end

  local nt = reaper.GetActiveTake(titem)
  ok(nt ~= ttake, "and it is a new take, the original kept")

  ------------------------------------------------------------- take geometry --
  near(reaper.GetMediaItemTakeInfo_Value(nt, "D_STARTOFFS"), 0, 0,
       "the new take starts at offset 0")
  near(reaper.GetMediaItemTakeInfo_Value(nt, "D_PLAYRATE"), 1, 0,
       "its playrate is neutral -- the accessor already applied the stretch")
  near(reaper.GetMediaItemTakeInfo_Value(nt, "D_PITCH"), 0, 0, "its pitch is neutral")
  near(reaper.GetMediaItemTakeInfo_Value(nt, "I_CHANMODE"), 0, 0,
       "its channel mode is neutral")
  near(reaper.GetMediaItemInfo_Value(titem, "D_LENGTH"), SECS / playrate, 0.01,
       "and the item did not change length")

  -- A rendered file gets no waveform unless its peaks are built, and the take
  -- plays back perfectly either way -- so nothing but this notices.
  local pbuf = reaper.new_array(64 * 2)
  pbuf.clear(0)
  local pret = reaper.PCM_Source_GetPeaks(
    reaper.GetMediaItemTake_Source(nt), 8, 0, 1, 64, 0, pbuf)
  local pn = pret & 0xFFFFF
  ok(pn > 0, "peaks were built for the new source", "got " .. tostring(pn))
  local pt, nonzero = pbuf.table(1, 64), false
  for i = 1, 64 do if pt[i] ~= 0 then nonzero = true break end end
  ok(nonzero, "and they are not all zero")

  ----------------------------------------------------- the end-to-end check --
  -- Re-read the take that was just written and measure it the same way. This
  -- is the only assertion that covers the whole chain at once.
  local sel2 = { target = { { item = titem, take = nt } }, refs = {} }
  local geo2 = Analyze.geometry(nt)
  local k2 = Kernel.build(ImGui, ctx, script_dir, geo2.nchan, cfg)
  k2:set_hop(Config.hop(cfg))
  local res2 = Analyze.drive(function()
    return Analyze.run(sel2, cfg, k2, geo)
  end)
  ok(res2 ~= nil, "the applied take can be analysed again")
  if res2 then
    local m2 = Spectrum.measure(res2.target, cfg, geo.rate, k2.fft_size)
    say(string.format("        after the tilt: %+.2f dB (reference %+.2f dB)",
        m2.ratio or 0 / 0, mr.ratio))
    near(m2.ratio, mr.ratio, 0.3,
         "THE POINT: after applying, the target's balance matches the reference")
  end
  pcall(ImGui.Detach, ctx, k2.func)

  ------------------------------------------------------------------ the null --
  -- A zero-gain render has to come back sample for sample. The shelf pair has
  -- no bulk delay, so this is an exact null at shift 0 rather than a search.
  local zpath = Render.output_path(ttake, cfg, claimed)
  written[#written + 1] = zpath
  local zplan = Solve.plan(mt.spec, cfg, geo.rate, 0, k.fft_size, geo.rate)
  zplan.makeup = 1
  local zres = Analyze.drive(function()
    return Render.run(ttake, cfg, k, zplan, zpath, 0, 1)
  end)
  ok(zres ~= nil, "a zero-gain render completes")
  if zres then
    local a = read_take(ttake, geo.rate, geo.nchan)
    local b = read_wav_f32(zpath)
    ok(a and b, "both sides of the null could be read")
    if a and b then
      local n = math.min(#a, #b)
      local function nulldb(shift)
        local s, c = 0, 0
        for i = 1 + math.max(0, -shift), n - math.max(0, shift) do
          local d = a[i] - b[i + shift]
          s = s + d * d
          c = c + 1
        end
        return 10 * math.log(math.max(s / c, 1e-30), 10)
      end
      local at0, atm1, atp1 = nulldb(0), nulldb(-1), nulldb(1)
      say(string.format("        null: %.1f dB at shift 0, %.1f / %.1f at -1 / +1",
          at0, atm1, atp1))
      ok(at0 < -80, "a zero-gain render nulls against the source", string.format("%.1f dB", at0))
      ok(at0 < atm1 - 20 and at0 < atp1 - 20,
         "and it nulls at shift 0, not one sample either side")
    end
  end

  pcall(ImGui.Detach, ctx, k.func)
  drop()
end

run_case(1.0)
run_case(1.25)

report()
