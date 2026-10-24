#!/usr/bin/env python3
"""A tab dragged onto the pins, and a pin dragged out among the tabs, in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_drag.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The column's drop calls Browser.pinDropped and
Browser.unpinDropped; `pin … at` calls the same two, so what is checked here
is what a drop does: the place, the kind, the page kept (no reload), the
pins file, shared pins, groups and pairs. The drag itself — the hand, the
grid making room, the line opened among the rows — is driven in
PinDragTests (`swift test --filter PinDragTests`), in a window off every
screen, and looked at by hand on a release candidate.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own (see use()).
sv.use("bld-pd")

t = sv.T()
def state(): return sv.sp("state")
def name_of(st): return {x["id"]: x["url"].rsplit("/", 1)[-1] for x in st["tabs"]}
def names(st, ids): m = name_of(st); return [m[i] for i in ids]
def pins(st): return names(st, st["pins"])
def rows(st): return names(st, st["listed"])
def shared(st): return names(st, st["everywhere"])
def loose(st): return [x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] not in st["pins"] and not x["blank"]]
def tab_of(st, name): return next(x["id"] for x in st["tabs"] if x["url"].endswith("/" + name))
def web(st, id): return next(x["web"] for x in st["tabs"] if x["id"] == id)
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def mark(id, value): sv.ev(id, f"window.__pd = '{value}'; document.title")
def marked(id): return sv.ev(id, "window.__pd || 'gone'")

try:
    sv.setup(sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d"); e = sv.page("e")
    pin(a); pin(b)
    st = state()
    t.ok("start: two pins, three tabs", pins(st) == ["a", "b"] and loose(st) == ["c", "d", "e"], (pins(st), loose(st)))

    # A tab let go between the two squares.
    mark(d, "kept-d"); before = web(state(), d)
    r = pin(d, at=1)
    st = state()
    t.ok("onto the grid: pinned between the two", pins(st) == ["a", "d", "b"], pins(st))
    t.ok("onto the grid: a square, not a row", "d" not in rows(st), rows(st))
    t.ok("onto the grid: the drop says it took it", r.get("taken") is True, r)
    t.ok("onto the grid: the same web view", web(st, d) == before and before != "", (before, web(st, d)))
    t.ok("onto the grid: the page wasn't loaded again", marked(d) == "kept-d", marked(d))
    t.ok("onto the grid: its home is the page it was on", r.get("home", "").endswith("/d"), r)

    # At the head, and past the end.
    pin(c, at=0); t.ok("onto the grid: first", pins(state()) == ["c", "a", "d", "b"], pins(state()))
    pin(e, at=99); t.ok("onto the grid: past the end is the end", pins(state()) == ["c", "a", "d", "b", "e"], pins(state()))

    # Out again, among the tabs.
    mark(a, "kept-a"); before = web(state(), a)
    r = pin(a, off=True, at=0)
    st = state()
    t.ok("out of the grid: a tab, first among the tabs", "a" not in pins(st) and loose(st)[0] == "a", (pins(st), loose(st)))
    t.ok("out of the grid: no letter, no home", r.get("pin") == "" and r.get("home") == "", r)
    t.ok("out of the grid: the same web view, the page as it was", web(st, a) == before and marked(a) == "kept-a", (before, web(st, a), marked(a)))
    pin(c, off=True, at=1); pin(e, off=True, at=5)
    st = state()
    t.ok("out of the grid: at the place it was let go", loose(st) == ["a", "c", "e"], loose(st))

    # The pins file follows, as it does for Pin Tab.
    sv.sp("save")
    kept = json.load(open(f"{sv.SUPPORT}/pins.json"))
    homes = [x["home"].rsplit("/", 1)[-1] for x in next(iter(kept.values()))]
    t.ok("pins.json: the pins in their new order", homes == ["d", "b"], homes)

    # A pair isn't pinned by a drag; the menu's Pin Tab still can.
    sv.sp("enabled", on=True)
    sv.sp("pair", id=c, **{"with": a}, side="right")
    r = pin(a, at=0); st = state()
    t.ok("pair: not taken", r.get("taken") is False and "a" not in pins(st) and len(st["splits"]) == 1, (r, pins(st), st["splits"]))
    pin(c, at=0); st = state()
    t.ok("pair: its other half neither", "c" not in pins(st) and len(st["splits"]) == 1, (pins(st), st["splits"]))
    sv.sp("detach", id=c)

    # A private tab neither.
    sv.sp("private"); st = state()
    shy = next(x["id"] for x in st["tabs"] if x["shy"])
    r = pin(shy, at=0)
    t.ok("private: not taken", r.get("taken") is False and shy not in state()["pins"], r)
    sv.sp("close", id=shy)

    # Pinned rows: a tab onto the rows, a square onto the rows and back.
    sv.quit()
    sv.setup(sidebar=True, **{"pins.list": True}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d")
    pin(a); pin(b, listed=True)
    pin(c, at=0, listed=True); st = state()
    t.ok("rows: a tab onto the pinned rows, first", rows(st) == ["c", "b"] and pins(st) == ["a", "c", "b"], (pins(st), rows(st)))
    pin(a, at=1, listed=True); st = state()
    t.ok("rows: a square onto the rows becomes one, where let go", rows(st) == ["c", "a", "b"] and pins(st) == ["c", "a", "b"], (pins(st), rows(st)))
    pin(b, at=0, listed=False); st = state()
    t.ok("rows: a row onto the grid becomes a square", pins(st) == ["b", "c", "a"] and rows(st) == ["c", "a"], (pins(st), rows(st)))
    # (The world's first, blank tab is among them too: the end is past it.)
    pin(c, off=True, at=99); st = state()
    t.ok("rows: a pinned row out among the tabs", "c" not in pins(st) and loose(st) == ["d", "c"], (pins(st), loose(st)))

    # Groups: a pin let go over a group's name goes into it.
    sv.quit()
    sv.setup(sidebar=True, **{"tabs.groups": True}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    pin(a)
    st = sv.sp("group", id=b); group = st["groups"][0]["id"]
    pin(a, off=True, at=0, group=group); st = state()
    t.ok("groups: a pin out into a group", "a" not in pins(st) and st["groupIDs"][[x["id"] for x in st["tabs"]].index(a)] == group, (pins(st), st["groupIDs"]))
    pin(c, at=0); st = state()
    t.ok("groups: a tab onto the grid leaves no group behind", pins(st) == ["c"], pins(st))
    pin(b, at=0); st = state()
    t.ok("groups: a grouped tab onto the grid leaves its group", pins(st) == ["b", "c"] and st["groupIDs"][0] == "", (pins(st), st["groupIDs"]))

    # Pins in every space: a drop makes the space's own pin, after the
    # shared ones; a shared pin dragged out leaves every space, as Unpin.
    sv.quit()
    sv.setup(sidebar=True, spaces=True, **{"pins.shared": True}); sv.launch()
    m = sv.page("mail"); n = sv.page("notes"); x = sv.page("x")
    pin(m); pin(m, everywhere=True); time.sleep(0.5)
    pin(n, at=0); st = state()
    t.ok("shared: dropped first, it lands after the shared pin", pins(st) == ["mail", "notes"] and shared(st) == ["mail"], (pins(st), shared(st)))
    t.ok("shared: it is this space's own", "notes" not in shared(st), shared(st))
    sv.cmd({"do": "space", "action": "new", "name": "Two"}); time.sleep(1)
    st = state(); t.ok("shared: the other space has only the shared one", pins(st) == ["mail"], pins(st))
    sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.8)
    pin(tab_of(state(), "mail"), off=True, at=0); time.sleep(0.5)
    st = state(); t.ok("shared: dragged out, a tab here", "mail" in loose(st) and pins(st) == ["notes"], (pins(st), loose(st)))
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    st = state(); t.ok("shared: and gone from the other space", pins(st) == [], pins(st))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
