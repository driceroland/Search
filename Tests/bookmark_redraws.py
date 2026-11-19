#!/usr/bin/env python3
"""Bookmarks kept and let go, measured, with 20 tabs and 200 down the side.

Build first (`./build.sh`), then `python3 Tests/bookmark_redraws.py`. A
hidden probe (tabs down the side, the bookmarks bar on, one bookmark already
kept so the bar is up throughout) restores a session of N tabs (lazy, so no
page loads but the one on screen), and Bench "bookmarksweep" keeps 10
bookmarks and then lets them go, one a frame.

The bookmarks bar shows them, so it is built again at each edit ("bar").
The column's rows show none of them ("row"), so an edit builds none of
them; built again at every edit they were the tabs times the edits. Also
printed: the main run loop's passes that carried an edit, in milliseconds.
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmark-redraws")
SWEEPS = 3
COUNT = 10


def world(n):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{sv.BASE}/tab-{i}", "title": f"Tab {i}"} for i in range(n)]
    json.dump({"tabs": tabs, "active": 0}, open(f"{sv.SUPPORT}/session.json", "w"))
    resident = [{"id": str(uuid.uuid4()).upper(), "title": "Resident", "url": "https://resident.test/"}]
    json.dump(resident, open(f"{sv.SUPPORT}/bookmarks.json", "w"))


def measure(n):
    sv.setup(sidebar=True, **{"bookmarks.bar": True})
    world(n)
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(1.5)
    sv.cmd({"do": "bookmarksweep", "count": COUNT})  # warm-up, not counted
    runs = [sv.cmd({"do": "bookmarksweep", "count": COUNT}) for _ in range(SWEEPS)]
    sv.quit()
    for r in runs:
        if r["left"] != 1:
            raise RuntimeError(f"a sweep left {r['left']} bookmarks, not the resident one")
    edits = sum(r["edits"] for r in runs)
    bodies = {}
    for r in runs:
        for k, v in r["bodies"].items():
            bodies[k] = bodies.get(k, 0) + v
    return {
        "tabs": runs[0]["tabs"], "edits": edits,
        "perEdit": {k: round(v / edits, 2) for k, v in sorted(bodies.items())},
        "editP50": round(sorted(r["editMs"]["p50"] for r in runs)[1], 3),
        "editP95": round(max(r["editMs"]["p95"] for r in runs), 3),
        "editMax": round(max(r["editMs"]["max"] for r in runs), 3),
    }


if __name__ == "__main__":
    t = sv.T()
    try:
        for n in [int(a) for a in sys.argv[1:]] or [20, 200]:
            m = measure(n)
            print(json.dumps(m), flush=True)
            per = m["perEdit"]
            t.ok(f"{n} tabs: the bookmarks bar is built again at each edit ({per.get('bar', 0)})",
                 per.get("bar", 0) >= 1, per)
            t.ok(f"{n} tabs: an edit builds no row of the column ({per.get('row', 0)})",
                 per.get("row", 0) == 0, per)
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
