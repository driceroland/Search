#!/usr/bin/env python3
"""The column's edge held, in a hidden probe: the page slides with it.

Build first (`./build.sh`), then `python3 Tests/column_edge_held.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
made, shown or brought forward, everything removed afterwards. Checked
through the bench (`edgetime`, the edge held a frame at a time, and
`icons` for the column's width): narrower or wider, the page is laid out
once as the edge is taken and then only slides with it, where it was
resized every 40 points and its far side jumped; let go, it takes the
width it was let go at. Whether the edge
keeps the left-right cursor under a moving pointer is on the RC list:
a hidden probe has no pointer.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("column-edge-held")

t = sv.T()
def column():
    """The column's width as kept and as drawn (the bench's `icons`)."""
    return sv.cmd({"do": "icons"})
def held(start, end, steps=24):
    """The edge held from `start` to `end`, a frame at a time: the page's
    own width at every step after the first, and every sample. The first
    step is where the page is laid out once for the hold, and is drawn a
    frame late; the last sample is after it is let go."""
    drawn = sv.cmd({"do": "edgetime", "from": start, "to": end, "steps": steps, "held": True})["drawn"]
    return {round(d["maxX"] - d["minX"]) for d in drawn[1:-1]}, drawn
def follows(drawn):
    """The page's near side as far from the edge at the last held step as
    at the first."""
    return abs((drawn[-2]["minX"] - drawn[-2]["edge"]) - (drawn[0]["minX"] - drawn[0]["edge"])) <= 1
def kept(w, within=4):
    until = time.time() + within
    while column()["sideWidth"] != w and time.time() < until: time.sleep(0.15)
    return column()

try:
    for cards in (True, False):
        kind = "as a card" if cards else "edge to edge"
        sv.setup(sidebar=True, **{"layout.cards": cards}); sv.launch()
        sv.page("a"); time.sleep(0.6)

        sizes, drawn = held(340, 180)
        t.ok(f"{kind}, held narrower: the page laid out once, then only slid", len(sizes) == 1, sizes)
        t.ok(f"{kind}, held narrower: it follows the edge", follows(drawn), (drawn[0], drawn[-2]))
        st = kept(180)
        t.ok(f"{kind}, let go: the width kept", st["sideWidth"] == 180 and st["columnWidth"] == 180, st["sideWidth"])
        t.ok(f"{kind}, let go: the page laid out to it",
             abs(drawn[-1]["minX"] - drawn[-1]["edge"] - (drawn[-2]["minX"] - drawn[-2]["edge"])) <= 1, drawn[-1])

        sizes, drawn = held(180, 420)
        t.ok(f"{kind}, held wider: the page laid out once, then only slid", len(sizes) == 1, sizes)
        t.ok(f"{kind}, held wider: it follows the edge", follows(drawn), (drawn[0], drawn[-2]))
        st = kept(420)
        t.ok(f"{kind}, let go wider: the width kept", st["sideWidth"] == 420, st["sideWidth"])
        sv.finish()
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
