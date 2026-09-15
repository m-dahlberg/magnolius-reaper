"""Reusable scaffold for headless REAPER render tests of a JSFX plugin.

Copy this and wavio.py into <plugin>/tools/, then write render_test.py that
imports from here. Every fact encoded below was verified against a
REAPER-written project chunk; deviating from it has silently broken renders
before (see the notes on each function).

    from render_harness import Harness, ReaperProject
    H = Harness("myplug", "MyPlug.jsfx")
    out, secs = H.render("unity", H.slider_line([1.0, 0.0]), input_name="in.wav")

Requires only the stdlib. `reaper` must be on PATH; `-newinst` means these
renders are safe to run while a normal REAPER instance is open.
"""
import base64
import os
import re
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavio import read_wav, write_wav_f32  # noqa: E402

RESOURCE = os.path.expanduser("~/.config/REAPER")   # Linux; ~/Library/Application Support/REAPER on macOS
EFFECTS = os.path.join(RESOURCE, "Effects")
DATA = os.path.join(RESOURCE, "Data")

# 32-bit float WAV. The 4-byte tag is little-endian "wave" -> b"evaw".
RENDER_CFG = base64.b64encode(b"evaw" + struct.pack("<i", 32)).decode()


# ---------------------------------------------------------------------------
# project chunk
# ---------------------------------------------------------------------------

class ReaperProject:
    """Builds a minimal .rpp with one track, one FX, optionally one item.

    RENDER_FMT's THIRD field is the render sample rate. Omit it and REAPER
    renders at whatever rate it used last, silently resampling the output --
    the classic "everything is subtly wrong by a fraction of a dB" failure.

    SAMPLERATE's SECOND field is the "project sample rate" checkbox. Leave it
    0 and the engine runs at the device/default rate (48k) no matter what the
    first field says -- media at any other rate gets resampled twice, which
    shows up as sinc ringing at item edges (measured on a 96k render before
    this was set to 1).
    """

    TEMPLATE = """<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000
  SAMPLERATE %(srate)d 1 0
  TEMPO 120 4 4
  RENDER_FILE "%(out_wav)s"
  RENDER_PATTERN ""
  RENDER_FMT 0 2 %(srate)d
  RENDER_1X 0
  RENDER_RANGE 1 0 %(length)s 18 1000
  RENDER_RESAMPLE 3 0 1
  RENDER_ADDTOPROJ 0
  RENDER_STEMS 0
  RENDER_DITHER 0
  <RENDER_CFG
    %(cfg)s
  >
  <TRACK
    NAME "test"
    <FXCHAIN
      SHOW 0
      LASTSEL 0
      DOCKED 0
      BYPASS 0 0 0
      <JS "%(fx)s" ""
        %(sliders)s
      >%(extra)s
    >
%(item)s  >
>
"""

    ITEM = """    <ITEM
      POSITION 0
      LENGTH %s
      LOOP 0
      NAME input
      <SOURCE WAVE
        FILE "%s"
      >
    >
"""

    def write(self, path, fx, sliders, out_wav, input_wav=None, length=2.0,
              srate=48000, in_len=None, js_ser=None, parmenv=None):
        extra = ""
        if js_ser:
            extra += "\n      " + js_ser
        if parmenv:
            extra += "\n" + parmenv
        item = self.ITEM % (in_len or length, input_wav) if input_wav else ""
        with open(path, "w") as f:
            f.write(self.TEMPLATE % dict(
                srate=srate, out_wav=out_wav, length=length, cfg=RENDER_CFG,
                fx=fx, sliders=sliders, extra=extra, item=item))


def slider_line(values, nslots=64):
    """One line holding all 64 slider values; '-' means undefined.

    File sliders serialize AT THEIR POSITION as a quoted basename relative to
    the slider's own directory -- '"ir.wav"', never '"ReverbIRs/ir.wav"' and
    never the list index. Pass such entries already quoted.
    """
    vals = list(values) + ["-"] * (nslots - len(values))
    return " ".join(str(v) for v in vals)


