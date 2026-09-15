-- Note Leveling -- pure-Lua suite.
--
-- Covers the stages that hold the algorithm and no REAPER: clustering pitch
-- frames into notes, turning notes into gains and envelope points, mixing
-- reference clips onto the target's grid, and the rider's segmentation, gain
-- law and curve.
-- Runs under REAPER's embedded Lua via reascript_test.py (there is no system
-- lua on this machine) and equally from the Actions list.

local src = debug.getinfo(1, "S").source:match("^@(.+)$")
local dir = src:match("^(.*[/\\])") or "./"
local root = dir:gsub("test[/\\]$", "")
package.path = root .. "?.lua;" .. package.path

local Config    = require "nl.config"
local Cluster   = require "nl.cluster"
local Level     = require "nl.level"
local Kernel    = require "nl.kernel"
local Reference = require "nl.reference"
local Rider     = require "nl.rider"
local Octave    = require "nl.octave"

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
     string.format("%s vs %s", tostring(a), tostring(b)))
end

-- Anything that stops the run counts as a failure, not as "nothing to check".
local function bail(msg)
  fail = fail + 1
  print("FAIL  " .. msg)
end

------------------------------------------------------------------ fixtures

local A4, As4, C5 = 440.0, 466.164, 523.251

-- Build a frame table from a list of { hz = <or nil for unvoiced>, n, db }.
local function build(segs, hop_ms)
  hop_ms = hop_ms or 5
  local F = { hop_s = hop_ms / 1000, n = 0, item_pos = 0,
              ms = {}, level_db = {}, bp_ms = {}, bp_db = {},
              f0 = {}, aper = {} }
  for _, s in ipairs(segs) do
    local dbv = s.db or -12
    for _ = 1, s.n do
      local i = F.n + 1
      F.n = i
      F.ms[i] = 10 ^ (dbv / 10)
      F.level_db[i] = dbv
      F.f0[i] = s.hz or 0
      F.aper[i] = s.hz and 0.05 or 0.90
      -- The band-passed track is what the rider measures. For a synthetic
      -- fixture there is no band to speak of, so it is the same number.
      F.bp_ms[i] = F.ms[i]
      F.bp_db[i] = dbv
    end
  end
  F.span = F.n * F.hop_s
  return F
end

local function conf(over)
  local c = Config.new()
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

------------------------------------------------------------------ labelling

do
  local c = conf()
  ok(Cluster.label(440, 100) == 69, "A440 labels as MIDI 69")
  ok(Cluster.label(261.626, 100) == 60, "middle C labels as MIDI 60")
  ok(Cluster.label(0, 100) == nil, "silence has no label")
  ok(Cluster.label(30, 100) == nil, "below C2 has no label")
  ok(Cluster.label(3000, 100) == nil, "above G6 has no label")
  -- 40 cents sharp of A4 is inside a 50 cent tolerance and outside a 30 cent one
  local sharp = 440 * 2 ^ (40 / 1200)
  ok(Cluster.label(sharp, 50) == 69, "40 cents sharp passes a 50 cent tolerance")
  ok(Cluster.label(sharp, 30) == nil, "40 cents sharp fails a 30 cent tolerance")
  near(Cluster.cents(sharp, 440), 40, 0.001, "cents round-trips")
  ok(Cluster.note_name(69) == "A4", "MIDI 69 is A4")
  ok(Cluster.note_name(60) == "C4", "MIDI 60 is C4")
  ok(c.hop_ms == 5, "default sampling distance is 5 ms")
end

------------------------------------------------------------------ clustering

