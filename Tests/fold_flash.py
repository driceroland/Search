#!/usr/bin/env python3
"""⌘S without a flash of empty page, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fold_flash.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown,
moved or resized, everything removed afterwards.

Hiding the column gives the page the column's room. Given it as the slide
started, the page grew while it slid, and the part WebKit had not drawn yet
at the new size came in from the far edge as a bar of the web view's own
ground, black or white with the theme. 1.0.17 had the page take its new
size before the column moved, and give it up after it came, which made
what the page centres jump (idea 659). The page now follows the column,
laid out at each width it passes through, and what it hasn't drawn yet is
in its own colour (fold_follow.py, frame by frame). Read through the
bench's `foldtime`: the page's width and whether the column is folded at
the end of each pass of the main run loop.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-flash")
t = sv.T()


def fold():
    return sv.cmd({"do": "foldtime"})


def check(label):
    a = fold()
    passes = a["passes"]
    widths = [p["page"] for p in passes]
    t.ok(f"{label} hide: folded", a["folded"], a)
    final = widths[-1] if widths else 0
    t.ok(f"{label} hide: the page is wider", final > a["pageBefore"], (a["pageBefore"], final))
    # The page follows the column, laid out at the widths it passes through
    # (fold_follow.py checks it frame by frame), never at its new width
    # before the column has moved.
    between = {w for w in widths if a["pageBefore"] < w < final}
    t.ok(f"{label} hide: the page grows with the column, through widths between", len(between) >= 2,
         [(p["at"], p["page"], p["folded"]) for p in passes][:10])
    early = [p for p in passes if not p["folded"] and p["page"] == final]
    t.ok(f"{label} hide: …never at its new width before the column goes", not early, early[:2])
    t.ok(f"{label} hide: what it grows into is the page's own colour, never the view's ground",
         all(p["grounded"] for p in passes if p["follows"] and p["page"] > a["pageBefore"]),
         [(p["at"], p["page"], p["grounded"]) for p in passes][:10])
    time.sleep(0.6)
    b = fold()
    passes = b["passes"]
    t.ok(f"{label} show: out", not b["folded"], b)
    narrowed = [p for p in passes if p["page"] < b["pageBefore"]]
    first = narrowed[0]["at"] if narrowed else 9999
    t.ok(f"{label} show: the page gives up its room as the column comes ({first} ms)", first < 150,
         [(p["at"], p["page"], p["folded"]) for p in passes])
    t.ok(f"{label} show: …through widths between", len({p["page"] for p in narrowed}) >= 3,
         sorted({p["page"] for p in narrowed}))
    time.sleep(0.6)


def twice(label):
    a = sv.cmd({"do": "foldtime", "twice": True})
    t.ok(f"{label} ⌘S twice at once: the column stays, the page at its size",
         not a["folded"] and not a["passes"][-1]["away"] and a["passes"][-1]["page"] == a["pageBefore"],
         [(p["at"], p["page"], p["folded"], p["away"]) for p in a["passes"]][-3:])
    time.sleep(0.4)


try:
    sv.setup(sidebar=True); sv.launch()
    sv.page("flash")
    check("card")
    twice("card")
    sv.quit()
    sv.setup(**{"sidebar": True, "layout.cards": False}); sv.launch()
    sv.page("flash")
    check("edge to edge")
    twice("edge to edge")
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
