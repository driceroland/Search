#!/usr/bin/env python3
"""A space swipe and a column scroll, every display frame timed (idea 1051).

Build first (`./build.sh`), then `python3 Tests/space_pace.py [rounds]`. A
hidden probe starts with 3 spaces of 60 tabs, 12 of the first pinned, the
tabs down the side; Bench "paceframes" stages its window far off every
screen (FoldFrames.stage), so it draws at the display's pace and nothing
shows, then swipes from space to space over the column, scrolls the column
with a trackpad stroke and its glide, and with a mouse's notches.

Prints one JSON line of medians for each: the gaps between frames (p95,
max; late: over 13 ms), the main thread's busy time and its longest pass,
the CPU used and the rows built. At 120 Hz a frame is 8.3 ms. The display
sets the pace, not the app: a ProMotion display can run at 60 Hz for a
whole run (gapMedian 16.7), and every other frame then reads as late
whatever the app does; such a run says nothing about the app.
"""
import json
import os
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-pace")
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 6
IDS = [sv.FIRST_SPACE.upper(), "5E4C0000-0000-4000-8000-0000000010B2", "5E4C0000-0000-4000-8000-0000000010B3"]
KEYS = ("gapMedian", "gapP95", "gapMax", "late", "busyMs", "longestPass", "cpuMs", "rows")


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": i, "name": f"S{n}", "colour": n + 2, "sharesSignIns": True} for n, i in enumerate(IDS)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for n, i in enumerate(IDS):
        tabs = [{"url": f"{sv.BASE}/s{n}-{k}", "title": f"space {n} tab {k} with a longer title"} for k in range(60)]
        json.dump({"tabs": tabs, "active": 30},
                  open(f"{sv.SUPPORT}/" + ("session.json" if n == 0 else f"session-{i}.json"), "w"))


def med(rs, k): return round(statistics.median(r[k] for r in rs), 1)


try:
    sv.setup(sidebar=True, spaces=True)
    world()
    sv.launch()
    sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
    time.sleep(2)
    tabs = sv.sp("state")["tabs"]
    for x in tabs[:12]:
        sv.cmd({"do": "pin", "id": x["id"]})
    time.sleep(1.5)
    out = {"pins": sum(1 for x in sv.sp("state")["tabs"] if x.get("staysReason") == "pinned"), "tabs": len(tabs)}
    # Warmed up: the first swipes build what every later one reuses.
    for dx in (-240, 240):
        sv.cmd({"do": "paceframes", "kind": "swipe", "tail": 1.2, "dx": dx}); time.sleep(0.5)
    swipes, strokes, notches = [], [], []
    for r in range(ROUNDS):
        a = sv.cmd({"do": "paceframes", "kind": "swipe", "tail": 1.2, "dx": -240 if r % 2 == 0 else 240})
        if not a["landed"]:
            raise RuntimeError(f"a swipe didn't land: {a}")
        swipes.append(a); time.sleep(0.4)
    for r in range(ROUNDS):
        strokes.append(sv.cmd({"do": "paceframes", "kind": "scroll", "dy": -14 if r % 2 == 0 else 14, "steps": 40, "glide": 50}))
        time.sleep(0.4)
    for r in range(ROUNDS):
        notches.append(sv.cmd({"do": "paceframes", "kind": "scroll", "wheel": True, "dy": -40 if r % 2 == 0 else 40,
                               "steps": 30, "every": 1 / 60}))
        time.sleep(0.4)
    for name, rs in (("swipe", swipes), ("scroll", strokes), ("wheel", notches)):
        out[name] = {k: med(rs, k) for k in KEYS}
    out["hz"] = swipes[0]["hz"]
    # Each stroke moved the column, there and back.
    out["scrolled"] = [round(a["offsetTo"] - a["offsetFrom"]) for a in strokes]
    print(json.dumps(out))
finally:
    sv.finish()
