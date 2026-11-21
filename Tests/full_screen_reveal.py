#!/usr/bin/env python3
"""The top bars follow the menu bar's reveal in full screen, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/full_screen_reveal.py`.
Nothing goes full screen. With the tabs on top and the bookmarks bar on, the
window is told it is in full screen and that macOS has brought its menu bar
and the bar with the window's buttons down over the top by 60 points
(bench `fullscreen` and `reveal`), and what lies under points of the window
is asked: the strip of tabs and the bookmarks bar are 60 points lower, and
the room that was theirs is the ground, not them. With nothing revealed
they are where they were. The real thing, a pointer at the top of a window
in full screen, is checked by hand on a release candidate (idea 854).
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("full-reveal")
TREE = [{"id": str(uuid.uuid4()).upper(), "title": "Alpha", "url": "https://alpha.example/"}]


def at(y):
    return sv.cmd({"do": "hit", "x": 400, "y": y})["view"][:14]


def column(ys):
    return [at(y) for y in ys]


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=False, **{"bookmarks.bar": True})
        os.makedirs(sv.SUPPORT, exist_ok=True)
        json.dump(TREE, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        time.sleep(1)
        ys = list(range(4, 160, 4))
        before = column(ys)
        sv.cmd({"do": "ui", "fullscreen": True}); time.sleep(0.8)
        full = column(ys)
        t.ok("full screen alone moves nothing", full == before, list(zip(ys, full)))
        sv.cmd({"do": "ui", "reveal": 60.0}); time.sleep(1.5)
        down = column(ys)
        def first(col, kind):
            return next((y for y, v in zip(ys, col) if v == kind), None)
        t.ok("revealed: the tabs start 60 points lower", first(before, "Strip") == 4 and first(down, "Strip") == 60,
             (first(before, "Strip"), first(down, "Strip")))
        t.ok("revealed: the page starts 60 points lower", abs(first(down, "StageView") - first(before, "StageView") - 60) <= 4,
             (first(before, "StageView"), first(down, "StageView")))
        t.ok("revealed: nothing of the bars is under the menu bar", "Strip" not in down[:14], down[:14])
        sv.cmd({"do": "ui", "reveal": 0.0}); time.sleep(1.5)
        t.ok("hidden again: back where they were", column(ys) == before)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
