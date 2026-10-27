#!/usr/bin/env python3
"""The column scrolls both ways (idea 443), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/column_scroll.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown
or brought forward, everything removed afterwards. A short window, a dozen
groups (most folded, as a user with many folders had them) and loose tabs
past its height: the column must scroll, a wheel take it back up to the
folders and down again, and the tab you go to be scrolled into sight. Then
the same with the column on the right, as icons only, with roomier rows,
and folded away and out over the page. The column is read through the
bench's `column`: its room, what the rows add up to and measure, and its
scroll view's offset.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("column-scroll")

t = sv.T()
def col(**f): return sv.cmd({"do": "columnscroll", **f})
def layout(v): sv.cmd({"do": "settings", "set": "tabs.layout", "value": v}); time.sleep(0.8)


def settle(want, within=4):
    """The column again until `want` holds of it: it is measured a frame or
    two after a change."""
    until = time.time() + within
    while True:
        c = col()
        if want(c) or time.time() > until: return c
        time.sleep(0.2)


def fill():
    """Twelve groups of two, ten folded, and twelve loose tabs: every page
    opened first, from a tab in no group (a page opened from a grouped tab
    joins its group), then grouped."""
    ids = [sv.page(f"g{g}{x}") for g in range(12) for x in "ab"]
    loose = [sv.page(f"l{i}") for i in range(12)]
    for g in range(12):
        sv.cmd({"do": "group", "id": ids[2 * g], "new": True, "name": f"G{g}"})
        sv.cmd({"do": "group", "id": ids[2 * g + 1], "name": f"G{g}"})
    sv.sp("select", id=loose[-1])
    for g in range(10):
        sv.cmd({"do": "group", "fold": True, "name": f"G{g}"})
    return ids, loose


def check(label, loose, first):
    c = settle(lambda c: c["scrolls"])
    t.ok(f"{label}: more rows than room, and the column scrolls", c["scrolls"], c)
    m = c["measured"]
    t.ok(f"{label}: the rows measure taller than the room", m.get("drawn", 0) > m.get("room", 1e9), m)
    if not c["scrolls"]: return
    # The last tab, gone to: scrolled down to it.
    sv.sp("select", id=loose[-1])
    c = settle(lambda c: c["offset"] + c["visible"] >= c["content"] - 80)
    t.ok(f"{label}: the last tab, gone to, is scrolled into sight",
         c["offset"] + c["visible"] >= c["content"] - 80, c)
    # All the way back up to the folders, with the wheel.
    c = col(wheel=-(c["content"] + 200))
    t.ok(f"{label}: the wheel takes the column back to its top", abs(c["offset"]) < 2, c)
    c = col(wheel=150)
    t.ok(f"{label}: …and down again", c["offset"] > 50, c)
    col(wheel=-400)
    # A folder at the top opened and folded again from there.
    sv.cmd({"do": "group", "fold": True, "name": "G0"}); time.sleep(0.5)
    sv.cmd({"do": "group", "fold": True, "name": "G0"}); time.sleep(0.5)
    c = col()
    t.ok(f"{label}: folding a group at the top leaves the column at the top", c["scrolls"] and c["offset"] < 2, c)
    # The first tab of the first open group, gone to from the bottom.
    sv.sp("select", id=loose[-1]); time.sleep(0.8)
    sv.sp("select", id=first)
    c = settle(lambda c: c["offset"] < c["content"] / 2)
    t.ok(f"{label}: a tab near the top, gone to, is scrolled back to", c["offset"] < c["content"] / 2, c)


def main():
    try:
        sv.setup(**{"tabs.groups": True, "sidebar": True}); sv.launch()
        sv.cmd({"do": "resize", "width": 1000, "height": 560, "steps": 1})
        ids, loose = fill()
        first = ids[20]  # G10's first tab, in a group left open
        check("left", loose, first)

        # Opened again with the space as it was left: the column starts out
        # a plain stack, already past the window, the groups folded. It used
        # to stay one, measuring its room as tall as itself.
        sv.quit(); sv.launch()
        sv.cmd({"do": "resize", "width": 1000, "height": 560, "steps": 1})
        c = settle(lambda c: c["scrolls"])
        t.ok("opened again: the column scrolls", c["scrolls"], c)
        if c["scrolls"]:
            c = col(wheel=-(c["content"] + 200))
            t.ok("opened again: the wheel takes it to the top", abs(c["offset"]) < 2, c)
        # Its tabs have new ids now: found again by their pages.
        named = {x["url"].rsplit("/", 1)[-1]: x["id"] for x in sv.sp("state")["tabs"]}
        loose = [named[f"l{i}"] for i in range(12)]
        first = named["g10a"]
        ids = [named[f"g{g}{x}"] for g in range(12) for x in "ab"]

        layout("right"); check("right", loose, first)
        layout("icons"); check("icons", loose, first)
        layout("left")

        # Folded away (⌘S) and out over the page.
        c = col(peek=True)
        c = settle(lambda c: c["scrolls"])
        t.ok("peeking: the column out over the page scrolls", c["scrolls"], c)
        if c["scrolls"]:
            c = col(wheel=-(c["content"] + 200))
            t.ok("peeking: the wheel takes it to the top", abs(c["offset"]) < 2, c)
            c = col(wheel=150)
            t.ok("peeking: …and down again", c["offset"] > 50, c)
        col(peek=False)

        # Few rows: a plain stack again, nothing to scroll.
        sv.cmd({"do": "settings", "set": "tabs.layout", "value": "left"})
        for x in loose + ids[:16]: sv.sp("close", id=x)
        c = settle(lambda c: not c["scrolls"])
        t.ok("few rows: the column doesn't scroll", not c["scrolls"], c)

        # Roomier rows, from the start.
        sv.quit()
        sv.setup(**{"tabs.groups": True, "sidebar": True, "sidebar.roomy": True}); sv.launch()
        sv.cmd({"do": "resize", "width": 1000, "height": 560, "steps": 1})
        ids, loose = fill()
        check("roomier", loose, ids[20])
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
