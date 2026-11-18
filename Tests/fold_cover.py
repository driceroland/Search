#!/usr/bin/env python3
"""⌘S on a page slow to draw at its new size, in a hidden probe (idea 737).

Build first (`./build.sh`), then `python3 Tests/fold_cover.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown,
moved or resized, everything removed afterwards.

Folding the column gives the page its room, and the column slides once WebKit
has drawn the page at its new size, or after 0.12 s (see fold_flash.py). A
page busy for longer than that (a large app, a page that works on resize)
was still drawn at its old size when the column moved, and the room it grew
into slid into the window as a block of the web view's own ground, black in
the dark theme, on the far side, until the page caught up: seen frame by
frame in an off-screen recording at 250 ms. The room is now covered in the
page's own colour until WebKit has drawn it (Browser.cover). Read through
the bench's `foldtime`: covers laid, one there while the column moves, none
left once the page is drawn. Card, edge to edge and Reduce animations.

And ⌘S with the column out over the page (the pointer at the edge brought
it): it stays where it is. It was put away for a frame, the page bare where
it had been with the window's buttons over it, and slid out again.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fold-cover")
t = sv.T()

# 250 ms of work on every resize: drawn at the new size only after it.
BUSY = "window.addEventListener('resize',function(){var t=Date.now();while(Date.now()-t<250){}});1"


def check(label, slides=True):
    tab = sv.page("cover")
    sv.cmd({"do": "eval", "id": tab, "js": BUSY})
    time.sleep(0.3)
    a = sv.cmd({"do": "foldtime"})
    passes = a["passes"]
    t.ok(f"{label}: folded", a["folded"], a)
    t.ok(f"{label}: the room the page grew into was covered", a.get("covers", 0) >= 1, a.get("covers"))
    if slides:
        moving = [p for p in passes if p["folded"]]
        t.ok(f"{label}: covered while the column slides",
             bool(moving) and moving[0]["covered"] >= 1, [(p["at"], p["folded"], p["covered"]) for p in passes][:8])
    t.ok(f"{label}: the cover goes once the page is drawn", a.get("coveredAfter") == 0, a.get("coveredAfter"))
    time.sleep(0.5)
    b = sv.cmd({"do": "foldtime"})
    t.ok(f"{label}: showing it lays none", not b["folded"] and b.get("covers") == 0, (b["folded"], b.get("covers")))
    time.sleep(0.6)


def from_peek(label):
    sv.cmd({"do": "foldtime"}); time.sleep(0.6)
    sv.cmd({"do": "columnscroll", "peek": True})
    a = sv.cmd({"do": "foldtime"})
    away = [(x["at"], x["folded"], x["peeking"]) for x in a["passes"] if x["folded"] and not x["peeking"]]
    t.ok(f"{label}: ⌘S on the column out over the page keeps it out", not a["folded"] and not away, away or a)
    xs = [x["column"] for x in a["passes"] if isinstance(x.get("column"), (int, float))]
    t.ok(f"{label}: …where it was, never put away on the way", bool(xs) and min(xs) > 0, xs[:8])
    time.sleep(0.6)


try:
    sv.setup(sidebar=True); sv.launch()
    check("card")
    from_peek("card")
    sv.quit()
    sv.setup(**{"sidebar": True, "layout.cards": False}); sv.launch()
    check("edge to edge")
    sv.quit()
    sv.setup(**{"sidebar": True, "motion.instant": True}); sv.launch()
    check("Reduce animations", slides=False)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
