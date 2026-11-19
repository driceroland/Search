#!/usr/bin/env python3
"""Switching between two spaces of many tabs, timed.

Build first (`./build.sh`), then `python3 Tests/space_switch_time.py`. A
hidden probe starts with two spaces of N tabs each (lazy, so no page loads
but the one on screen), the tabs down the side, and Bench "spacetime"
switches back and forth, as ⌃1 and ⌃2 would; with --swipe, Bench
"swipetime" swipes there and back over the column instead, a frame a move.

For each N it prints how long the switch held the main thread, how long
the main run loop was busy in all over the next 0.7 s (SwiftUI's update,
layout, Core Animation's commit and the frames of any animation), and the
rows built over that time.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-switch-time")
SECOND = "5E4C0000-0000-4000-8000-0000000000B2"
SWITCHES = 6


def world(n):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    spaces = [{"id": sv.FIRST_SPACE.upper(), "name": "One", "colour": 0, "sharesSignIns": True},
              {"id": SECOND, "name": "Two", "colour": 0, "sharesSignIns": True}]
    json.dump(spaces, open(f"{sv.SUPPORT}/spaces.json", "w"))
    for name, file, active in (("one", "session.json", n - 1), ("two", f"session-{SECOND}.json", n // 2)):
        tabs = [{"url": f"{sv.BASE}/{name}-{i}", "title": f"{name} {i}"} for i in range(n)]
        json.dump({"tabs": tabs, "active": active}, open(f"{sv.SUPPORT}/{file}", "w"))


SWIPE = "--swipe" in sys.argv
# ⌃1–⌃9 slid in, as on screen; without, switched at once as a hidden window does.
GLIDE = "--glide" in sys.argv


def switch(i):
    if SWIPE:
        # Fingers to the left bring the next space; to the right, the one before.
        return sv.cmd({"do": "swipetime", "dx": -200 if i % 2 == 0 else 200})
    return sv.cmd({"do": "spacetime", "index": 2 - i % 2, "glide": GLIDE})


def measure(n):
    sv.setup(sidebar=True, spaces=True)
    world(n)
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(1.5)
    switch(0)  # warm-up, not counted
    switch(1)
    runs = [switch(i) for i in range(SWITCHES)]
    sv.quit()
    for r in runs:
        if SWIPE and not r["landed"]:
            raise RuntimeError(f"a swipe didn't land: {r['space']}")
        if r["tabs"] < n:
            raise RuntimeError(f"a switch landed on a short row: {r['space']}, {r['tabs']} tabs")
    calls = sorted(r.get("callMs", 0) for r in runs)
    busy = sorted(sum(p["ms"] for p in r["passes"]) for r in runs)
    longest = sorted(max(p["ms"] for p in r["passes"]) for r in runs)
    rows = sorted(sum(p["rows"] for p in r["passes"]) for r in runs)
    return {"tabs": n, "callMedianMs": calls[len(calls) // 2], "busyMedianMs": round(busy[len(busy) // 2], 1),
            "longestPassMedianMs": longest[len(longest) // 2], "rowsMedian": rows[len(rows) // 2]}


try:
    for n in [int(a) for a in sys.argv[1:] if a.isdigit()] or [20, 200]:
        print(json.dumps(measure(n)))
finally:
    sv.finish()
