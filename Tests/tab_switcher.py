#!/usr/bin/env python3
"""The ⌃Tab switcher and the pointer, in a hidden probe (#358, by oddharsh).

Build first (`./build.sh`), then `python3 Tests/tab_switcher.py`. ⌃Tab is
pressed through the app and a click is sent through it too, so the window's
event monitor sees them as it sees a hand's; no window is made or shown.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-switcher")


def switcher():
    return sv.cmd({"do": "switcher"})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
        sv.sp("select", id=c); time.sleep(0.4)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = switcher()
        t.ok("⌃Tab: the switcher is up", s["visible"] and len(s["candidates"]) >= 3, s)
        t.ok("its cards have their places", set(s["cards"]) >= {a, b, c} and s["panel"][2] > 0, s["cards"])
        x, y, w, h = s["cards"][a]
        sv.sp("mouse", points=[[x + w / 2, y + h / 2], [x + w / 2, y + h / 2]]); time.sleep(0.6)
        s = switcher()
        t.ok("a click on a card, ⌃ held: that tab", s["active"] == a and not s["visible"], s)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}); time.sleep(0.8)
        s = switcher()
        px, py, pw, ph = s["panel"]
        sv.sp("mouse", points=[[5, 5], [5, 5]]); time.sleep(0.6)
        s = switcher()
        t.ok("a click outside the panel puts the switcher away, the tab unchanged", not s["visible"] and s["active"] == a, s)
        # A split pair is one switcher card, and keeps the page with focus.
        sv.sp("enabled", on=True)
        a = sv.page("pair-left"); b = sv.page("pair-right"); c = sv.page("outside-pair")
        sv.sp("pair", id=b, **{"with": a}, side="right")
        sv.sp("select", id=c)
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]})
        time.sleep(0.3)
        s = switcher()
        t.ok("a split pair is one card", s["candidates"].count(a) == 1 and b not in s["candidates"] and s["selected"] == a, s)
        x, y, w, h = s["cards"][a]
        sv.sp("mouse", points=[[x + w / 2, y + h / 2], [x + w / 2, y + h / 2]])
        st = sv.sp("state")
        t.ok("picking the pair restores its focused page", st["activeID"] == b and set(st["visibleIDs"]) == {a, b}, st)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
