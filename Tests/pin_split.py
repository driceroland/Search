#!/usr/bin/env python3
"""A split pinned as a split, from the right-click menu of one of its rows,
in a hidden probe: both pages become pins, in their order, and stay one
split; ⌘W puts it down whole and it is still one split after a relaunch.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/pin_split.py`. It uses the split suite's harness in a world
of its own: the bench's `columnmenu` reads the menu a right-click at a point
would bring up and picks from it, so no menu is put on screen. The drop on
the pins is in Tests/pin_drag.py.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-split")
t = sv.T()


def state(): return sv.sp("state")
def name_of(st): return {x["id"]: x["url"].rsplit("/", 1)[-1] for x in st["tabs"]}
def pins(st): m = name_of(st); return [m[i] for i in st["pins"]]
def rows(st): m = name_of(st); return [m[i] for i in st["listed"]]
def pairs(st): m = name_of(st); return [[m.get(i, "?") for i in p["tabs"]] for p in st["splits"]]
def menu(x, y, **f): return sv.cmd({"do": "columnmenu", "x": x, "y": y, **f})


def row_offering(title):
    for y in range(30, 600, 3):
        if title in menu(60, y)["items"]:
            return y
    return None


try:
    sv.setup(sidebar=True, splitView=True, **{"pins.list": True}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.sp("pair", id=b, **{"with": a}, side="right")
    sv.sp("select", id=c); time.sleep(0.8)

    y = row_offering("Pin Split View")
    t.ok("a page in Split View offers Pin Split View", y is not None)
    if y is not None:
        menu(60, y, pick="Pin Split View"); time.sleep(0.8)
    st = state()
    t.ok("both pages pinned, in their order, as rows", pins(st) == ["a", "b"] and rows(st) == ["a", "b"], (pins(st), rows(st)))
    pinned = row_offering("Unpin")
    items = menu(60, pinned)["items"] if pinned is not None else []
    t.ok("the pinned split offers no Show as Square", pinned is not None and "Show as Square" not in items, items)
    t.ok("and still one split", pairs(st) == [["a", "b"]], pairs(st))

    sv.sp("select", id=a); time.sleep(0.5)
    sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"], "letgo": True}); time.sleep(0.8)
    st = state()
    t.ok("⌘W puts it down whole, still a split", pins(st) == ["a", "b"] and pairs(st) == [["a", "b"]], (pins(st), pairs(st)))

    sv.quit(); sv.launch(); time.sleep(0.5)
    st = state()
    t.ok("after a relaunch: the same pins, one split", pins(st) == ["a", "b"] and pairs(st) == [["a", "b"]], (pins(st), pairs(st)))

    # Unpin acts on the pair as one group: both pages come out and stay as
    # a Split View among the tabs.
    tabs = {x["url"].rsplit("/", 1)[-1]: x["id"] for x in st["tabs"]}
    sv.cmd({"do": "pin", "id": tabs["a"], "off": True})
    st = state()
    t.ok("Unpin the pair: both come out, no pins left",
         pins(st) == [] and pairs(st) == [["a", "b"]], (pins(st), pairs(st)))

    # Two separate pins: Open 2 Tabs in Split View merges into a pinned pair.
    # The pair from Unpin is still a split among the tabs: take it apart
    # first, so Pin on each pins just that page, not the whole split.
    sv.sp("detach", id=tabs["a"])
    sv.cmd({"do": "pin", "id": tabs["a"]})
    sv.cmd({"do": "pin", "id": tabs["b"]})
    st = state()
    t.ok("start: two separate pins, no pair", pins(st) == ["a", "b"] and pairs(st) == [], (pins(st), pairs(st)))
    sv.sp("pick", ids=[tabs["a"], tabs["b"]])
    sv.sp("pairPicked")
    time.sleep(0.5)
    st = state()
    t.ok("merged into a pinned pair, in their order, as rows",
         pins(st) == ["a", "b"] and rows(st) == ["a", "b"] and pairs(st) == [["a", "b"]],
         (pins(st), rows(st), pairs(st)))
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
