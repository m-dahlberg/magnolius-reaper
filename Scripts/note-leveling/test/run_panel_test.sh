#!/usr/bin/env bash
# Run test/panel_in_reaper.lua and wait for its result file.
#
# It cannot go through reascript_test.py: that harness reports completion when
# the file finishes loading, which for a deferred panel is before it has drawn
# anything. See the header of panel_in_reaper.lua.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
result="$here/panel_result.txt"

pgrep -x reaper >/dev/null || { echo "no REAPER running"; exit 1; }

rm -f "$result"
reaper -nonewinst "$here/panel_in_reaper.lua" >/dev/null 2>&1

for _ in $(seq 1 60); do
  if [ -f "$result" ] && grep -q __PANEL_DONE__ "$result"; then
    sed '/__PANEL_DONE__/d' "$result"
    code=$(sed -n 's/.*__PANEL_DONE__ //p' "$result")
    rm -f "$result"
    exit "${code:-1}"
  fi
  sleep 0.5
done

echo "timed out waiting for the panel to report"
exit 1
