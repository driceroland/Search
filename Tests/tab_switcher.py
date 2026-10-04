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

def switcher(**options):
    return sv.cmd({"do": "switcher", **options})


def press(backwards=False):
    return sv.cmd({"do": "press", "code": 48, "chars": "\t",
                   "mods": ["ctrl", "shift"] if backwards else ["ctrl"]})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
        t.ok("previews are off without a saved choice", not switcher()["enabled"])
        sv.sp("select", id=a)
        press()
        s = switcher()
        t.ok("off: Ctrl-Tab follows the row without a preview", s["active"] == b and not s["candidates"], s)
        press(backwards=True)
        t.ok("off: Ctrl-Shift-Tab goes back", switcher()["active"] == a)
        sv.sp("select", id=c); sv.sp("select", id=b); sv.sp("select", id=a)
        switcher(enabled=True)
        press()
        s = switcher()
        t.ok("off: tab changes kept no recently-used order", [id for id in s["candidates"] if id in (a, b, c)] == [a, b, c], s)
        switcher(enabled=False)
        time.sleep(0.3)
        s = switcher()
        t.ok("turning off cancels the gesture without switching", not s["visible"] and not s["candidates"] and s["active"] == a, s)
        switcher(enabled=True)
        sv.quit(); time.sleep(0.5); sv.launch()
        t.ok("the explicit choice survives a restart", switcher()["enabled"])
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
        press(); time.sleep(0.3)
        switcher(enabled=False)
        s = switcher()
        t.ok("turning off closes a visible preview", not s["visible"] and not s["candidates"], s)
        sv.quit(); time.sleep(0.5); sv.launch()
        t.ok("off stays off after a restart", not switcher()["enabled"])
        # A split pair is one switcher card, and keeps the page with focus.
        sv.sp("enabled", on=True)
        a = sv.page("pair-left"); b = sv.page("pair-right"); c = sv.page("outside-pair")
        sv.sp("pair", id=b, **{"with": a}, side="right")
        switcher(enabled=True)
        sv.sp("select", id=c)
        press()
        s = switcher()
        t.ok("a split pair is one card", s["candidates"].count(a) == 1 and b not in s["candidates"] and s["selected"] == a, s)
        x, y, w, h = s["cards"][a]
        sv.sp("mouse", points=[[x + w / 2, y + h / 2], [x + w / 2, y + h / 2]])
        st = sv.sp("state")
        t.ok("picking the pair restores its focused page", st["activeID"] == b and set(st["visibleIDs"]) == {a, b}, st)
        switcher(enabled=False)
        press()
        s = switcher()
        t.ok("off: Ctrl-Tab steps past the pair", s["active"] == c and not s["candidates"], s)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
