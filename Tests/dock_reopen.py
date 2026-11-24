#!/usr/bin/env python3
"""Search's Dock icon brings a browser window forward, and every window is in
the Window menu (idea 1047).

Build first (`./build.sh`), then `python3 Tests/dock_reopen.py`. It uses the
split suite's harness in a world of its own: started hidden, no window shown
or brought forward, everything removed afterwards.

A hidden probe's window is never minimised, covered or on another Space, and
a test run ignores the Dock's reopen, so the bench's `seam` tells the window
it is minimised or out of sight and asks what a click on the Dock icon would
do (`reopen`, with what AppKit says of the app's windows). The floating
video, a download's or a recording's panel is a window AppKit counts as
shown: with the browser's window minimised or out of sight, the click did
nothing, and the window stayed where it was.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("dock-reopen")
t = sv.T()


def seam(**f):
    return sv.cmd({"do": "seam", **f})


try:
    sv.setup(sidebar=True); sv.launch()
    sv.page("one"); time.sleep(0.8)

    a = seam(visible=True, minimized=False, reopen=True)
    t.ok("in sight: the Dock's click is macOS's own", a["reopens"] is False, a)
    a = seam(minimized=True, reopen=False)
    t.ok("minimised, nothing else shown: a window comes", a["reopens"] is True and a["minimized"], a)
    a = seam(minimized=True, reopen=True)
    t.ok("minimised, the floating video up: a window comes", a["reopens"] is True, a)
    a = seam(minimized=False, visible=False, reopen=True)
    t.ok("out of sight (covered, another Space), the floating video up: a window comes", a["reopens"] is True, a)
    seam(real=True)

    # Two windows: both in the Window menu (and the Dock icon's), which is
    # where ⌘` and the Dock's list find them.
    ws = sv.cmd({"do": "windows", "action": "new"})["windows"]
    t.ok("two windows", len(ws) == 2, ws)
    t.ok("every window is in the Window menu, the first one included",
         all(w["inWindowMenu"] for w in ws), [(w["n"], w["scene"], w["inWindowMenu"]) for w in ws])
    a = seam()
    browsers = [w for w in a["windows"] if w["browser"]]
    t.ok("…and none is left out of ⌘`'s round", all(w["key"] and not (w["behavior"] & 64) for w in browsers), browsers)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
