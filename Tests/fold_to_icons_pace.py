#!/usr/bin/env python3
"""⌘S to icons only keeps the display's pace with several spaces (idea 927).

Build first (`./build.sh`), then `python3 Tests/fold_to_icons_pace.py`. A
hidden probe in a world of its own (split_view.py's harness) has three
spaces of 25 tabs and "⌘S makes the column icons only" on, with Slide the
column in and out; Bench "foldframes" stages its window far off every
screen, where it is drawn at the display's pace and never seen, and presses
⌘S ten times, timing every display frame.

Since 1.0.16 the column keeps every space's rows out of sight for a swipe
(SideBar.others). ⌘S glides the column's width between icons and titles,
and those rows were laid out again at every width it passed through: with
three spaces the main thread missed every other frame (frames 20 ms apart
at 120 Hz against 8 with one space, 1.0.15's pace). They are left out
while the width glides, and made again once it rests (Browser.columnTurning). Checked: the display's frames come
one frame apart (95th percentile), every press.
"""
import json
import os
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-to-icons-pace")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper(), "5E4C0000-0000-4000-8000-0000000000B2", "5E4C0000-0000-4000-8000-0000000000B3"]


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": i, "name": f"S{n}", "colour": n + 2, "sharesSignIns": True} for n, i in enumerate(IDS)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for n, i in enumerate(IDS):
        tabs = [{"url": f"{sv.BASE}/s{n}-{k}", "title": f"space {n} tab {k}"} for k in range(24)]
        tabs.append({"url": f"{sv.BASE}/long", "title": "long"})
        json.dump({"tabs": tabs, "active": len(tabs) - 1},
                  open(f"{sv.SUPPORT}/" + ("session.json" if n == 0 else f"session-{i}.json"), "w"))


try:
    sv.setup(**{"sidebar": True, "spaces": True, "sidebar.foldIcons": True, "sidebar.icons": True})
    world()
    sv.launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    time.sleep(3)
    sv.cmd({"do": "foldframes", "times": 2, "slides": True})  # staged, warmed up
    a = sv.cmd({"do": "foldframes", "times": 10, "slides": True})
    frame = 1000 / (a["hz"] or 60)
    presses = a["presses"]
    t.ok("staged off every screen", a["frame"][0] <= -10000, a["frame"])
    t.ok("⌘S turned the column, never folded it", not any(p["folded"] for p in presses))
    p95 = statistics.median(p["tickP95"] for p in presses)
    print(f"    display frames' 95th percentile {p95} ms (a frame is {frame:.1f}),"
          f" main thread {statistics.median(p['cpuMs'] for p in presses)} ms a press")
    t.ok("the display's frames come one frame apart while the column turns", p95 <= frame + 1, (p95, frame))
    t.ok("…every press", sum(p["tickP95"] > 2 * frame + 1 for p in presses) <= 1, [p["tickP95"] for p in presses])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
