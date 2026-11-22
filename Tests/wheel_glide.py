#!/usr/bin/env python3
"""A mouse wheel's notches glide with Smooth scrolling with a mouse wheel on,
and jump the whole notch at once with it off, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/wheel_glide.py`. Uses the
split suite's harness in a world of its own; no window is made or brought
forward. The bench sends three notches of one line, 250 ms apart, to a long
page and reads where the page is every 4 ms (bench `wheel`): off, each notch
is one step of 40 points; on, each is many small steps that end at the same
place, and a notch the other way during a glide drops what was left of it.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("wheel-glide")


def wheel(id, **f):
    return sv.cmd({"do": "wheel", "id": id, **f})


def main():
    t = sv.T()
    sv.setup()
    sv.launch()
    try:
        id = sv.page("long")
        time.sleep(0.5)
        off = wheel(id, smooth=False)
        ys = [p[1] for p in off["positions"]]
        print("  off:", off["positions"])
        t.ok("off: three notches, 40 points each, one step each", ys == [0, 40, 80, 120], ys)
        sv.ev(id, "scrollTo(0, 0)")
        time.sleep(0.3)
        on = wheel(id, smooth=True)
        ys = [p[1] for p in on["positions"]]
        print("  on: ", on["positions"])
        t.ok("on: ends where off does", ys[-1] == 120, ys)
        t.ok("on: each notch in many steps", len(ys) >= 3 * 6, len(ys))
        t.ok("on: never back, never past", all(b > a for a, b in zip(ys, ys[1:])) and max(ys) == 120, ys)
        biggest = max(b - a for a, b in zip(ys, ys[1:]))
        t.ok("on: no step near a whole notch", biggest <= 16, biggest)
        # Quick notches: one 30 ms after another adds to what's left.
        sv.ev(id, "scrollTo(0, 0)")
        time.sleep(0.3)
        quick = wheel(id, smooth=True, notches=5, gap=30)
        t.ok("on, five quick notches: all of them, 200 points", quick["last"] == 200, quick["positions"])
        # A notch of several lines at once: all of them.
        sv.ev(id, "scrollTo(0, 400)")
        time.sleep(0.3)
        down = wheel(id, smooth=True, notches=1, lines=-3)
        t.ok("on, three lines at once: 120 points", down["last"] == 520, down["positions"])
        # Pages see wheel events in pixels and the page's own listener still
        # gets them; a page that takes the wheel stops the scroll.
        sv.ev(id, "window.__w = 0; addEventListener('wheel', e => { __w++; e.preventDefault() }, {passive: false}); scrollTo(0, 0)")
        time.sleep(0.3)
        held = wheel(id, smooth=True, notches=2)
        seen = sv.ev(id, "__w")
        t.ok("on, a page that takes the wheel: its listener hears it, nothing scrolls", held["last"] == 0 and seen and seen > 2, (held["positions"], seen))
        t.done()
    finally:
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
