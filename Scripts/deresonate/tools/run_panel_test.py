#!/usr/bin/env python3
"""Drive the deferred panel suite and poll for its result file.

reascript_test.py cannot judge this one: it reports success as soon as the file
finishes loading, before a single frame has been drawn.
"""
import subprocess, sys, os, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULT = os.path.join(os.environ.get("TMPDIR", "/tmp"), "deresonate-panel-result.txt")

def main():
    if subprocess.run(["pgrep", "-x", "reaper"], capture_output=True).returncode != 0:
        print("REAPER is not running; start it first.")
        return 2
    if os.path.exists(RESULT):
        os.remove(RESULT)
    subprocess.run(["reaper", "-nonewinst",
                    os.path.join(ROOT, "test/panel_in_reaper.lua")])
    for _ in range(300):
        if os.path.exists(RESULT):
            txt = open(RESULT).read().strip()
            print(txt)
            return 0 if txt.startswith("RESULT OK") else 1
        time.sleep(0.1)
    print("timed out waiting for the panel to report")
    return 1

if __name__ == "__main__":
    sys.exit(main())
