#!/usr/bin/env python3
"""⌘S without a flash of empty page, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fold_flash.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown,
moved or resized, everything removed afterwards.

Hiding the column gives the page the column's room. Given it as the slide
started, the page grew while it slid, and the part WebKit had not drawn yet
at the new size came in from the far edge as a bar of the web view's own
ground, black or white with the theme. The page now takes its new size
before the column moves, and keeps it through the slide; showing the column
slides over a page still at its size, which gives up the room only once the
slide is over. Read through the bench's `foldtime`: the page's width and
whether the column is folded at the end of each pass of the main run loop.
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
    sliding = [i for i, p in enumerate(passes) if p["folded"]]
    grown = [i for i, p in enumerate(passes) if p["page"] == final]
    start = sliding[0] if sliding else -1
    if grown and sliding:
        print(f"  {label}: page grown at {passes[grown[0]]['at']:.0f} ms, column moving at {passes[start]['at']:.0f} ms")
    t.ok(f"{label} hide: the page has its new width a pass before the column moves",
         bool(grown) and grown[0] < start, [(p["at"], p["page"], p["folded"]) for p in passes])
    t.ok(f"{label} hide: …and keeps it through the slide",
         all(passes[i]["page"] == final for i in sliding), [(p["at"], p["page"], p["folded"]) for p in passes])
    time.sleep(0.6)
    b = fold()
    passes = b["passes"]
    t.ok(f"{label} show: out", not b["folded"], b)
    narrowed = [p for p in passes if p["page"] < b["pageBefore"]]
    first = narrowed[0]["at"] if narrowed else 9999
    t.ok(f"{label} show: the page keeps its width until the slide is over ({first} ms)", first >= 250,
         [(p["at"], p["page"], p["folded"]) for p in passes])
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