def parm_env(param_index, name, points, active=1):
    """Automation envelope for one slider -- the only way to change a
    parameter mid-render. Points are (time_sec, value_in_slider_units);
    shape 1 = square, so a mode switch lands on an exact sample.

    param_index is the slider number minus 1. Format confirmed against a
    REAPER-written chunk.
    """
    pts = "\n".join("        PT %g %g 1" % (t, v) for t, v in points)
    return ('      <PARMENV %d 0 2 %d "%s"\n'
            "        ACT 1 -1\n        VIS 1 1 1\n        ARM 0\n"
            "        DEFSHAPE 1 -1 -1\n%s\n      >"
            % (param_index, active, name, pts))


def js_ser_block(floats, indent=8):
    """@serialize state: raw 32-bit LE floats, base64, inside <JS_SER.

    The float order must match the file_var/file_mem calls in @serialize
    exactly, in order.
    """
    raw = struct.pack("<%df" % len(floats), *[float(v) for v in floats])
    b64 = base64.b64encode(raw).decode()
    lines = [b64[i:i + 128] for i in range(0, len(b64), 128)]
    pad = " " * indent
    return "<JS_SER\n" + "\n".join(pad + ln for ln in lines) + "\n      >"


# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

class Harness:
    def __init__(self, slug, fx_name, srate=48000, work=None):
        self.slug = slug
        self.fx = fx_name
        self.srate = srate
        self.work = work or os.path.expanduser("~/.cache/%s-rendertest" % slug)
        os.makedirs(self.work, exist_ok=True)
        self.proj = ReaperProject()
        self.results = []

    # -- reporting ---------------------------------------------------------
    def report(self, name, ok, detail):
        self.results.append((name, ok))
        print("%-14s %s  %s" % (name, "PASS" if ok else "FAIL", detail))

    def run(self, tests, argv=None):
        """tests: [(name, fn), ...]. Exits nonzero if anything failed."""
        sel = (argv if argv is not None else sys.argv[1:])
        for name, fn in tests:
            if sel and name not in sel:
                continue
            try:
                fn()
            except Exception as e:                      # noqa: BLE001
                self.report(name, False, "EXCEPTION %s" % e)
        bad = [n for n, ok in self.results if not ok]
        print("----\n%d/%d passed" % (len(self.results) - len(bad),
                                      len(self.results)))
        sys.exit(1 if bad else 0)

    # -- rendering ---------------------------------------------------------
    def path(self, *parts):
        return os.path.join(self.work, *parts)

    def write_input(self, name, channels, srate=None):
        p = self.path(name)
        write_wav_f32(p, srate or self.srate, channels)
        return p

    def render(self, name, sliders, input_name=None, length=2.0, srate=None,
               in_len=None, fx=None, js_ser=None, parmenv=None, timeout=600):
        srate = srate or self.srate
        out_wav = self.path(name + ".wav")
        rpp = self.path(name + ".rpp")
        if input_name and self.path(input_name) == out_wav:
            # the output is deleted before rendering -- a name collision
            # silently eats the input and renders silence
            raise ValueError("render name %r collides with its input file"
                             % name)
        if os.path.exists(out_wav):
            os.remove(out_wav)      # an existing output can pop a dialog and hang
        self.proj.write(rpp, fx or self.fx, sliders, out_wav,
                        input_wav=self.path(input_name) if input_name else None,
                        length=length, srate=srate, in_len=in_len,
                        js_ser=js_ser, parmenv=parmenv)
        t0 = time.time()
        subprocess.run(["reaper", "-newinst", "-nosplash", "-renderproject", rpp],
                       check=True, timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not os.path.exists(out_wav):
            raise RuntimeError("render produced no output: " + out_wav)
        _, chans = read_wav(out_wav)
        return chans, time.time() - t0

    # -- ReaScript ground truth -------------------------------------------
    PROBE_LUA = """
local out = [[%(out)s]]
local lines = {}
reaper.InsertTrackAtIndex(0, false)
local tr = reaper.GetTrack(0, 0)
local fx = reaper.TrackFX_AddByName(tr, [[%(fx)s]], false, -1)
if fx < 0 then
  lines[1] = "ADD_FAILED"
else
  local n = reaper.TrackFX_GetNumParams(tr, fx)
  lines[1] = "nparams " .. n
  for i = 0, n - 1 do
    local _, nm = reaper.TrackFX_GetParamName(tr, fx, i, "")
    local v, mn, mx = reaper.TrackFX_GetParam(tr, fx, i)
    lines[#lines+1] = string.format("%%d\\t%%s\\t%%.6f\\t%%.6f\\t%%.6f", i, nm, v, mn, mx)
  end
end
local f = io.open(out, "w")
f:write(table.concat(lines, "\\n") .. "\\n")
f:close()
reaper.Main_SaveProject(0, false)   -- clear the dirty flag...
reaper.Main_OnCommand(40004, 0)     -- ...so File:Quit exits without a dialog
"""

    def probe_params(self, timeout=120):
        """Ask REAPER which sliders actually parsed.

        A JSFX header parse error has NO error UI: the bad slider and usually
        every slider after it vanish and the plugin still loads. Comparing
        this list against the expected names is the only reliable detector.
        REAPER appends wet/bypass/delta params after the real sliders, so
        check names by index, not the count alone.

        Returns (names_by_index, raw_lines).
        """
        out = self.path("params.txt")
        lua = self.path("probe.lua")
        rpp = self.path("probe.rpp")
        if os.path.exists(out):
            os.remove(out)
        with open(rpp, "w") as f:
            f.write('<REAPER_PROJECT 0.1 "7.0/linux-x86_64" 1721000000\n'
                    '  <TRACK\n    NAME "probe"\n  >\n>\n')
        with open(lua, "w") as f:
            f.write(self.PROBE_LUA % dict(out=out, fx=self.fx))
        subprocess.run(["reaper", "-newinst", "-nosplash", rpp, lua],
                       check=True, timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not os.path.exists(out):
            raise RuntimeError("probe wrote no output (stdout is not captured)")
        lines = open(out).read().splitlines()
        if not lines or lines[0] == "ADD_FAILED":
            raise RuntimeError("plugin failed to load: " + self.fx)
        names = {}
        for ln in lines[1:]:
            parts = ln.split("\t")
            names[int(parts[0])] = parts[1]
        return names, lines

    # -- debug build -------------------------------------------------------
    def build_debug_fx(self, src_path, tail, extra_slider=None,
                       after_slider=None, dst_name=None):
        """Generate <plugin>_dbg.jsfx from the real source on every run.

        Regenerating (rather than maintaining a second file) is what keeps the
        tested code from drifting from the shipped code. Delete it afterwards.

        `tail` is EEL2 appended to the end of @sample -- it is inserted just
        before the @gfx section, so the source must have one.
        """
        with open(src_path) as f:
            src = f.read()
        if extra_slider:
            anchor = "\n%s:" % after_slider
            if anchor not in src:
                raise RuntimeError("%s not found - source layout changed"
                                   % after_slider)
            src = re.sub(r"(?m)^(%s:.*)$" % re.escape(after_slider),
                         lambda m: m.group(1) + "\n" + extra_slider, src, 1)
        if "\n@gfx" not in src:
            raise RuntimeError("@gfx section not found - cannot place debug tail")
        head, sep, rest = src.partition("\n@gfx")
        src = head + tail + sep + rest
        dst = os.path.join(EFFECTS, dst_name or (self.slug + "_dbg.jsfx"))
        if os.path.islink(dst):
            os.remove(dst)
        with open(dst, "w") as f:
            f.write(src)
        return dst


# ---------------------------------------------------------------------------
# debug-value multiplexing
# ---------------------------------------------------------------------------
#
# To read internals that have no audible output, a debug build overwrites
# spl0/spl1 with internal values, one per SLOT samples, and the decoder reads
# them back from the render. Two hard constraints, both learned the hard way:
#
#   1. Every emitted sample MUST stay inside -1..1. REAPER zeroes a track's
#      ENTIRE render if the FX emits samples far outside that range -- a raw
#      -1000 "no data" sentinel silenced every sample, which is
#      indistinguishable from a dead plugin.
#   2. The counter free-runs from the plugin's first sample, which is NOT the
#      first sample of the render range (REAPER runs blocks before the range
#      starts). Emit a sync marker in the last slot and have the decoder find
#      the frame rather than assume it begins at sample 0.

DBG_SLOT = 64                   # samples per multiplexed value
DBG_SCALE = 0.002               # dB -> sample; 0.9/0.002 = 450 dB of headroom
DBG_MAGIC = 0.9876543           # sync marker; must not collide with real data


def decode_dbg(chans, nvals, at_sec, srate=48000, nslots=64,
               slot=DBG_SLOT, scale=DBG_SCALE, magic=DBG_MAGIC):
    """Decode one multiplexed frame at/just after `at_sec`.

    Read the frame while the input is still playing: REAPER appends a 1 s tail
    to every render, and analysis windows straddling the end of the item drag
    averages down by a dB or so. Each value is the MEDIAN of the slot's middle
    half, so slot-boundary transitions cannot skew it.
    """
    frame = nslots * slot
    ch0 = chans[0]
    start = int(at_sec * srate)
    hit = None
    for p in range(start, min(len(ch0), start + 2 * frame)):
        if abs(ch0[p] - magic) < 1e-5:
            hit = p
            break
    if hit is None:
        raise RuntimeError("debug sync marker not found near %.2f s" % at_sec)
    while hit > 0 and abs(ch0[hit - 1] - magic) < 1e-5:
        hit -= 1
    base = hit - (nslots - 1) * slot
    if base < 0 or base + frame > len(ch0):
        raise RuntimeError("debug frame at %.2f s is truncated" % at_sec)
    out = []
    for ch in chans[:2]:
        vals = []
        for k in range(nvals):
            seg = sorted(ch[base + k * slot + slot // 4:
                            base + k * slot + 3 * slot // 4])
            vals.append(seg[len(seg) // 2] / scale)
        out.append(vals)
    return out


# ---------------------------------------------------------------------------
# analysis helpers
# ---------------------------------------------------------------------------

def maxdiff(a, b, lo=0, hi=None):
    hi = len(a) if hi is None else hi
    return max(abs(x - y) for x, y in zip(a[lo:hi], b[lo:hi]))


def rms(x, lo=0, hi=None):
    import math
    seg = x[lo:hi]
    return math.sqrt(sum(v * v for v in seg) / max(len(seg), 1))


def bin_freq(target, srate=48000, n=16384):
    """Nearest frequency landing exactly on a DFT bin of an n-sample window.

    Using an exact bin frequency removes leakage entirely, which is what makes
    sub-0.01 dB gain assertions possible.
    """
    return round(target * n / srate) * srate / n


def dft_mag(x, f, srate=48000):
    """Rectangular-window magnitude. Only trustworthy when `f` is an exact bin
    of the window AND nothing else strong is present -- otherwise use
    dft_mag_hann: a 0.5-amplitude 200 Hz tone leaks 1.2e-3 into a 997 Hz
    rectangular probe, louder than most things worth measuring.
    """
    import math
    re = im = 0.0
    for n, v in enumerate(x):
        w = 2 * math.pi * f * n / srate
        re += v * math.cos(w)
        im -= v * math.sin(w)
    return 2.0 * math.sqrt(re * re + im * im) / len(x)


def dft_mag_hann(x, f, srate=48000):
    """Hann-windowed magnitude probe: sidelobes fall as 1/f^3, putting the
    leakage floor below 1e-6. Use this for any measurement near a loud tone."""
    import math
    n = len(x)
    re = im = 0.0
    for k, v in enumerate(x):
        w = 0.5 - 0.5 * math.cos(2 * math.pi * k / n)
        a = 2 * math.pi * f * k / srate
        re += v * w * math.cos(a)
        im -= v * w * math.sin(a)
    return 4.0 * math.sqrt(re * re + im * im) / n


def db(x, floor=1e-30):
    import math
    return 20 * math.log10(max(abs(x), floor))
