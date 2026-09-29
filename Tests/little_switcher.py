#!/usr/bin/env python3
"""The small windows in the ⌃Tab switcher, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/little_switcher.py`. Three
small windows are made without being shown (see Little.swift). In the
browser window, ⌃Tab shows them beside the grid as moons, and picking one
brings its window forward and leaves the row alone. In a small window,
⌃Tab shows the same planet and moons, walked from the moon it's in, and
Escape puts the switcher away without closing the window it was up in.
A moon is bigger the longer its page.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

CTRL_TAB = {"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}


def switcher():
    return sv.cmd({"do": "switcher"})


def little(what="state"):
    return sv.cmd({"do": "little", "what": what})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("a"); b = sv.page("b")
        x, y, z = (f"{sv.BASE}/{n}" for n in "xyz")
        for u in (x, y, z): little(u); time.sleep(0.5)

        # The browser window: tabs in the grid, the small windows beside it.
        sv.sp("select", id=b); time.sleep(0.4)
        sv.cmd(CTRL_TAB); time.sleep(0.8)
        s = switcher()
        grid = s["candidates"]
        t.ok("⌃Tab in the browser: the grid has the tabs, and only them",
             s["visible"] and {a, b} <= set(grid) and not {x, y, z} & set(grid), s)
        t.ok("and the small windows are its moons, newest first", s["moons"] == [z, y, x], s["moons"])
        t.ok("a moon has a card of its own", z in s["cards"], s["cards"])
        t.ok("the first ⌃Tab goes back to the last tab, not a moon", s["selected"] == a, s)
        for _ in range(len(grid) - 1): sv.cmd(CTRL_TAB); time.sleep(0.2)
        t.ok("walking on goes out of the grid to the first moon", switcher()["selected"] == z, switcher())
        sv.cmd({"do": "press", "code": 124, "chars": "", "mods": ["ctrl"], "letgo": True}); time.sleep(0.6)
        s = switcher(); l = little()
        t.ok("⌃→ moves along the moons; letting go of ⌃ brings that window forward",
             l["fronted"] == y and not s["visible"], (s, l))
        t.ok("and the row is as it was", s["active"] == b and len(l["littles"]) == 3, (s, l))

        # A small window: the same planet and moons, walked from its moon.
        sv.cmd({**CTRL_TAB, "window": "little"}); time.sleep(0.8)
        l = little()["switcher"]
        t.ok("⌃Tab in a small window: the small windows are the moons, the one it's in first",
             l["visible"] and l["moons"] == [z, y, x], l)
        t.ok("and the browser's tabs are the planet", {a, b} <= set(l["candidates"]), l)
        t.ok("it stops on the next moon", l["selected"] == y, l)
        planet = l["candidates"]
        sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": ["ctrl"], "window": "little"}); time.sleep(0.6)
        l = little()
        t.ok("Escape puts the switcher away and leaves the window open",
             not l["switcher"]["visible"] and len(l["littles"]) == 3, l)
        sv.cmd({**CTRL_TAB, "window": "little"}); time.sleep(0.2)
        sv.cmd({**CTRL_TAB, "window": "little", "letgo": True}); time.sleep(0.6)
        l = little()
        t.ok("two ⌃Tabs and ⌃ let go of: the moon two along comes forward",
             l["fronted"] == x and not l["switcher"]["visible"], l)
        sv.cmd({**CTRL_TAB, "mods": ["ctrl", "shift"], "window": "little", "letgo": True}); time.sleep(0.6)
        l = little()
        t.ok("⇧⌃Tab from a small window: the planet's far end, that tab in the browser",
             l["activeID"] == planet[-1] and not l["switcher"]["visible"], (planet, l))
        t.ok("the browser's switcher never came up for it", not switcher()["visible"])

        # Moons by the length of their pages.
        little(f"{sv.BASE}/long"); time.sleep(1.5)
        l = little()
        short, long_ = l["screens"][0], l["screens"][-1]
        t.ok("a small window's page says how long it is", short >= 1 and long_ > 10, l["screens"])
        sv.cmd(CTRL_TAB); time.sleep(0.8)
        cards = switcher()["cards"]
        t.ok("its moon is bigger than a one-screen page's",
             cards[f"{sv.BASE}/long"][2] > cards[x][2], cards)
        sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": ["ctrl"]}); time.sleep(0.4)
        # Tabs and small windows managed from the switcher, ⌃ held.
        def press(code, ch): sv.cmd({"do": "press", "code": code, "chars": ch, "mods": ["ctrl"]}); time.sleep(0.6)
        sv.cmd(CTRL_TAB); time.sleep(0.8)
        pick = switcher()["selected"]
        press(46, "m")
        s = switcher()
        t.ok("off, as it is unless turned on: ⌃M puts the switcher away and mutes nothing",
             not s["visible"] and pick not in s["muted"], s)
        sv.cmd({"do": "switcher", "keys": True})
        sv.cmd(CTRL_TAB); time.sleep(0.8)
        pick = switcher()["selected"]
        press(46, "m")
        s = switcher()
        t.ok("⌃M mutes the tab picked, and the switcher stays up", pick in s["muted"] and s["visible"], s)
        press(13, "w")
        s = switcher()
        t.ok("⌃W closes it: its card goes and the pick moves on, the switcher still up",
             s["visible"] and pick not in s["candidates"] and s["selected"] not in ("", pick), s)
        t.ok("and the tab is gone from the row", pick not in sv.order(sv.sp("state")))
        for _ in range(12):
            if switcher()["selected"] in switcher()["moons"]: break
            sv.cmd(CTRL_TAB); time.sleep(0.2)
        moon = switcher()["selected"]; before = len(little()["littles"])
        press(13, "w")
        s = switcher(); l = little()
        t.ok("⌃W on a moon closes its small window", moon not in s["moons"] and len(l["littles"]) == before - 1
             and moon not in l["littles"] and s["visible"], (s, l))
        for _ in range(12):
            if switcher()["selected"] in switcher()["moons"]: break
            sv.cmd(CTRL_TAB); time.sleep(0.2)
        moon = switcher()["selected"]; rows = len(sv.order(sv.sp("state")))
        press(31, "o")
        l = little()
        t.ok("⌃O on a moon takes it into the row", moon not in l["littles"]
             and len(sv.order(sv.sp("state"))) == rows + 1 and not switcher()["visible"], l)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
