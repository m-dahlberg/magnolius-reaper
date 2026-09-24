-- @noindex
-- Note Leveling -- parameter defaults and persistence.
--
-- Pure Lua with no hard reaper dependency beyond the load/save helpers, so the
-- cluster and level stages can be exercised headlessly.
--
-- The parameter classes at the bottom are what make the panel responsive: only
-- ANALYSIS_KEYS change which samples get read, so everything else can move a
-- slider and see the result without touching the audio again.

local M = {}

M.EXT_SECTION = "note_leveling"

M.defaults = {
  -- A time selection narrows what is analysed and what is written; this overrides that back to
  -- the whole item without making you clear the selection. There is no split here: this script
  -- writes envelopes, not takes, so narrowing simply means fewer points.
  ignore_time_selection = false,

  -- Pitch detection ----------------------------------------------------------
  -- hop_ms is the pitch sampling distance -- the "every 5 ms" of the design.
  -- It sets the frame grid for both the pitch track and the RMS measurement,
  -- so both stages agree on what frame 100 means.
  hop_ms        = 5,
  min_hz        = 75,       -- YIN search range. 75..600 is the Vocal Editor's
  max_hz        = 600,      -- vocal range and decides tau_max/tau_min.
  -- The rate the accessor is asked for during the pitch pass. YIN costs
  -- O(window * tau_max) per frame, and both scale with the rate, so full-rate
  -- YIN is ~40x this and lands near realtime. 8 kHz still resolves 600 Hz to
  -- about +-10 cents after parabolic interpolation, against the 50 cents that
  -- semitone bucketing actually needs. RMS is never measured here -- that pass
  -- runs at the source rate, because a leveling tool that ignored everything
  -- above 4 kHz would misjudge bright and breathy voices.
  pitch_rate    = 8000,
  yin_threshold = 0.15,     -- CMNDF aperiodicity below this counts as voiced

  -- Note clustering (ported from the Vocal Editor's cluster_notes) ------------
  -- A frame counts as voiced only if it is also above this level, which is
  -- what keeps room tone and reverb tails from becoming notes. It lives here
  -- rather than with detection because it is a comparison against a number the
  -- analysis already produced -- moving it costs a recompute, not a re-read.
  -- Octave repair. YIN reads each frame on its own and has no evidence about
  -- its own octave -- the reason is in octave.lua -- so a held note can come
  -- back as the same note name in two octaves and get split in half. The
  -- repair is a Viterbi over the pitch track that prefers a continuous line.
  --
  -- hold_ms is the whole control, and it says what it means: an octave change
  -- shorter than this is treated as a detection error, longer than it is
  -- treated as the melody. Off for anything that really does move in octaves.
  octave_fix      = true,
  octave_hold_ms  = 1000,
  -- Two voiced frames further apart than this are not coupled: a rest is a
  -- phrase boundary, and a real octave leap across one has to be allowed.
  octave_link_ms  = 200,
  -- ...and how far outside the take's own register a pitch may sit before its
  -- octave is doubted, in semitones either side of the median. This is the
  -- musical half of the repair, and it is what continuity alone cannot supply:
  -- a note held for five seconds is "the melody" by the hold rule however
  -- implausible it is, and only the singer's range can say that a C5 in a take
  -- centred on A3 is a misread C4.
  --
  -- A FLOOR, not the whole answer: the dead zone widens to three times the
  -- take's own spread when the melody is genuinely wide, so this only decides
  -- how tight it may get on a narrow one. 36 effectively turns the check off.
  octave_range    = 9,

  voice_gate_db   = -50,
  tolerance_cents = 100,    -- max distance from a semitone centre to accept it
  min_note_ms     = 100,    -- shorter clusters are discarded, leaving a hole
  max_gap_ms      = 500,    -- same-note clusters up to this far apart merge
  silence_db      = -30,    -- ...but only if the gap is louder than this
  wobble_ms       = 150,    -- vibrato excursions shorter than this are absorbed

  -- Leveling -----------------------------------------------------------------
  -- A note inside [floor_db, ceiling_db] is left alone. One outside is moved
  -- `amount` percent of the way back to the edge it crossed.
  floor_db   = -30,
  ceiling_db = -12,
  amount     = 100,
  -- ...and then clamped. A note whose RMS was measured badly -- a half-caught
  -- consonant, a breath that made it past the voice gate -- can otherwise ask
  -- for a huge move, and `amount` scales it rather than bounding it. These
  -- bound it. Separate limits because the two directions are not equally
  -- forgiving: pulling a loud note down is nearly always safe, pushing a quiet
  -- one up lifts its noise floor with it.
  max_boost_db = 6,
  max_cut_db   = 6,

  -- Output -------------------------------------------------------------------
  -- Optional: a pair of take markers around every note, so the detection can
  -- be read and edited in the arrange view rather than only in the panel.
  write_markers = false,

  -- Envelope -----------------------------------------------------------------
  -- The default envelope falls back to unity in every gap long enough to hold
  -- both ramps, which leaves whatever sits between two notes at its own level.
  -- That is right when the notes around it were left alone and wrong when they
  -- were both cut: a consonant, a breath or a room-tone tail between two notes
  -- that were each pulled down 4 dB becomes the loudest thing in the phrase,
  -- and a correction meant to even out the melody has emphasised the noise
  -- between it instead.
  --
  -- Glide mode never returns to unity. The gain runs straight from one note's
  -- gain to the next's across the whole gap, the first note's gain reaches back
  -- to the start of the clip and the last note's holds to the end, so the
  -- material between two notes stays inside the correction its neighbours got.
  -- Ramp in and ramp out are unused in this mode; point spacing still is not.
  glide_notes = false,
  ramp_in_ms  = 30,
  ramp_out_ms = 60,
  -- Ramps are subdivided at this resolution. A REAPER envelope interpolates
  -- linearly in its own stored domain, so a two-point ramp would not be linear
  -- in dB; emitting the exact dB value every few milliseconds makes the curve
  -- right whatever the envelope's scaling mode is.
  ramp_res_ms = 10,

  -- Rider -- the macro pass -------------------------------------------------
  -- Part 2. Where the note leveling above evens out one voice against itself,
  -- the rider sits that voice against the rest of the arrangement: it measures
  -- one or more reference clips, measures the target, and writes a stepped
  -- ride as POST-FX volume automation (VOLENV2, the fader) so it stacks on top
  -- of the Pre-FX correction rather than fighting it.
  --
  -- The gain law, per segment, is three terms:
  --
  --   static   (R_med + offset - T_med)     the overall balance
  --   follow   ref_follow  * (ref - R_med)  louder backing -> louder vocal
  --   level    -tgt_level  * (tgt - T_med)  softer word    -> more boost
  --
  -- The third term is what makes a soft phrase rise further than a loud one
  -- under the same backing, which a plain differential ride cannot do.
  rider_offset_db  = 0,     -- where the vocal should sit against the reference
  rider_ref_follow = 70,    -- %, how much the ride follows the backing
  rider_tgt_level  = 60,    -- %, how much of the vocal's own dynamics it cancels
  rider_max_boost_db = 6,   -- range caps, against unity
  rider_max_cut_db   = 6,

  -- Measurement. Both sides are read through a fixed vocal band (see
  -- rider.lua) and reduced with a high percentile rather than a mean, so a
  -- word that opens on a breath is judged by the word.
  -- Both windows are anchored at the segment's onset: what a syllable competes
  -- with is what happens from the moment it starts, not the average over a
  -- note that may run on for four seconds after the decision is made.
  rider_ref_window_ms = 500,
  rider_tgt_window_ms = 400,
  -- Longest a single held level may last. A note longer than this is split
  -- into several segments, each measured on its own, so a sustained note can
  -- still follow a build underneath it. 0 disables the split.
  rider_seg_max_ms    = 1000,
  -- Below this the target is not ridden at all: the curve holds whatever it
  -- last had. This is the whole answer to "quiet parts get dragged up".
  rider_gate_db       = -45,

  -- Motion -------------------------------------------------------------------
  -- smooth_ms is a zero-phase Gaussian over the per-segment gains, weighted by
  -- the time between segment centres -- offline there is no reason to lag.
  rider_smooth_ms  = 1000,
  rider_speed_db_s = 12,    -- slew limit; a big step simply takes longer
  -- The transition into a segment is COMPLETE this long before its onset, so
  -- the level is already right when the word starts instead of arriving at it.
  rider_lookahead_ms = 40,
  rider_trans_ms     = 60,  -- nominal transition length, stretched by speed
  rider_point_ms     = 20,  -- envelope point spacing along a transition

  rider_trim_db = 0,        -- output trim, added to everything

  -- The rider measures the raw take and adds the Pre-FX note gains to it, so
  -- it plans against the signal the fader will actually see. That is only true
  -- if the Pre-FX envelope is written too, so by default the rider writes both.
  rider_after_notes = true,
  -- Track roles. The source is the vocal being levelled and ridden; up to three background
  -- tracks are summed into the loudness reference. Each is stored as a GUID, the name it had
  -- when it was picked, and a typed name that overrides both -- see nl/trackpick.lua for why
  -- all three, and nl/select.lua for what replaced the old positional rule. Every audio clip
  -- on a chosen track is used; nothing needs selecting.
  source_guid = "", source_name = "", source_override = "",
  bg1_guid = "", bg1_name = "", bg1_override = "",
  bg2_guid = "", bg2_name = "", bg2_override = "",
  bg3_guid = "", bg3_name = "", bg3_override = "",
}

function M.new()
  local t = {}
  for k, v in pairs(M.defaults) do t[k] = v end
  return t
end

-- Restore every tunable to its default. In place, because the panel holds one
-- cfg table as an upvalue and hands it to the kernel, the cluster stage and the
-- level stage -- swapping the table would leave those pointing at the old one.
function M.reset(cfg)
  local extra = {}
  for k in pairs(cfg) do
    if M.defaults[k] == nil then extra[#extra + 1] = k end
  end
  for _, k in ipairs(extra) do
    cfg[k] = nil
    if reaper then reaper.DeleteExtState(M.EXT_SECTION, k, true) end
  end
  for k, v in pairs(M.defaults) do cfg[k] = v end
  M.save(cfg)
  return cfg
end

-- Parameter classes -----------------------------------------------------------
-- Changing any ANALYSIS key changes the samples that would be read, or the
-- grid they are reduced onto, so the frame cache has to be thrown away.
-- Everything else only re-derives from frames already in memory, which is why
-- a floor or ceiling slider can redraw the panel without re-reading a sample.

-- The track roles are analysis keys for the same reason as the rest: they change which samples
-- would be read. The source picks the take that is levelled and ridden; each background slot
-- adds reference clips. None of them can be re-derived from frames already in memory, which is
-- the line this class draws.
M.ANALYSIS_KEYS = { "hop_ms", "min_hz", "max_hz", "pitch_rate", "yin_threshold",
                    "source_guid", "source_name", "source_override",
                    "bg1_guid", "bg1_name", "bg1_override",
                    "bg2_guid", "bg2_name", "bg2_override",
                    "bg3_guid", "bg3_name", "bg3_override",
                    "ignore_time_selection" }
M.CLUSTER_KEYS  = { "voice_gate_db", "tolerance_cents", "min_note_ms",
                    "max_gap_ms", "silence_db", "wobble_ms",
                    "octave_fix", "octave_hold_ms", "octave_link_ms",
                    "octave_range" }
M.LEVEL_KEYS    = { "floor_db", "ceiling_db", "amount",
                    "max_boost_db", "max_cut_db", "glide_notes",
                    "ramp_in_ms", "ramp_out_ms", "ramp_res_ms" }
-- Output options change nothing that is computed, only what gets written, so
-- they are in no class: moving one must not even trigger a recompute.
M.OUTPUT_KEYS   = { "write_markers" }
-- The rider re-derives from the same cached frames plus the reference level
-- track, so its own class is separate from LEVEL_KEYS -- but note that
-- LEVEL_KEYS feed it too, since the Pre-FX note gains are part of what it
-- plans against. rider_sig is therefore always paired with level_sig.
M.RIDER_KEYS    = { "rider_offset_db", "rider_ref_follow", "rider_tgt_level",
                    "rider_max_boost_db", "rider_max_cut_db",
                    "rider_ref_window_ms", "rider_tgt_window_ms",
                    "rider_seg_max_ms", "rider_gate_db",
                    "rider_smooth_ms", "rider_speed_db_s",
                    "rider_lookahead_ms", "rider_trans_ms", "rider_point_ms",
                    "rider_trim_db", "rider_after_notes" }

local function signature(cfg, keys)
  local t = {}
  for i, k in ipairs(keys) do t[i] = tostring(cfg[k]) end
  return table.concat(t, "|")
end

function M.analysis_sig(cfg) return signature(cfg, M.ANALYSIS_KEYS) end
function M.cluster_sig(cfg)  return signature(cfg, M.CLUSTER_KEYS)  end
function M.level_sig(cfg)    return signature(cfg, M.LEVEL_KEYS)    end
function M.rider_sig(cfg)   return signature(cfg, M.RIDER_KEYS)   end

-- The kernel's memory map is fixed by these, so a change in any of them means
-- building a new kernel rather than reconfiguring the one in hand.
function M.kernel_sig(cfg, nchan)
  return table.concat({ nchan, cfg.pitch_rate, cfg.min_hz, cfg.max_hz }, "|")
end

-- Persistence ----------------------------------------------------------------
-- Values round-trip through ExtState as strings; the type is recovered from
-- the default, so an absent or corrupt key falls back rather than erroring.

function M.save(cfg)
  if not reaper then return end
  for k, v in pairs(cfg) do
    reaper.SetExtState(M.EXT_SECTION, k, tostring(v), true)
  end
end

function M.load()
  local cfg = M.new()
  if not reaper then return cfg end
  for k, default in pairs(M.defaults) do
    if reaper.HasExtState(M.EXT_SECTION, k) then
      local s = reaper.GetExtState(M.EXT_SECTION, k)
      if type(default) == "number" then
        cfg[k] = tonumber(s) or default
      elseif type(default) == "boolean" then
        cfg[k] = (s == "true")
      else
        cfg[k] = s
      end
    end
  end
  return cfg
end

return M
