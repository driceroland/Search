#!/usr/bin/env python3
"""⌘S keeps 1.0.15's pace: the column slides on every frame, and the page
under it is neither drawn clear nor painted twice (idea 847).

Build first (`./build.sh`), then `python3 Tests/fold_pacing.py`. A hidden
probe in a world of its own (split_view.py's harness) opens a dozen tabs,
and Bench "foldframes" stages its window far off every screen, where it is
drawn at the display's pace and never seen, then presses ⌘S ten times with
the slide off and ten with Slide the column in and out on, timing every
display frame.

1.0.16 turned each page's own background off while it resized (#1250), the
column's slide included: WebKit painted the whole page again, clear, and
again half a second later, all through the slide, and the window server
stuttered over it (WindowServer's load, not Search's). ⌘S has its own cover
for the room a page grows into (Browser.cover), so the page now keeps its
background there. Measured against 1.0.15 the same way:

- the column moves on every frame of its slide: no gap between two of its
  frames longer than three display frames (one press in ten may have one,
  as 1.0.15's did, never past 50 ms), the 95th percentile one frame;
- the page is never drawn clear while the column moves;
- folding the column away paints the page no more than a page following
  the column's edge needs to (fold_follow.py; 1.0.15 and 1.0.17 resized it
  once, 1.0.16 painted it twice over, drawn clear);
- and a window made wider still clears its page's ground while WebKit
  catches up (#1250), and one made narrower doesn't, having nothing undrawn.
"""
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-pacing")
t = sv.T()
N = 12


def world():
    import json, os
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{sv.BASE}/long" if i == N - 1 else f"{sv.BASE}/tab-{i}", "title": f"tab {i}"} for i in range(N)]
    json.dump({"tabs": tabs, "active": N - 1}, open(f"{sv.SUPPORT}/session.json", "w"))


def painted(press):
    """The page's tiles given new contents over the press."""
    return sum(n for who, n in press["redrawers"].items() if who.startswith("WebActionDisablingCALayerDelegate"))


try:
    sv.setup(sidebar=True)
    world()
    sv.launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    import time
    time.sleep(2)
    sv.cmd({"do": "foldframes", "times": 2, "slides": False})  # staged, warmed up
    for slides in (False, True):
        name = "slide" if slides else "spring"
        a = sv.cmd({"do": "foldframes", "times": 10, "slides": slides})
        presses = a["presses"]
        frame = 1000 / (a["hz"] or 60)
        t.ok(f"{name}: staged off every screen", a["frame"][0] <= -10000, a["frame"])
        t.ok(f"{name}: every press moved the column", all(p["moved"] >= 8 for p in presses), [p["moved"] for p in presses])
        worst = sorted(p["worst"] for p in presses)
        t.ok(f"{name}: no gap past three frames, but in one press of ten", worst[-2] <= 3 * frame + 1, (worst, frame))
        t.ok(f"{name}: and none past 1.0.15's worst, 50 ms", worst[-1] <= 50, worst)
        p95 = statistics.median(p["p95"] for p in presses)
        t.ok(f"{name}: one frame between the column's frames", p95 <= frame + 1, (p95, frame))
        clear = [p["middle"].get("clearPages", 0) for p in presses]
        t.ok(f"{name}: the page is never drawn clear mid-slide", not any(clear), clear)
        away = statistics.median(painted(p) for p in presses if not p["was"])
        back = statistics.median(painted(p) for p in presses if p["was"])
        # The page follows the column (fold_follow.py): going away it is
        # drawn at each wider width it passes through, coming back it is
        # only cut narrower, so going away paints more (195 tiles against
        # 120 on springs, 22 Nov 2026). 1.0.16's second paint came with the
        # page drawn clear, which is checked for itself above.
        print(f"    {name}: tiles painted going away {away}, coming back {back}")
        t.ok(f"{name}: folding away paints the page no more than a page following the column does",
             away <= 2.5 * back + 10, (away, back))
    # #1250 kept: a window made wider still clears its page's own ground
    # while WebKit catches up, and gives it back; made narrower, nothing
    # is left undrawn, so nothing is cleared.
    sv.cmd({"do": "resize", "width": 1400, "height": 820, "steps": 4})
    c = sv.cmd({"do": "foldframes", "census": True})
    t.ok("grown: the page's ground cleared while it catches up (#1250)", c["clearPages"] >= 1, c["clearPages"])
    time.sleep(1)
    t.ok("…and given back after", sv.cmd({"do": "foldframes", "census": True})["clearPages"] == 0)
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 4})
    t.ok("narrowed: nothing cleared", sv.cmd({"do": "foldframes", "census": True})["clearPages"] == 0)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