do
  local c = conf()
  local F = build({ { hz = A4, n = 40 }, { hz = As4, n = 12 }, { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 1, "a 60 ms excursion that returns is absorbed as wobble",
     "got " .. #notes)
  if notes[1] then
    ok(notes[1].midi == 69, "and the note keeps its original label")
    near(notes[1].dur_ms, 92 * 5, 0.01, "spanning every frame it absorbed")
  end
end

do
  local c = conf()
  local F = build({ { hz = A4, n = 40 }, { hz = As4, n = 60 }, { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 3, "a 300 ms excursion is a real note change", "got " .. #notes)
end

do
  local c = conf()
  -- Unvoiced but loud: a consonant, not a pause.
  local F = build({ { hz = A4, n = 40 }, { n = 20, db = -12 }, { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 1, "a short loud gap between same-note clusters bridges",
     "got " .. #notes)
end

do
  local c = conf()
  local F = build({ { hz = A4, n = 40 }, { n = 20, db = -60 }, { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 2, "the same gap does not bridge when it is silent",
     "got " .. #notes)
end

do
  local c = conf()
  local F = build({ { hz = A4, n = 40 }, { n = 120, db = -12 }, { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 2, "a 605 ms gap is past max_gap_ms and does not bridge",
     "got " .. #notes)
end

do
  local c = conf()
  local F = build({ { hz = A4, n = 40 }, { n = 10, db = -60 },
                    { hz = C5, n = 10 }, { n = 10, db = -60 },
                    { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 2, "a 50 ms cluster is dropped", "got " .. #notes)
  if #notes == 2 then
    ok(notes[1].midi == 69 and notes[2].midi == 69,
       "and leaves a hole rather than merging into a neighbour")
    ok(notes[2].t0 - notes[1].t1 > 0.1, "the hole is the whole excursion")
  end
end

do
  -- A glide: every intermediate semitone is too short to survive, so the two
  -- stable ends come out as notes with a gap between them.
  local c = conf()
  local segs = { { hz = A4, n = 60 } }
  for m = 70, 74 do
    segs[#segs + 1] = { hz = Cluster.midi_hz(m), n = 8 }
  end
  segs[#segs + 1] = { hz = Cluster.midi_hz(75), n = 60 }
  local notes = Cluster.run(build(segs), c)
  ok(#notes == 2, "a portamento comes out as two notes, not a staircase",
     "got " .. #notes)
end

do
  local c = conf()
  local F = build({ { hz = A4, n = 60, db = -6 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 1, "one steady note")
  if notes[1] then
    near(notes[1].rms_db, -6, 0.001, "its RMS is the level of its frames")
    near(notes[1].mean_freq, A4, 0.001, "its pitch is the mean of its frames")
    near(notes[1].t0, 0, 1e-9, "starting at the first frame")
    near(notes[1].t1, 0.3, 1e-9, "and ending at the end of the last")
  end
end

do
  -- The voice gate, not the aperiodicity, is what rejects a quiet periodic
  -- tail. Same pitch, 30 dB down.
  local c = conf({ voice_gate_db = -50 })
  local quiet = Cluster.run(build({ { hz = A4, n = 60, db = -70 } }), c)
  ok(#quiet == 0, "a note under the voice gate is not a note", "got " .. #quiet)
  local loud = Cluster.run(build({ { hz = A4, n = 60, db = -40 } }), c)
  ok(#loud == 1, "the same note above the gate is", "got " .. #loud)
end

do
  -- wobble_ms = 0 disables absorption entirely.
  local c = conf({ wobble_ms = 0 })
  local F = build({ { hz = A4, n = 40 }, { hz = As4, n = 12 }, { hz = A4, n = 40 } })
  local notes = Cluster.run(F, c)
  ok(#notes == 2, "with wobble off the excursion splits the note and is dropped",
     "got " .. #notes)
end

---------------------------------------------------------------------- gains

do
  -- Limits wide open, so this block tests the proportional maths alone.
  local c = conf({ floor_db = -30, ceiling_db = -7, amount = 100,
                   max_boost_db = 24, max_cut_db = 24 })
  near(Level.gain_db(-6, c), -1.0, 1e-9,
       "-6 dB against a -7 dB ceiling at 100% is -1.0 dB")
  c.amount = 50
  near(Level.gain_db(-6, c), -0.5, 1e-9, "...and -0.5 dB at 50%")
  c.amount = 0
  near(Level.gain_db(-6, c), 0, 1e-9, "...and nothing at 0%")

  c.amount = 100
  near(Level.gain_db(-12, c), 0, 1e-9, "a note inside the window is untouched")
  near(Level.gain_db(-7, c), 0, 1e-9, "a note exactly on the ceiling too")
  near(Level.gain_db(-30, c), 0, 1e-9, "a note exactly on the floor too")
  near(Level.gain_db(-40, c), 10, 1e-9, "a note under the floor is raised")
  c.amount = 25
  near(Level.gain_db(-40, c), 2.5, 1e-9, "...proportionally")
end

do
  -- The limits bound the move, and they bound it AFTER the amount has scaled
  -- it -- so "amount" reads as how much of the correction you want and the
  -- limits as the most any one note may move.
  local c = conf({ floor_db = -30, ceiling_db = -7, amount = 100,
                   max_boost_db = 6, max_cut_db = 3 })
  near(Level.gain_db(-40, c), 6, 1e-9, "a boost is capped at max_boost_db")
  near(Level.gain_db(-1, c), -3, 1e-9, "a cut is capped at max_cut_db")
  near(Level.gain_db(-33, c), 3, 1e-9, "a boost inside the cap is untouched")
  near(Level.gain_db(-5.5, c), -1.5, 1e-9, "a cut inside the cap is untouched")

  c.amount = 25
  near(Level.gain_db(-40, c), 2.5, 1e-9, "the amount is applied before the cap")

  c.amount = 100
  c.max_boost_db = 0
  near(Level.gain_db(-40, c), 0, 1e-9, "a zero limit freezes that direction")
  near(Level.gain_db(-1, c), -3, 1e-9, "and leaves the other one alone")

  -- The flag is set where the clamp happens, so a gain that lands exactly on
  -- the limit by chance is not reported as clamped.
  c.max_boost_db = 6
  local notes = Level.gains({ { rms_db = -40 }, { rms_db = -33 },
                              { rms_db = -12 } }, c)
  ok(Level.is_clamped(notes[1]), "a capped note reports as clamped")
  ok(not Level.is_clamped(notes[2]), "a note inside the limits does not")
  ok(not Level.is_clamped(notes[3]), "and neither does an untouched one")
  near(notes[2].gain_db, 3, 1e-9, "the uncapped note kept its full move")
end

------------------------------------------------------------------- envelope

local function monotone(pts)
  for i = 2, #pts do
    if pts[i].t <= pts[i - 1].t then return false, i end
  end
  return true
end

do
  local c = conf({ ramp_in_ms = 30, ramp_out_ms = 60, ramp_res_ms = 10 })
  local notes = {
    { t0 = 1.0, t1 = 1.5, gain_db = -2 },
    { t0 = 2.0, t1 = 2.5, gain_db = 3 },
  }
  local pts = Level.envelope(notes, c, 4.0)
  ok(#pts > 0, "a long gap produces points")
  ok(monotone(pts), "envelope times strictly increase")
  near(pts[1].db, 0, 1e-9, "the first point is unity gain")
  near(pts[#pts].db, 0, 1e-9, "so is the last")
  near(pts[#pts].t, 4.0, 1e-9, "and it reaches the end of the source")
  near(Level.value_at(pts, 1.25), -2, 1e-9, "the first note sits at its gain")
  near(Level.value_at(pts, 2.25), 3, 1e-9, "the second at its own")
  near(Level.value_at(pts, 1.75), 0, 1e-9,
       "and the middle of a long gap rests at unity")
  near(Level.value_at(pts, 1.53), -1.0, 1e-9,
       "halfway down the ramp out is half the gain")
  near(Level.value_at(pts, 1.56), 0, 1e-9,
       "reaching unity exactly ramp_out after the note")
  near(Level.value_at(pts, 1.97), 0, 1e-9,
       "and leaving it exactly ramp_in before the next")
end

do
  local c = conf({ ramp_in_ms = 30, ramp_out_ms = 60, ramp_res_ms = 10 })
  local notes = {
    { t0 = 1.0, t1 = 1.5, gain_db = -2 },
    { t0 = 1.52, t1 = 2.0, gain_db = -4 },
  }
  local pts = Level.envelope(notes, c, 3.0)
  ok(monotone(pts), "a short gap still gives strictly increasing times")
  local dipped = false
  for _, p in ipairs(pts) do
    if p.t > 1.5 and p.t < 1.52 and math.abs(p.db) < 1.9 then dipped = true end
  end
  ok(not dipped, "a gap shorter than the ramps does not dip toward unity")
  local mid = Level.value_at(pts, 1.51)
  ok(mid < -2 and mid > -4, "it transitions straight between the two gains",
     tostring(mid))
end

do
  -- Two notes butted together with no gap at all. The transition has to happen
  -- in finite time or the envelope steps, which clicks.
  local c = conf({ ramp_in_ms = 0, ramp_out_ms = 0, ramp_res_ms = 1 })
  local notes = {
    { t0 = 1.0, t1 = 1.5, gain_db = -6 },
    { t0 = 1.5, t1 = 2.0, gain_db = 0 },
  }
  local pts = Level.envelope(notes, c, 3.0)
  ok(monotone(pts), "a zero-length gap still gives strictly increasing times")
  local a = Level.value_at(pts, 1.5 - Level.MIN_TRANS)
  local b = Level.value_at(pts, 1.5 + Level.MIN_TRANS)
  near(a, -6, 0.01, "the first note holds right up to the crossfade")
  near(b, 0, 0.01, "and the second has arrived just after it")
  near(Level.value_at(pts, 1.5), -3, 0.6, "with the boundary halfway across")
end

do
  -- The ramp is linear in dB, which is the whole reason it is subdivided.
  local c = conf({ ramp_in_ms = 100, ramp_out_ms = 100, ramp_res_ms = 10 })
  local notes = { { t0 = 1.0, t1 = 2.0, gain_db = -6 } }
  local pts = Level.envelope(notes, c, 3.0)
  near(Level.value_at(pts, 0.95), -3, 1e-9, "halfway up the ramp is half the dB")
  near(Level.value_at(pts, 0.975), -4.5, 1e-9, "three quarters up, likewise")
  near(Level.value_at(pts, 2.05), -3, 1e-9, "and the same coming down")
  ok(#pts >= 20, "the ramp is subdivided, not left as two points", "#" .. #pts)
end

do
  -- Glide mode. The complaint it answers: two adjacent notes both cut, and the
  -- breath between them left at unity -- i.e. the loudest thing in the phrase.
  local c = conf({ ramp_in_ms = 30, ramp_out_ms = 60, ramp_res_ms = 10,
                   glide_notes = true })
  local notes = {
    { t0 = 1.0, t1 = 1.5, gain_db = -4 },
    { t0 = 2.0, t1 = 2.5, gain_db = -6 },
  }
  local pts = Level.envelope(notes, c, 4.0)
  ok(monotone(pts), "glide times strictly increase")
  near(Level.value_at(pts, 1.25), -4, 1e-9, "the first note sits at its gain")
  near(Level.value_at(pts, 2.25), -6, 1e-9, "the second at its own")
  near(Level.value_at(pts, 1.75), -5, 1e-9,
       "and the middle of the gap is halfway between them, not unity")
  near(Level.value_at(pts, 1.6), -4.4, 1e-9,
       "the transition is linear in dB across the whole gap")
  near(Level.value_at(pts, 0.2), -4, 1e-9,
       "the first note's gain reaches back to the start of the clip")
  near(Level.value_at(pts, 3.9), -6, 1e-9,
       "and the last note's holds to the end")
  near(pts[1].t, 0, 1e-9, "the envelope starts at the clip start")
  near(pts[#pts].t, 4.0, 1e-9, "and ends at the clip end")
  local unity = false
  for _, p in ipairs(pts) do
    if math.abs(p.db) < 1e-9 then unity = true end
  end
  ok(not unity, "no point anywhere returns to unity")
end

do
  -- Two notes butted together in glide mode: still a finite transition, not a
  -- vertical step.
  local c = conf({ ramp_res_ms = 1, glide_notes = true })
  local notes = {
    { t0 = 1.0, t1 = 1.5, gain_db = -6 },
    { t0 = 1.5, t1 = 2.0, gain_db = 0 },
  }
  local pts = Level.envelope(notes, c, 3.0)
  ok(monotone(pts), "a zero-length gap glides with increasing times")
  near(Level.value_at(pts, 1.5 - Level.MIN_TRANS), -6, 0.01,
       "the first note holds right up to the crossfade")
  near(Level.value_at(pts, 1.5 + Level.MIN_TRANS), 0, 0.01,
       "and the second has arrived just after it")
end

do
  -- A flat gap is two points, not one every `res`. Glide mode's gaps are as
  -- long as the arrangement allows, so this is what keeps an instrumental
  -- section between two uncorrected notes from costing thousands of points.
  local c = conf({ ramp_res_ms = 10, glide_notes = true })
  local notes = {
    { t0 = 1.0, t1 = 2.0, gain_db = -3 },
    { t0 = 32.0, t1 = 33.0, gain_db = -3 },
  }
  local pts = Level.envelope(notes, c, 34.0)
  ok(#pts <= 8, "a flat 30 s gap is not subdivided", "#" .. #pts)
  near(Level.value_at(pts, 17.0), -3, 1e-9, "and holds the gain across it")
end

do
  local c = conf({ glide_notes = true })
  ok(#Level.envelope({}, c, 3.0) == 0, "no notes produces no points in glide")
end

do
  local c = conf()
  ok(#Level.envelope({}, c, 3.0) == 0, "no notes produces no points")
end

do
  -- A note that starts at time zero has no room in front of it for a ramp.
  local c = conf({ ramp_in_ms = 100, ramp_out_ms = 100 })
  local notes = { { t0 = 0, t1 = 1.0, gain_db = -6 } }
  local pts = Level.envelope(notes, c, 2.0)
  ok(monotone(pts), "a note at time zero still gives increasing times")
  near(Level.value_at(pts, 0.5), -6, 1e-9, "and reaches its gain")
end

-------------------------------------------------------------- panel coverage

do
  -- Every tunable needs a control, or it is a setting nobody can reach. This
  -- greps the panel source rather than driving it, which is crude but catches
  -- the case that actually happens: a key renamed in one file and not the
  -- other.
  local fh = io.open(root .. "nl/ui.lua", "rb")
  if not fh then
    bail("cannot open nl/ui.lua to check panel coverage")
  else
    local usrc = fh:read("a")
    fh:close()
    local hidden = {}
    for k in pairs(Config.defaults) do
      if not usrc:find('"' .. k .. '"', 1, true) then
        hidden[#hidden + 1] = k
      end
    end
    table.sort(hidden)
    ok(#hidden == 0, "every default has a panel control",
       table.concat(hidden, ", "))
  end
end

do
  local c = Config.new()
  local seen = {}
  for _, list in ipairs({ Config.ANALYSIS_KEYS, Config.CLUSTER_KEYS,
                          Config.LEVEL_KEYS, Config.OUTPUT_KEYS,
                          Config.RIDER_KEYS }) do
    for _, k in ipairs(list) do
      ok(c[k] ~= nil, "parameter class key " .. k .. " exists")
      ok(not seen[k], "parameter class key " .. k .. " is in exactly one class")
      seen[k] = true
    end
  end
  local missing = {}
  for k in pairs(Config.defaults) do
    if not seen[k] then missing[#missing + 1] = k end
  end
  table.sort(missing)
  ok(#missing == 0, "every default belongs to a parameter class",
     table.concat(missing, ", "))
end


------------------------------------------------------ the vocal band filters

do
  -- Magnitude of a biquad at frequency f, straight from the transfer function.
  -- The point is not to re-derive RBJ but to prove the coefficients that reach
  -- the kernel describe the filter the rider's design assumes: a band that
  -- rejects the kick and keeps the voice.
  local function mag(co, f, rate)
    local w = 2 * math.pi * f / rate
    local function z(k) return math.cos(-k * w), math.sin(-k * w) end
    local c1, s1 = z(1)
    local c2, s2 = z(2)
    local nr = co[1] + co[2] * c1 + co[3] * c2
    local ni =         co[2] * s1 + co[3] * s2
    local dr = 1      + co[4] * c1 + co[5] * c2
    local di =         co[4] * s1 + co[5] * s2
    return math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
  end

  local rate = 48000
  local hp = Kernel.rbj("hp", Kernel.BAND_LO_HZ, rate)
  local lp = Kernel.rbj("lp", Kernel.BAND_HI_HZ, rate)

  local function band_db(f)
    return 20 * math.log(mag(hp, f, rate) * mag(lp, f, rate), 10)
  end

  near(band_db(1000), 0, 0.5, "the vocal band passes 1 kHz flat")
  near(band_db(Kernel.BAND_LO_HZ), -3, 0.6, "the band is -3 dB at its low corner")
  near(band_db(Kernel.BAND_HI_HZ), -3, 0.6, "the band is -3 dB at its high corner")
  ok(band_db(50) < -28, "the band rejects 50 Hz",
     string.format("%.1f dB", band_db(50)))
  ok(band_db(16000) < -20, "the band rejects 16 kHz",
     string.format("%.1f dB", band_db(16000)))
  -- 12 dB/octave each side: an octave below the corner must be ~12 dB down on
  -- the corner itself. A single band-pass biquad across this span could not do
  -- it, which is why there are two.
  ok(band_db(Kernel.BAND_LO_HZ / 4) < band_db(Kernel.BAND_LO_HZ) - 20,
     "the low side is second order")
end

--------------------------------------------------------- mixing the reference

-- One reference clip: n frames of constant mean square, at a project position.
local function ref_clip(ms, n, pos, hop_ms)
  local R = { n = n, hop_s = (hop_ms or 5) / 1000, item_pos = pos or 0,
              bp_ms = {} }
  for i = 1, n do R.bp_ms[i] = ms end
  return R
end

do
  local target = { n = 200, hop_s = 0.005, item_pos = 0 }

  -- Two equal sources sum in POWER: +3 dB, not +0 and not +6.
  local one = Reference.mix({ ref_clip(1e-2, 200, 0) }, target)
  local two = Reference.mix({ ref_clip(1e-2, 200, 0),
                              ref_clip(1e-2, 200, 0) }, target)
  near(one.db[1], -20, 0.001, "one reference at -20 dB reads -20")
  near(two.db[1], -20 + 3.0103, 0.001, "two equal references sum to +3 dB")
  ok(two.nrefs == 2, "the mix counts its sources")

  -- A reference that starts half a second later lands half a second later on
  -- the target's grid: 0.5 s at a 5 ms hop is 100 frames.
  local late = Reference.mix({ ref_clip(1e-2, 100, 0.5) }, target)
  ok(not late.covered[100], "before a late reference starts, nothing is covered")
  ok(late.covered[101], "a reference 0.5 s late begins at frame 101")
  ok(late.covered[200], "and runs to the end of its own length")
  near(late.db[101], -20, 0.001, "the late reference carries its level")

  -- Rounding, not truncation: a shift of 2.6 frames goes to 3, so the
  -- reference is never systematically early or late.
  local odd = Reference.mix({ ref_clip(1e-2, 50, 0.013) }, target)
  ok(odd.covered[4] and not odd.covered[3],
     "a 2.6 frame shift rounds to 3 rather than truncating to 2")

  -- Uncovered is not silent. A window with no reference under it must refuse
  -- to answer rather than hand back the floor as though the band were quiet.
  local short = Reference.mix({ ref_clip(1e-2, 50, 0) }, target)
  ok(short.covered[50] and not short.covered[51], "coverage ends with the clip")
  local v = Reference.window_db(short, 1, 50, 90, 0.5)
  near(v, -20, 0.001, "a covered window answers")
  ok(Reference.window_db(short, 100, 150, 90, 0.5) == nil,
     "an uncovered window answers nil, not a level")
  ok(Reference.window_db(short, 40, 90, 90, 0.5) == nil,
     "a window less than half covered answers nil")
  ok(Reference.window_db(short, 1, 60, 90, 0.5) ~= nil,
     "a window more than half covered answers")
end

do
  -- The percentile is a percentile: 90% of a window at -30 and 10% at -6 reads
  -- near the loud end, which is the whole reason it is not a mean. A mean here
  -- would be about -13 dB and a rider would under-boost against it.
  local target = { n = 100, hop_s = 0.005, item_pos = 0 }
  local R = Reference.mix({ ref_clip(1e-3, 100, 0) }, target)
  for i = 91, 100 do R.ms[i] = 10 ^ (-6 / 10) R.db[i] = -6 end
  near(Reference.window_db(R, 1, 100, 90, 0.5), -30, 0.001,
       "the 90th percentile of a mostly-quiet window sits at the 90% mark")
  near(Reference.window_db(R, 1, 100, 95, 0.5), -6, 0.001,
       "and the 95th reaches into the loud tail")
end

-------------------------------------------------------------- rider fixtures

-- A rider config with every softening feature off, so a test measures the gain
-- law rather than the smoothing on top of it.
local function rconf(over)
  local c = conf({
    rider_smooth_ms = 0, rider_seg_max_ms = 0, rider_gate_db = -90,
    rider_max_boost_db = 60, rider_max_cut_db = 60,
    rider_lookahead_ms = 40, rider_trans_ms = 60, rider_speed_db_s = 60,
    rider_after_notes = false, rider_offset_db = 0,
    rider_ref_follow = 100, rider_tgt_level = 100, rider_trim_db = 0,
  })
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

-- Three half-second notes at 1 s intervals, at the levels given, over digital
-- silence -- well below rconf's disabled gate, so the gaps produce no fallback
-- segments and a test can look at the three notes alone.
-- Returns F, notes.
local function take3(levels, gains)
  local segs = {}
  for i, db in ipairs(levels) do
    if i > 1 then segs[#segs + 1] = { n = 100, db = -110 } end
    segs[#segs + 1] = { hz = A4, n = 100, db = db }
  end
  segs[#segs + 1] = { n = 100, db = -110 }
  local F = build(segs)
  local notes = {}
  for i = 1, #levels do
    notes[i] = { t0 = (i - 1) * 1.0, t1 = (i - 1) * 1.0 + 0.5,
                 rms_db = levels[i], gain_db = (gains and gains[i]) or 0,
                 name = "A4", midi = 69, cents = 0 }
  end
  return F, notes
end

-- A flat reference at `db` covering the whole target.
local function flat_ref(F, db)
  return Reference.mix({ ref_clip(10 ^ (db / 10), F.n, 0) }, F)
end

------------------------------------------------------------ rider segmentation

do
  local c = rconf()
  local F, notes = take3({ -20, -20, -20 })
  local segs = Rider.segments(F, notes, c)
  ok(#segs == 3, "three notes make three segments", tostring(#segs))
  for i, s in ipairs(segs) do
    ok(s.kind == "note", "segment " .. i .. " came from a note")
    near(s.t0, (i - 1) * 1.0, 1e-9, "segment " .. i .. " starts at its note")
    near(s.t1, (i - 1) * 1.0 + 0.5, 1e-9, "segment " .. i .. " ends at its note")
  end
end

do
  -- A note longer than the cap is split into EQUAL parts, so a sustained note
  -- can follow a build underneath it without the last piece being a stub
  -- measured over a window barely longer than itself.
  local c = rconf({ rider_seg_max_ms = 400 })
  local F = build({ { hz = A4, n = 200, db = -20 }, { n = 20, db = -80 } })
  local notes = { { t0 = 0, t1 = 1.0, rms_db = -20, gain_db = 0 } }
  local segs = Rider.segments(F, notes, c)
  ok(#segs == 3, "a 1 s note under a 400 ms cap becomes three segments",
     tostring(#segs))
  for i, s in ipairs(segs) do
    near(s.t1 - s.t0, 1 / 3, 1e-9, "part " .. i .. " is an equal third")
  end
  ok(segs[1].note == notes[1], "the parts still know their note")
end

do
  -- Where the pitch detector found nothing but there is still voice -- a
  -- spoken line, a whisper -- the level track has to segment it, or the ride
  -- would hold the last sung note's gain across the whole passage.
  local c = rconf({ rider_gate_db = -45 })
  local F = build({
    { hz = A4, n = 100, db = -20 },   -- a note
    { n = 60, db = -80 },             -- silence
    { n = 100, db = -25 },            -- unpitched, above the gate
    { n = 60, db = -80 },
  })
  local notes = { { t0 = 0, t1 = 0.5, rms_db = -20, gain_db = 0 } }
  local segs = Rider.segments(F, notes, c)
  ok(#segs >= 2, "an unpitched passage above the gate becomes a segment")
  local fb = nil
  for _, s in ipairs(segs) do if s.kind == "fallback" then fb = s end end
  ok(fb ~= nil, "and it is marked as a fallback segment")
  if fb then
    ok(fb.t0 >= 0.79 and fb.t0 <= 0.82, "the fallback starts where the level does",
       string.format("%.3f", fb.t0))
  end
end

do
  -- The same passage below the gate produces nothing at all. That is the
  -- answer to "quiet parts get dragged up": there is no segment to lift.
  local c = rconf({ rider_gate_db = -45 })
  local F = build({
    { hz = A4, n = 100, db = -20 },
    { n = 60, db = -80 },
    { n = 100, db = -55 },            -- room tone, below the gate
    { n = 60, db = -80 },
  })
  local notes = { { t0 = 0, t1 = 0.5, rms_db = -20, gain_db = 0 } }
  local segs = Rider.segments(F, notes, c)
  ok(#segs == 1, "room tone below the gate makes no segment", tostring(#segs))
end

------------------------------------------------------------------ the gain law

do
  -- Same reference throughout, three different vocal levels. This is the
  -- property the whole feature exists for: under an identical backing, the
  -- soft note is raised further than the loud one.
  local c = rconf()
  local F, notes = take3({ -20, -26, -14 })
  local R = flat_ref(F, -20)
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  local _, st = Rider.gains(segs, c)

  near(st.T_med, -20, 0.01, "the vocal median is the middle note")
  near(st.R_med, -20, 0.01, "the reference median is its own level")
  near(st.static_db, 0, 0.01, "a matched balance has no static term")
  near(segs[1].gain_db,  0, 0.01, "the median note is left alone")
  near(segs[2].gain_db, 6, 0.01, "the note 6 dB softer is raised 6 dB")
  near(segs[3].gain_db, -6, 0.01, "the note 6 dB louder is lowered 6 dB")

  -- At half strength it is half the move, which is what the control claims.
  local c2 = rconf({ rider_tgt_level = 50 })
  local s2 = Rider.segments(F, notes, c2)
  Rider.measure(s2, F, R, c2)
  Rider.gains(s2, c2)
  near(s2[2].gain_db, 3, 0.01, "at 50% the soft note gets half the boost")
  near(s2[3].gain_db, -3, 0.01, "and the loud note half the cut")

  -- At zero it does nothing, and with a flat reference nothing else does
  -- either, so the ride is silent. A rider that moved here would be moving
  -- for no reason at all.
  local c3 = rconf({ rider_tgt_level = 0 })
  local s3 = Rider.segments(F, notes, c3)
  Rider.measure(s3, F, R, c3)
  Rider.gains(s3, c3)
  for i = 1, 3 do
    near(s3[i].gain_db, 0, 0.01, "at 0% under a flat reference nothing moves")
  end
end

do
  -- The mirror image: one vocal level, three different backings.
  local c = rconf({ rider_tgt_level = 0 })
  local F, notes = take3({ -20, -20, -20 })
  local target = { n = F.n, hop_s = F.hop_s, item_pos = 0 }
  local R = Reference.mix({ ref_clip(10 ^ (-20 / 10), F.n, 0) }, target)
  for i = 200, 300 do R.db[i] = -14 end          -- the second note's backing
  for i = 400, 500 do R.db[i] = -26 end          -- the third's
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  Rider.gains(segs, c)
  near(segs[1].gain_db,  0, 0.01, "under the median backing the vocal holds")
  near(segs[2].gain_db, 6, 0.01, "a backing 6 dB louder lifts the vocal 6 dB")
  near(segs[3].gain_db, -6, 0.01, "a backing 6 dB quieter drops it 6 dB")

  local c2 = rconf({ rider_tgt_level = 0, rider_ref_follow = 50 })
  local s2 = Rider.segments(F, notes, c2)
  Rider.measure(s2, F, R, c2)
  Rider.gains(s2, c2)
  near(s2[2].gain_db, 3, 0.01, "at 50% follow it tracks half the change")
end

do
  -- The offset is absolute: it says where the vocal should sit against the
  -- reference, so a vocal already 6 dB below a backing and asked to sit level
  -- with it comes up by 6.
  local c = rconf({ rider_tgt_level = 0, rider_ref_follow = 0 })
  local F, notes = take3({ -26, -26, -26 })
  local R = flat_ref(F, -20)
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  local _, st = Rider.gains(segs, c)
  near(st.static_db, 6, 0.01, "the static term is the whole balance error")
  near(segs[1].gain_db, 6, 0.01, "and every segment carries it")

  -- match_offset is the number that makes it vanish -- what the panel's
  -- button sets, so that "absolute" can be a usable default.
  local off = Rider.match_offset(segs)
  near(off, -6, 0.01, "match_offset reports the balance the mix already has")
  local c2 = rconf({ rider_tgt_level = 0, rider_ref_follow = 0,
                     rider_offset_db = off })
  local s2 = Rider.segments(F, notes, c2)
  Rider.measure(s2, F, R, c2)
  local _, st2 = Rider.gains(s2, c2)
  near(st2.static_db, 0, 0.01, "applying it cancels the static term exactly")
end

do
  -- Caps bound the ride; trim is added AFTER the cap, because it is an output
  -- level and not part of the correction.
  local c = rconf({ rider_max_boost_db = 2, rider_max_cut_db = 3 })
  local F, notes = take3({ -20, -30, -10 })
  local R = flat_ref(F, -20)
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  Rider.gains(segs, c)
  near(segs[2].gain_db, 2, 0.01, "a boost is capped")
  near(segs[3].gain_db, -3, 0.01, "a cut is capped separately")
  ok(segs[2].clamped and segs[3].clamped, "capped segments are flagged")
  ok(not segs[1].clamped, "an uncapped segment is not")

  local c2 = rconf({ rider_max_boost_db = 2, rider_max_cut_db = 3,
                     rider_trim_db = -1.5 })
  local s2 = Rider.segments(F, notes, c2)
  Rider.measure(s2, F, R, c2)
  Rider.gains(s2, c2)
  near(s2[2].gain_db, 0.5, 0.01, "trim lands on top of the cap, not under it")
end

do
  -- The Pre-FX note gains are part of what the fader will see, so the rider
  -- plans against the corrected level. A note already lifted 4 dB by part 1
  -- needs 4 dB less from the ride.
  local F, notes = take3({ -20, -26, -14 }, { 0, 4, -4 })
  local R = flat_ref(F, -20)
  local c = rconf({ rider_after_notes = true })
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  Rider.gains(segs, c)
  near(segs[2].tgt_db, -22, 0.01, "the target level includes the Pre-FX gain")
  near(segs[2].gain_db, 2, 0.01, "so the ride asks for what is left")

  local c2 = rconf({ rider_after_notes = false })
  local s2 = Rider.segments(F, notes, c2)
  Rider.measure(s2, F, R, c2)
  Rider.gains(s2, c2)
  near(s2[2].tgt_db, -26, 0.01, "and ignores it when told the take is raw")
  near(s2[2].gain_db, 6, 0.01, "riding the raw level instead")
end

do
  -- No reference at all is a legitimate way to use this: the target term
  -- still levels the take against its own median.
  local c = rconf()
  local F, notes = take3({ -20, -26, -14 })
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, nil, c)
  local _, st = Rider.gains(segs, c)
  ok(st.R_med == nil, "with no reference there is no reference median")
  near(segs[2].gain_db, 6, 0.01, "and the vocal is still levelled against itself")
end

do
  -- A segment the reference does not reach must not be given a level derived
  -- from nothing. It keeps the target term and drops the follow term.
  local c = rconf()
  local F, notes = take3({ -20, -20, -20 })
  local target = { n = F.n, hop_s = F.hop_s, item_pos = 0 }
  local R = Reference.mix({ ref_clip(10 ^ (-14 / 10), 150, 0) }, target)
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  Rider.gains(segs, c)
  ok(segs[1].ref_db ~= nil, "a covered segment has a reference level")
  ok(segs[3].no_ref, "an uncovered one is marked, not guessed at")
  ok(segs[3].gain_db ~= nil, "and is still ridden on the target term alone")
end

------------------------------------------------------------------ smoothing

do
  -- Smoothing is in TIME, not in segments: the same three notes an octave
  -- apart in tempo must smooth by the same musical amount. Here, one lone
  -- loud note surrounded by median ones is pulled back toward its neighbours.
  local c = rconf({ rider_smooth_ms = 1000 })
  local F, notes = take3({ -20, -32, -20 })
  local R = flat_ref(F, -20)
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  Rider.gains(segs, c)
  near(segs[2].raw_gain_db, 12, 0.01, "the raw gain is the full correction")
  ok(segs[2].gain_db < 12 and segs[2].gain_db > 4,
     "smoothing pulls it back toward its neighbours",
     string.format("%.2f", segs[2].gain_db))
  ok(segs[1].gain_db > 0 and segs[3].gain_db > 0,
     "and pushes some of it onto them")
  -- Zero-phase: neighbours on both sides move by the same amount, so the ride
  -- does not lag. A one-pole would have left segment 1 untouched.
  near(segs[1].gain_db, segs[3].gain_db, 0.01,
       "smoothing is symmetric -- it does not lag")
end

do
  local c = rconf({ rider_smooth_ms = 0 })
  local F, notes = take3({ -20, -32, -20 })
  local R = flat_ref(F, -20)
  local segs = Rider.segments(F, notes, c)
  Rider.measure(segs, F, R, c)
  Rider.gains(segs, c)
  near(segs[2].gain_db, 12, 0.01, "smoothing off leaves the gain alone")
  near(segs[1].gain_db, 0, 0.01, "and its neighbours untouched")
end

--------------------------------------------------------------------- the curve

do
  local c = rconf()
  local F, notes = take3({ -20, -26, -14 })
  local R = flat_ref(F, -20)
  local segs, pts = Rider.run(F, notes, R, c)
  ok(#pts > 0, "the ride produces points")

  local prev = -1
  local mono = true
  for _, p in ipairs(pts) do
    if p.t <= prev then mono = false end
    prev = p.t
  end
  ok(mono, "points are strictly increasing in time")

  -- The claim the whole design rests on: the level is already right when the
  -- word starts, not arriving at it. At `lookahead` before every onset the
  -- curve is already at that segment's gain.
  local look = c.rider_lookahead_ms / 1000
  for i, s in ipairs(segs) do
    near(Rider.value_at(pts, s.t0 - look), s.gain_db, 0.02,
         string.format("segment %d is at its level %d ms before its onset",
                       i, c.rider_lookahead_ms))
    near(Rider.value_at(pts, (s.t0 + s.t1) / 2), s.gain_db, 0.02,
         string.format("segment %d holds its level through itself", i))
  end

  -- And in the gap it HOLDS the level it had. A corrective envelope returns to
  -- unity between notes; a ride that did would dip to the wrong level once per
  -- word, which is the pumping this exists to avoid.
  near(Rider.value_at(pts, 0.7), segs[1].gain_db, 0.02,
       "the curve holds through a gap instead of returning to unity")
  ok(math.abs(Rider.value_at(pts, 1.7) - segs[2].gain_db) < 0.02,
     "including a gap after a segment that moved 6 dB")

  near(pts[1].t, 0, 1e-9, "the curve starts at the top of the take")
  near(pts[1].db, segs[1].gain_db, 1e-9,
       "already at the first segment's level, not at unity")
  near(pts[#pts].t, F.span, 1e-6, "and runs to the end of the span")
  near(pts[#pts].db, segs[#segs].gain_db, 1e-9,
       "holding the last segment's level")
end

do
  -- Speed is a slew limit, so a big step takes proportionally longer rather
  -- than being truncated into a jump.
  local function transition_length(speed)
    local c = rconf({ rider_speed_db_s = speed, rider_trans_ms = 10 })
    local F, notes = take3({ -20, -32, -20 })
    local R = flat_ref(F, -20)
    local segs, pts = Rider.run(F, notes, R, c)
    -- Walk back from the second onset to where the curve was last flat at the
    -- first segment's level.
    local target = segs[1].gain_db
    local t, step = segs[2].t0, 0.001
    while t > 0 and math.abs(Rider.value_at(pts, t) - target) > 0.05 do
      t = t - step
    end
    return segs[2].t0 - t, segs[2].gain_db - segs[1].gain_db
  end

  local slow, delta = transition_length(6)
  local fast = transition_length(60)
  ok(slow > fast, "a slower speed makes a longer transition",
     string.format("%.3f vs %.3f s", slow, fast))
  -- 12 dB at 6 dB/s is 2 s of movement, which is longer than the gap can hold,
  -- so it is bounded by the room available rather than reaching the full time.
  ok(slow >= 0.4, "and a 12 dB move at 6 dB/s takes a good part of a second",
     string.format("%.3f s for %.1f dB", slow, delta))
end

do
  -- Two segments at the same level need no transition at all, so the curve is
  -- flat across the gap between them. A rider that moved here would be
  -- audible for no reason.
  local c = rconf()
  local F, notes = take3({ -20, -20, -20 })
  local R = flat_ref(F, -20)
  local _, pts = Rider.run(F, notes, R, c)
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pts) do
    if p.db < lo then lo = p.db end
    if p.db > hi then hi = p.db end
  end
  near(hi - lo, 0, 1e-9, "an unchanging ride is a flat line")
end

do
  -- A gated stretch is held through, not ridden. The curve between two sung
  -- notes with a breath in the middle must never lift the breath.
  local c = rconf({ rider_gate_db = -45 })
  local F = build({
    { hz = A4, n = 100, db = -20 },
    { n = 100, db = -60 },            -- a breath, below the gate
    { hz = A4, n = 100, db = -20 },
    { n = 40, db = -80 },
  })
  local notes = { { t0 = 0, t1 = 0.5, rms_db = -20, gain_db = 0 },
                  { t0 = 1.0, t1 = 1.5, rms_db = -20, gain_db = 0 } }
  local R = flat_ref(F, -20)
  local segs, pts = Rider.run(F, notes, R, c)
  ok(#segs == 2, "the breath makes no segment of its own", tostring(#segs))
  near(Rider.value_at(pts, 0.75), segs[1].gain_db, 0.02,
       "and the curve holds across it rather than lifting it")
end


------------------------------------------------------------- octave repair

-- Frames at a given pitch, with an optional octave error in the middle. This
-- is the shape the bug actually takes: a held note that YIN reads an octave
-- high for a stretch and then reads correctly again.
local function held(hz, n, err_from, err_to, shift)
  local segs = {}
  for i = 1, n do
    local f = hz
    if err_from and i >= err_from and i <= err_to then
      f = hz * 2 ^ (shift or 1)
    end
    segs[#segs + 1] = { hz = f, n = 1, db = -12 }
  end
  return build(segs)
end

do
  local c = conf()
  -- A clean held note is left entirely alone. The repair must be invisible
  -- when there is nothing to repair, or every take gets quietly retuned.
  local F = held(A4, 300)
  local f0, nmoved = Octave.repair(F, c)
  ok(nmoved == 0, "a clean held note has nothing moved", tostring(nmoved))
  local intact = true
  for i = 1, F.n do
    if math.abs(f0[i] - A4) > 1e-9 then intact = false end
  end
  ok(intact, "and every frame comes back at its own pitch")
end

do
  -- The reported bug: 400 ms of a 1.5 s held note read an octave high. The
  -- repair has to pull those frames back down.
  local c = conf()
  local F = held(A4, 300, 101, 180, 1)
  local f0, nmoved, moved = Octave.repair(F, c)
  ok(nmoved == 80, "an 80 frame octave excursion is all moved", tostring(nmoved))
  local fixed = true
  for i = 101, 180 do
    if math.abs(f0[i] - A4) > 1e-6 or moved[i] ~= -1 then fixed = false end
  end
  ok(fixed, "every excursion frame is pulled back exactly one octave")
  for _, i in ipairs({ 1, 100, 181, 300 }) do
    near(f0[i], A4, 1e-9, "frame " .. i .. " outside the excursion is untouched")
  end

  -- And with the repair off it is left exactly as YIN read it, so the control
  -- is a real off switch rather than a change of degree.
  local off = conf({ octave_fix = false })
  local g0, gn = Octave.repair(F, off)
  ok(gn == 0, "with the repair off nothing moves")
  near(g0[150], A4 * 2, 1e-9, "and the excursion is still an octave up")
end

do
  -- The whole point of the fix: without it the excursion splits the held note
  -- into three, because a boundary is a change of semitone LABEL and an octave
  -- is a different label. With it, one note.
  local c = conf({ octave_fix = false, wobble_ms = 0 })
  local F = held(A4, 300, 101, 180, 1)
  local split = Cluster.run(F, c)
  ok(#split == 3, "unrepaired, one held note clusters as three",
     tostring(#split))

  local c2 = conf({ wobble_ms = 0 })
  local whole = Cluster.run(F, c2)
  ok(#whole == 1, "repaired, it is one note", tostring(#whole))
  if #whole == 1 then
    ok(whole[1].name == "A4", "at the right pitch", whole[1].name)
    near(whole[1].t1 - whole[1].t0, 300 * 0.005, 0.01,
         "and the full length of the note")
  end
end

do
  -- A downward error is repaired the same way. The bug is symmetric even if
  -- YIN's first-dip rule makes upward errors the common one.
  local c = conf()
  local F = held(A4, 300, 101, 180, -1)
  local f0, nmoved, moved = Octave.repair(F, c)
  ok(nmoved == 80, "an octave-DOWN excursion is moved too", tostring(nmoved))
  ok(moved[150] == 1, "upward, by one octave", tostring(moved[150]))
  near(f0[150], A4, 1e-6, "landing back on the note")
end

do
  -- What must NOT happen: a real octave leap that is held gets kept. This is
  -- the whole meaning of octave_hold_ms, and without this assertion the repair
  -- would be free to flatten every melody that spans an octave.
  local c = conf({ octave_hold_ms = 300 })
  -- 1.5 s at A4, then 1.5 s at A5 -- far longer than the 300 ms threshold.
  local F = build({ { hz = A4, n = 300, db = -12 },
                    { hz = A4 * 2, n = 300, db = -12 } })
  local _, nmoved = Octave.repair(F, c)
  ok(nmoved == 0, "a sustained octave leap is left alone", tostring(nmoved))

  -- ...and the same leap, held only briefly, is treated as the error it
  -- almost always is.
  local brief = build({ { hz = A4, n = 300, db = -12 },
                        { hz = A4 * 2, n = 20, db = -12 },
                        { hz = A4, n = 300, db = -12 } })
  local _, bn = Octave.repair(brief, c)
  ok(bn == 20, "a brief one is repaired", tostring(bn))
end

do
  -- The threshold is a real dial, not a constant with a name. The same
  -- excursion is kept or repaired depending on where hold sits relative to it.
  local F = build({ { hz = A4, n = 300, db = -12 },
                    { hz = A4 * 2, n = 100, db = -12 },
                    { hz = A4, n = 300, db = -12 } })
  local _, short_hold = Octave.repair(F, conf({ octave_hold_ms = 2000 }))
  ok(short_hold == 100, "a 500 ms excursion is repaired at a 2 s threshold",
     tostring(short_hold))
  local _, long_hold = Octave.repair(F, conf({ octave_hold_ms = 100 }))
  ok(long_hold == 0, "and kept at a 100 ms threshold", tostring(long_hold))
end

do
  -- A genuine melodic interval that is not an octave must survive untouched,
  -- whatever its size. Shifting a fifth by an octave would leave it a fourth
  -- the other way, which is a smaller jump -- so a repair that only looked at
  -- continuity would take it.
  local c = conf()
  local fifth = A4 * 2 ^ (7 / 12)
  local F = build({ { hz = A4, n = 200, db = -12 },
                    { hz = fifth, n = 200, db = -12 } })
  local _, nmoved = Octave.repair(F, c)
  ok(nmoved == 0, "a perfect fifth is not an octave error", tostring(nmoved))
end

do
  -- Across a long enough rest the chain is cut, so a phrase that really does
  -- start an octave away is not dragged back to the previous phrase's octave.
  local c = conf({ octave_link_ms = 200, octave_hold_ms = 100 })
  local F = build({ { hz = A4, n = 200, db = -12 },
                    { n = 100, db = -80 },              -- 500 ms of silence
                    { hz = A4 * 2, n = 200, db = -12 } })
  local _, nmoved = Octave.repair(F, c)
  ok(nmoved == 0, "a rest breaks the chain, so a new phrase keeps its octave",
     tostring(nmoved))
end

do
  -- Unvoiced frames are never moved: there is no pitch there to be wrong.
  local c = conf()
  local F = build({ { hz = A4, n = 100, db = -12 },
                    { n = 50, db = -80 },
                    { hz = A4 * 2, n = 30, db = -12 },
                    { hz = A4, n = 100, db = -12 } })
  local f0, _, moved = Octave.repair(F, c)
  local untouched = true
  for i = 101, 150 do
    if moved[i] ~= nil or f0[i] ~= F.f0[i] then untouched = false end
  end
  ok(untouched, "unvoiced frames are left exactly as they were")
end

do
  -- The repair is cached on the frame table and keyed on what changes it, so
  -- the panel's plot and the clustering share one pass.
  local c = conf()
  local F = held(A4, 200, 51, 90, 1)
  local a = Octave.repair(F, c)
  local b = Octave.repair(F, c)
  ok(a == b, "the same settings return the identical cached table")
  c.octave_hold_ms = c.octave_hold_ms + 1
  local d = Octave.repair(F, c)
  ok(a ~= d, "and a changed setting recomputes it")
end


do
  -- The register prior, and the case that needed it. Continuity alone believes
  -- anything held longer than octave_hold_ms, so a five second note read an
  -- octave high stays wrong however implausible it is. Only the singer's own
  -- range can say otherwise.
  --
  -- A phrase around A3 with a long C5 in it, which is what the real take did.
  local c = conf()
  local A3, C4, C5 = 220.0, 261.626, 523.251
  local F = build({
    { hz = A3, n = 400, db = -12 },      -- 2 s of the phrase
    { hz = C4, n = 200, db = -12 },
    { hz = A3, n = 400, db = -12 },
    { hz = C5, n = 1000, db = -12 },     -- 5 s, far past the hold threshold
  })
  local _, nmoved = Octave.repair(F, c)
  ok(nmoved == 1000, "a five second note outside the register is repaired",
     tostring(nmoved))
  local notes = Cluster.run(F, c)
  local last = notes[#notes]
  ok(last and last.name == "C4", "and reads as the C4 it was",
     last and last.name or "none")

  -- Continuity on its own does not get there, which is what the prior is for.
  local no_reg = conf({ octave_range = 36 })
  local _, without = Octave.repair(F, no_reg)
  ok(without == 0, "continuity alone leaves it, however long it is held",
     tostring(without))
end

do
  -- It must not drag a genuinely high note down. A phrase that reaches a
  -- fourth above the median is ordinary singing, and its octave-down would be
  -- CLOSER to the median -- so a prior that merely pulled toward the middle
  -- would take it.
  local c = conf()
  local A3 = 220.0
  local segs = {}
  for _ = 1, 6 do
    segs[#segs + 1] = { hz = A3, n = 200, db = -12 }
    segs[#segs + 1] = { hz = A3 * 2 ^ (5 / 12), n = 200, db = -12 }
  end
  local F = build(segs)
  local _, nmoved = Octave.repair(F, c)
  ok(nmoved == 0, "a fourth above the median is left alone", tostring(nmoved))
end

do
  -- Self-calibrating: the same melody an octave up is not "too high", because
  -- the register is measured from the take rather than assumed. A soprano take
  -- must behave exactly like the tenor one.
  local c = conf()
  local function phrase(root)
    return build({ { hz = root, n = 400, db = -12 },
                   { hz = root * 2 ^ (4 / 12), n = 400, db = -12 },
                   { hz = root * 2 ^ (7 / 12), n = 400, db = -12 } })
  end
  local low, high = phrase(196.0), phrase(392.0)
  local _, nlow = Octave.repair(low, c)
  local _, nhigh = Octave.repair(high, c)
  ok(nlow == 0 and nhigh == 0,
     "the register is measured, not assumed -- both octaves are left alone",
     nlow .. " and " .. nhigh)
end

do
  -- The dead zone widens with the take's own spread, so a melody that really
  -- does span two octaves is not flattened into the middle of itself.
  local c = conf()
  local root = 196.0
  local segs = {}
  for k = 0, 24, 2 do
    segs[#segs + 1] = { hz = root * 2 ^ (k / 12), n = 120, db = -12 }
  end
  local F = build(segs)
  local _, nmoved = Octave.repair(F, c)
  ok(nmoved == 0, "a two octave melody widens its own dead zone",
     tostring(nmoved))
end

do
  -- And the control is a real off switch for the register half, leaving the
  -- continuity half working.
  local A3, C5 = 220.0, 523.251
  local F = build({
    { hz = A3, n = 400, db = -12 },
    { hz = C5, n = 1000, db = -12 },
    { hz = A3, n = 400, db = -12 },
  })
  local _, off = Octave.repair(F, conf({ octave_range = 36 }))
  ok(off == 0, "at 36 semitones the register check is off", tostring(off))

  -- The brief excursions the continuity half handles are still handled.
  local brief = build({ { hz = A3, n = 400, db = -12 },
                        { hz = A3 * 2, n = 40, db = -12 },
                        { hz = A3, n = 400, db = -12 } })
  local _, still = Octave.repair(brief, conf({ octave_range = 36 }))
  ok(still == 40, "while continuity still repairs a brief one", tostring(still))
end

-------------------------------------------------------------------- report

print(string.format("headless: %d passed, %d failed", pass, fail))
-- The tally has to reach the exit code, or a CI job or an && chain reads a
-- suite that printed FAIL as green. Run from the Actions list this is a no-op:
-- REAPER's Lua has no os.exit, so the call is simply absent.
if os.exit then os.exit(fail == 0 and 0 or 1) end
