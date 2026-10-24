"""The pointer crossing the sidebar's rows, measured, with 20 tabs and 200.

Build first (`./build.sh`), then `python3 Tests/side_hover.py`. A hidden
probe restores a session of N tabs (lazy, so no page loads but the one on
screen), puts the tabs down the side, and Bench "hoversweep" moves the
pointer down the visible rows and back, one row a frame.

For each it prints the rows built per crossing (two is the floor: the row
left and the row entered) and the main run loop's passes that carried a
pointer move (SwiftUI update, layout, Core Animation commit), in
milliseconds. A hidden probe gets no real pointer, so each row's own hover
handler is called, exit then enter, as AppKit would; SwiftUI's finding of
the row under the pointer and the GPU's part are not in it.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("side-hover")
SWEEPS = 3


def session(n):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{sv.BASE}/tab-{i}", "title": f"Tab {i}"} for i in range(n)]
    # The live one at the end, below every row the sweep crosses.
    json.dump({"tabs": tabs, "active": n - 1}, open(f"{sv.SUPPORT}/session.json", "w"))


def measure(n):
    sv.setup(sidebar=True)
    session(n)
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(1.5)
    sv.cmd({"do": "hoversweep"})  # warm-up, not counted
    runs = [sv.cmd({"do": "hoversweep"}) for _ in range(SWEEPS)]
    sv.quit()
    for r in runs:
        if not r["crossingMs"].get("count"):
            raise RuntimeError(f"a sweep timed no crossings: {r}")
    crossings = sum(r["crossings"] for r in runs)
    bodies = {}
    for r in runs:
        for k, v in r["bodies"].items():
            bodies[k] = bodies.get(k, 0) + v
    return {
        "tabs": runs[0]["tabs"], "rows": runs[0]["rows"], "crossings": crossings,
        "perCrossing": {k: round(v / crossings, 2) for k, v in sorted(bodies.items())},
        "crossingP50": round(sorted(r["crossingMs"]["p50"] for r in runs)[1], 3),
        "crossingP95": round(max(r["crossingMs"]["p95"] for r in runs), 3),
        "crossingMax": round(max(r["crossingMs"]["max"] for r in runs), 3),
        "crossingMean": round(sum(r["crossingMs"]["total"] for r in runs) / sum(r["crossingMs"]["count"] for r in runs), 3),
        # Everything else the main thread did during the sweeps (animation
        # frames, timers), per crossing: work a change only moved elsewhere.
        "otherPerCrossing": round(sum(r["otherMs"].get("total", 0) for r in runs) / crossings, 3),
    }


if __name__ == "__main__":
    try:
        for n in [int(a) for a in sys.argv[1:]] or [20, 200]:
            print(json.dumps(measure(n)), flush=True)
    finally:
        sv.finish()
