#!/usr/bin/env python3
"""Run test/panel_in_reaper.lua and wait for its result.

The panel suite must be a deferred script -- ImGui will not draw outside the
defer cycle -- and reascript_test.py reports success as soon as the file
finishes LOADING, before any frame has been drawn. So this launches it and
polls for the result file the suite writes itself.
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SUITE = os.path.join(ROOT, "test", "panel_in_reaper.lua")
RESULT = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                      "trackmanager-panel-result.txt")
TIMEOUT = 60


def main():
    if subprocess.call(["pgrep", "-x", "reaper"], stdout=subprocess.DEVNULL):
        sys.exit("REAPER is not running. Open it first -- this runner will not,\n"
                 "because -nonewinst would become the instance.")
    if os.path.exists(RESULT):
        os.remove(RESULT)

    subprocess.check_call(["reaper", "-nonewinst", SUITE])

    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        if os.path.exists(RESULT):
            time.sleep(0.2)                      # let the write settle
            with open(RESULT) as fh:
                text = fh.read()
            if "RESULT OK" in text or "RESULT FAIL" in text:
                print(text, end="")
                return 0 if "RESULT OK" in text else 1
        time.sleep(0.25)

    sys.exit("timed out after %ds waiting for %s -- is a modal dialog open in "
             "REAPER?" % (TIMEOUT, RESULT))


if __name__ == "__main__":
    sys.exit(main())
