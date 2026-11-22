#!/usr/bin/env python3
"""The top bars follow the menu bar's reveal in full screen, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/full_screen_reveal.py`.
Nothing goes full screen. In both layouts, the tabs in the column and the
tabs across the top, each with the bookmarks bar off and on, the window is
told it is in full screen and that macOS has brought its menu bar and the
bar with the window's buttons down over the top by 60 points (bench
`fullscreen` and `reveal`), and what lies under points of the window is
asked, down three lines across it (the column or the start of the strip,
the middle, the far end): nothing of Search's own, no tab, no bookmark, no
band, no page, lies under the 60 points that came down (idea 926), and
everything that was at the top is exactly 60 points lower. With nothing
revealed they are where they were. How far the reveal comes down is
measured from the title bar macOS brings down (FullScreenReveal), which
only a real full screen has: that part is in FullScreenRevealTests, and the
real thing, a pointer at the top of a window in full screen, is checked by
hand on a release candidate (ideas 854, 926).
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
REVEAL = 60
YS = list(range(2, 200, 2))
# macOS's own title bar (the window's buttons): what comes down, not Search's.
THEIRS = ("_NSTheme", "NSTitlebar", "NSThemeFrame")


def at(x, y):
    v = sv.cmd({"do": "hit", "x": x, "y": y})["view"][:14]
    return "" if v.startswith(THEIRS) else v


def lines(xs):
    return {x: [at(x, y) for y in YS] for x in xs}


def first(col, kind):
    return next((y for y, v in zip(YS, col) if v == kind), None)


def main():
    t = sv.T()
    try:
        for sidebar in (True, False):
            for marks in (False, True):
                name = ("column" if sidebar else "tabs on top") + (", bookmarks bar" if marks else "")
                sv.setup(sidebar=sidebar, **{"bookmarks.bar": marks})
                os.makedirs(sv.SUPPORT, exist_ok=True)
                json.dump(TREE, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
                sv.launch()
                tab = sv.page("long")
                sv.cmd({"do": "select", "id": tab}); time.sleep(1)
                xs = [30, 400, 900]
                # Full screen takes away the room kept for the window's
                # buttons (idea 184); that is where the reveal starts from.
                sv.cmd({"do": "ui", "fullscreen": True}); time.sleep(0.8)
                full = lines(xs)
                sv.cmd({"do": "ui", "reveal": float(REVEAL)}); time.sleep(1.5)
                down = lines(xs)
                k = REVEAL // 2
                for x in xs:
                    # What came down covers the window's own ground, all of
                    # one view (SwiftUI's, which the tabs are drawn in too:
                    # that they aren't there is the next check's), and
                    # nothing of the page, the bars' AppKit views or a band.
                    above = set(v for v in down[x][:k - 1] if v)
                    t.ok(f"{name}: at x {x}, nothing of Search's under what came down", len(above) <= 1 and all(v.startswith("AppKitWindowHo") for v in above),
                         [(y, v) for y, v in zip(YS, down[x][:k - 1])][:8])
                    # Everything else is the same, exactly the reveal lower.
                    # (Where macOS's title bar answered, at the very top, it
                    # stays where it is: anything of Search's may be under it.)
                    shifted = [(y + REVEAL, u, v) for y, u, v in zip(YS, full[x], down[x][k:]) if u and u != v]
                    t.ok(f"{name}: at x {x}, all of it {REVEAL} points lower", not shifted, shifted[:6])
                if not sidebar:
                    # The strip's top edge is the bottom of what came down,
                    # to the point: no gap, no overlap.
                    t.ok(f"{name}: the strip of tabs starts right under what came down", first(down[400], "Strip") == REVEAL,
                         (first(full[400], "Strip"), first(down[400], "Strip")))
                sv.cmd({"do": "ui", "reveal": 0.0}); time.sleep(1.5)
                t.ok(f"{name}: hidden again, back where they were", lines(xs) == full)
                sv.cmd({"do": "ui", "fullscreen": False}); time.sleep(0.5)
                sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
