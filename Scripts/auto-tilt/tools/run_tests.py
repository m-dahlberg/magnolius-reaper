#!/usr/bin/env python3
"""Run every AutoTilt suite inside the already-running REAPER.

There is no system lua on this machine, so REAPER's embedded 5.4 stands in for
it -- which also means REAPER has to be open. The runner refuses to start one:
`reaper -nonewinst` silently BECOMES the instance when none is running, leaving
a stray GUI REAPER holding the audio device and rewriting ~/.config/REAPER on
exit.

    python3 tools/run_tests.py            # everything
    python3 tools/run_tests.py headless   # one suite, by name

Exits non-zero if any suite fails.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HARNESS = os.path.expanduser(
    "~/.claude/skills/reascript-lua/assets/reascript_test.py")

SUITES = [
    ("headless", "test/headless.lua", 120),
    ("selftest", "test/selftest_in_reaper.lua", 300),
    ("verify", "test/verify_edit_in_reaper.lua", 600),
]


def main():
    if not os.path.exists(HARNESS):
        sys.exit("the reascript-lua harness is missing: %s" % HARNESS)
    if subprocess.call(["pgrep", "-x", "reaper"], stdout=subprocess.DEVNULL):
        sys.exit("REAPER is not running. Open it first -- this runner will not,\n"
                 "because -nonewinst would become the instance and clobber the\n"
                 "resource directory on exit.")

    want = sys.argv[1:]
    picked = [s for s in SUITES if not want or s[0] in want]
    if not picked:
        sys.exit("no suite matched %s; known: %s"
                 % (want, ", ".join(s[0] for s in SUITES)))

    failed = []
    for name, path, timeout in picked:
        print("=" * 62)
        print("AutoTilt: %s" % name)
        print("=" * 62)
        rc = subprocess.call(
            [sys.executable, HARNESS, os.path.join(ROOT, path),
             "--timeout", str(timeout)])
        if rc != 0:
            failed.append(name)

    print()
    if failed:
        print("FAILED: %s" % ", ".join(failed))
        return 1
    print("all suites passed (%s)" % ", ".join(s[0] for s in picked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
