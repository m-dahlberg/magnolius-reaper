#!/usr/bin/env python3
"""Run the DeResonate suites that can be driven headlessly.

REAPER must already be running. This refuses to start it: `reaper -nonewinst`
silently BECOMES the instance when none exists, leaving a stray GUI REAPER
holding the audio device and rewriting ~/.config/REAPER on exit.
"""
import subprocess, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.expanduser("~/.claude/skills/reascript-lua/assets/reascript_test.py")

SUITES = [
    ("headless", "test/headless.lua", 120),
    ("selftest", "test/selftest_in_reaper.lua", 300),
    ("inject",   "test/inject_in_reaper.lua", 600),
    ("dereverb", "test/dereverb_in_reaper.lua", 900),
    ("gate",     "test/gate_in_reaper.lua", 900),
    ("t60calib", "test/t60_calib_in_reaper.lua", 900),
    ("sustain",  "test/sustained_in_reaper.lua", 900),
    ("verify",   "test/verify_edit_in_reaper.lua", 600),
]

def reaper_running():
    return subprocess.run(["pgrep", "-x", "reaper"],
                          capture_output=True).returncode == 0

def main():
    if not reaper_running():
        print("REAPER is not running. Start it first -- this harness will not,\n"
              "because -nonewinst becomes the instance and rewrites its config.")
        return 2
    bad = []
    for name, path, timeout in SUITES:
        print("=" * 62)
        print(name)
        print("=" * 62)
        r = subprocess.run([sys.executable, RUNNER, os.path.join(ROOT, path),
                            "--timeout", str(timeout)])
        if r.returncode != 0:
            bad.append(name)
    print("\n" + "=" * 62)
    print("FAILED: " + ", ".join(bad) if bad else "all suites passed")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
