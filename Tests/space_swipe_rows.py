#!/usr/bin/env python3
"""Two fingers sideways between spaces, measured, with 20 tabs and 200,
down the side and across the top.

Build first (`./build.sh`), then `python3 Tests/space_swipe_rows.py`. A
hidden probe (spaces on) restores a session of N tabs (lazy, so no page
loads but the one on screen), makes a second space and goes back to the
first, and Bench "swipesweep" moves the fingers 40 times, one a frame,
toward the second space, then lets go short of it so the rows settle back.

The swipe moves the pages and nothing in them changes (see SpacePages),
and a row is drawn again only when what it shows changes, so the rows
("row", down the side) or pills ("pill", across the top) built over the
whole swipe are the space coming in, once: within the tabs once over,
however many moves it took. With the swipe on the Browser they were the
tabs times the moves (798 with 20 tabs, 7638 with 200, 2026-11-01). Also
printed: the main run loop's passes that carried a move, in milliseconds.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-swipe-rows")
SWEEPS = 3
MOVES = 40


def session(n):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{sv.BASE}/tab-{i}", "title": f"Tab {i}"} for i in range(n)]
    json.dump({"tabs": tabs, "active": 0}, open(f"{sv.SUPPORT}/session.json", "w"))


def measure(n, sidebar):
    sv.setup(sidebar=sidebar, spaces=True)
    session(n)
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    sv.cmd({"do": "space", "action": "new", "name": "Second"})
    sv.cmd({"do": "space", "action": "go", "index": 1})
    time.sleep(1.5)
    sv.cmd({"do": "swipesweep", "moves": MOVES})  # warm-up, not counted
    time.sleep(0.5)
    runs = []
    for _ in range(SWEEPS):
        runs.append(sv.cmd({"do": "swipesweep", "moves": MOVES}))
        time.sleep(0.5)
    landed = sv.cmd({"do": "space"})
    sv.quit()
    if landed["current"] == "Second":
        raise RuntimeError("a sweep let go short of the second space, and it came anyway")
    bodies = {}
    for r in runs:
        for k, v in r["bodies"].items():
            bodies[k] = bodies.get(k, 0) + v
    return {
        "tabs": runs[0]["tabs"], "side": sidebar, "moves": MOVES,
        "perSwipe": {k: round(v / SWEEPS, 1) for k, v in sorted(bodies.items())},
        "moveP50": round(sorted(r["moveMs"]["p50"] for r in runs)[1], 3),
        "moveP95": round(max(r["moveMs"]["p95"] for r in runs), 3),
        "moveMax": round(max(r["moveMs"]["max"] for r in runs), 3),
    }


if __name__ == "__main__":
    t = sv.T()
    try:
        for n in [int(a) for a in sys.argv[1:]] or [20, 200]:
            for sidebar in [True, False]:
                m = measure(n, sidebar)
                print(json.dumps(m), flush=True)
                built = m["perSwipe"].get("row" if sidebar else "pill", 0)
                where = "down the side" if sidebar else "across the top"
                t.ok(f"{n} tabs {where}: {built} built in a swipe of {MOVES} moves, within {n}",
                     0 < built <= n, m["perSwipe"])
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
