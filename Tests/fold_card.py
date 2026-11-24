#!/usr/bin/env python3
"""⌘S moves the column, the page's card and the window's buttons together.

Build first (`./build.sh`), then `python3 Tests/fold_card.py`. A hidden probe
in a world of its own (split_view.py's harness); Bench "foldframes" stages
its window far off every screen and records, at every display frame of two
presses (away, then back), where the page is seen (the web view cut by every
layer above it that clips), the column's edge and the buttons' slide.

Before: the page was given its new size before the column slid away, and
kept it until the column was back, its card's round corners and edge
running 216 points past the window's right edge both ways; folded, a gap
and round corners stayed round the page; and the buttons, on an animation
of their own, ran a frame or two ahead of the column.
"""
import os, sys, time, json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import subprocess

sv.use("fold-card")
t = sv.T()

try:
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "layout.cards", "-bool", "true"])
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"{sv.BASE}/tall", "title": "tall"}, {"url": f"{sv.BASE}/a", "title": "a"}], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))
    sv.launch()
    sv.cmd({"do": "resize", "width": 1200, "height": 760, "steps": 1})
    time.sleep(2)
    sv.cmd({"do": "foldframes", "times": 2})  # staged, warmed up
    a = sv.cmd({"do": "foldframes", "times": 2, "track": True, "span": 0.6, "rest": 0.8})
    t.ok("staged off every screen", a["frame"][0] <= -10000, a["frame"])
    for p in a["presses"]:
        name = "away" if not p["was"] else "back"
        tr = [f for f in p["track"] if "card" in f]
        W, H = tr[0]["window"][2], tr[0]["window"][3]
        over = max(max(f["card"][0] + f["card"][2] - W, f["card"][1] + f["card"][3] - H) for f in tr)
        t.ok(f"{name}: the page never past the window's edge", over <= 0.5, over)
        widths = p["pageWidths"]
        t.ok(f"{name}: the page laid out at most once more", len(widths) <= 2, widths)
        rest = max(f["column"] for f in tr)
        lag = max(abs(f["lights"] - (f["column"] - rest)) for f in tr if not f["lightsHidden"])
        t.ok(f"{name}: the buttons ride the column's frames", lag <= 9, lag)
        folded = tr[-1] if name == "away" else tr[0]
        t.ok(f"{name}: folded, the page is the whole window, square",
             folded["card"] == [0, 0, W, H] and folded["radius"] == 0, folded)
        out = tr[0] if name == "away" else tr[-1]
        t.ok(f"{name}: out, the card has its gap and corners",
             W - out["card"][0] - out["card"][2] == 8 and out["radius"] == 10, out)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
