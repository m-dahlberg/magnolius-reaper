#!/usr/bin/env python3
"""Write the IR index that Magnolius_ConvolutionReverb.jsfx's built-in browser reads.

The browser needs a list of IR filenames, and JSFX has no way to enumerate a
directory: REAPER's host owns the file-slider index->filename mapping and a
plugin can neither read the whole list nor write the slider's value (setting it
from code, even via slider_automate, changes the number but not the file). So
the browser loads by path with file_open(#string) and gets its names from this
plain-text index.

Output: <resource>/Data/ConvReverbIRs.idx — one IR path per line, relative to
<resource>/Data/ReverbIRs, forward slashes, sorted case-insensitively.

The file deliberately lives in Data/ and NOT inside Data/ReverbIRs: anything
inside that folder also shows up in the Reverb IR file slider's dropdown.

Re-run whenever you add or remove IRs, then press Rescan in the plugin.
tools/RescanReverbIRs.lua does the same thing from inside REAPER.

Usage:
  index_irs.py [resource_dir]        # default ~/.config/REAPER
"""
import os
import sys

EXTS = (".wav",)


def main():
    res = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.config/REAPER")
    irdir = os.path.join(res, "Data", "ReverbIRs")
    out = os.path.join(res, "Data", "ConvReverbIRs.idx")
    if not os.path.isdir(irdir):
        sys.exit("no IR directory: %s" % irdir)

    names = []
    for root, dirs, files in os.walk(irdir):
        dirs.sort()
        for f in files:
            if f.lower().endswith(EXTS):
                rel = os.path.relpath(os.path.join(root, f), irdir)
                names.append(rel.replace(os.sep, "/"))
    names.sort(key=lambda s: s.lower())

    with open(out, "w") as fh:
        fh.write("".join(n + "\n" for n in names))
    print("wrote %d IRs to %s" % (len(names), out))


if __name__ == "__main__":
    main()
