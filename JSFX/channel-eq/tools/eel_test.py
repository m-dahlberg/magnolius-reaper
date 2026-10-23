#!/usr/bin/env python3
"""Offline tests of the plugin's EEL2 code, run through WDL's loose_eel (no REAPER).

    ./eel_test.py              # everything
    ./eel_test.py design gproto

  design   the audio-side design (laws -> analog prototype -> matched biquad ->
           fit) gives the same coefficients as tools/model.py
  gproto   the panel's own copy of the laws and prototypes (g_*) gives the same
           analog prototypes as the audio side; the curve in @gfx cannot be run
           headlessly, so this is how a drift between the two copies is caught

Needs loose_eel:  git clone --depth 1 https://github.com/justinfrankel/WDL.git ~/src/WDL
                  make -C ~/src/WDL/WDL/eel2 NO_GFX=1 PORTABLE=1 loose_eel
"""
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model as M                                                   # noqa: E402

SRC = os.path.join(HERE, "..", "Magnolius_ChannelEQ.jsfx")
EEL = os.environ.get("LOOSE_EEL", os.path.expanduser("~/src/WDL/WDL/eel2/loose_eel"))

TOL_COEF = 1e-7        # EEL vs model: both run the same algorithm in doubles


def _src():
    with open(SRC) as f:
        return f.read()


def _consts():
    s = _src()
    return s[s.index("// ---- constants (mirror tools/model.py)"):s.index("// ---- start-up state")]


def _gblock():
    s = _src()
    return s[s.index("function g_pw_log"):s.index("// Rectangle outline of 1 logical px.")]


def run_eel(program):
    with tempfile.NamedTemporaryFile("w", suffix=".eel", delete=False) as f:
        f.write(program)
        path = f.name
    try:
        r = subprocess.run([EEL, path], capture_output=True, text=True, timeout=300)
    finally:
        os.remove(path)
    if r.returncode or "rror" in r.stderr:
        raise RuntimeError("loose_eel: " + (r.stderr or r.stdout)[:600])
    return r.stdout


def preamble(params, fs):
    p = "srate=%d;\n" % fs
    for k in M.NAMES:
        p += "%s=%r;\n" % (k, float(params[k]))
    return p + "function slider(n) ( 0; );\n"


def random_params(rng):
    p = dict(M.DEFAULTS)
    for k in ("lf_g", "lmf_g", "hmf_g", "hf_g"):
        p[k] = rng.choice([-1, -.5, 0, 0.3, 0.7, 1.0, rng.uniform(-1, 1)])
    for k in ("lf_f", "lmf_f", "hmf_f", "hf_f", "lmf_q", "hmf_q"):
        p[k] = rng.random()
    p["hpf"] = rng.choice([0, 0.05, 0.3, 0.7, 1.0])
    p["lpf"] = rng.choice([1.0, 0.9, 0.5, 0.0])
    p["hmf_x3"] = rng.choice([0, 1])
    p["lmf_d3"] = rng.choice([0, 1])
    p["gain_law"] = rng.choice([0, 1])
    p["flt_in"] = rng.choice([1, 1, 1, 0])
    p["eq_in"] = rng.choice([1, 1, 1, 0])
    return p


def test_design(n=40):
    rng = random.Random(3)
    worst = 0.0
    for _ in range(n):
        fs = rng.choice([44100, 48000, 96000])
        p = random_params(rng)
        prog = preamble(p, fs) + _consts()
        prog += ("kg=1;\nbuild_proto_hp(); build_proto_lp(); build_proto_hf(); build_proto_hmf();"
                 " build_proto_lf(); build_proto_lmf();\n"
                 "s=0; loop(NSEC, design_slot(s); s+=1;);\n"
                 "s=0; loop(35, printf(\"%.17g\\n\", M_TGT[s]); s+=1;);\n")
        vals = [float(x) for x in run_eel(prog).split()]
        ref = M.targets(p, fs)
        for i in range(7):
            for k in range(5):
                worst = max(worst, abs(vals[i * 5 + k] - ref[i][k]))
    return worst < TOL_COEF, "worst coefficient difference %.3g over %d settings" % (worst, n)


def test_gproto(n=40):
    rng = random.Random(8)
    worst = 0.0
    for _ in range(n):
        p = random_params(rng)
        prog = preamble(p, 96000) + _consts() + _gblock()
        prog += ("build_proto_hp(); build_proto_lp(); build_proto_hf(); build_proto_hmf();"
                 " build_proto_lf(); build_proto_lmf();\ng_protos();\n"
                 "s=0; loop(7, k=0; loop(7, a=M_PROTO[s*8+k]; b=G_PROTO[s*8+k];"
                 " printf(\"%.17g %.17g\\n\", a, b); k+=1;); s+=1;);\n")
        for line in run_eel(prog).splitlines():
            a, b = (float(v) for v in line.split())
            worst = max(worst, abs(a - b) / max(abs(a), 1e-30))
    return worst < 1e-9, "worst relative difference between audio and panel prototypes %.3g" % worst


TESTS = [("design", test_design), ("gproto", test_gproto)]

if __name__ == "__main__":
    sel = sys.argv[1:]
    bad = 0
    ran = 0
    for name, fn in TESTS:
        if sel and name not in sel:
            continue
        ran += 1
        try:
            ok, msg = fn()
        except Exception as e:                                      # noqa: BLE001
            ok, msg = False, "EXCEPTION %s" % e
        print("%-10s %s  %s" % (name, "PASS" if ok else "FAIL", msg))
        bad += not ok
    print("----\n%d/%d passed" % (ran - bad, ran))
    sys.exit(1 if bad else 0)
