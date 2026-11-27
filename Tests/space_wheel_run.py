#!/usr/bin/env python3
"""A mouse's sideways wheel over the column: each notch brings one space, in
the way it was turned, however quickly they come (MX Master's thumb wheel).
Build first (`./build.sh`), then `python3 Tests/space_wheel_run.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
shown or brought forward, everything removed afterwards.

A spin of the wheel used to bring one space and then wait for the wheel to
have rested 0.3 s, every notch in between restarting the wait: turned
steadily, the wheel brought a space now and then, wherever it paused. A
wheel smoothed by its driver (steps in points, no phase) brought none.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-wheel")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper()] + [f"5E4C0000-0000-4000-8000-0000000000D{k}" for k in range(1, 5)]
NAMES = ["One", "Two", "Three", "Four", "Five"]


def where():
    st = sv.cmd({"do": "space"})
    return NAMES.index(st["current"])


def notches(**f):
    r = sv.cmd({"do": "spacenotch", **f})
    time.sleep(0.6)
    return r


try:
    sv.setup(sidebar=True, spaces=True)
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": x, "name": n, "colour": 0, "sharesSignIns": True} for x, n in zip(IDS, NAMES)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k in range(len(IDS)):
        f = "session.json" if k == 0 else f"session-{IDS[k]}.json"
        tabs = [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} {i}"} for i in range(3)]
        json.dump({"tabs": tabs, "active": 0}, open(f"{sv.SUPPORT}/{f}", "w"))
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(1.5)
    t.ok("starts on the first space", where() == 0, where())

    r = notches(dx=1, count=3, every=0.1)
    t.ok("three notches 0.1 s apart: three spaces on", where() == 3, (where(), r))
    r = notches(dx=-1, count=2, every=0.15)
    t.ok("two notches back: two spaces back", where() == 1, (where(), r))
    r = notches(dx=3, count=2, every=0.12)
    t.ok("two quick (accelerated, 3-line) notches: two spaces, not six", where() == 3, (where(), r))
    r = notches(dx=-1, count=1)
    t.ok("one notch back: one space back", where() == 2, (where(), r))
    # A notch smoothed by the driver: 36 points in six steps, no phase.
    r = notches(dx=1, count=6, every=0.008, points=6)
    t.ok("a smoothed notch (six 6-point steps, no phase): one space on", where() == 3, (where(), r))
    r = notches(dx=-1, count=18, every=0.008, points=6)
    t.ok("three smoothed notches back: three spaces back", where() == 0, (where(), r))
    # A tablet pen's pan (Wacom, Pan/Scroll, idea 1391): the page carried left
    # (dx below zero) brings the next space, the way the page moves, natural
    # scrolling on or off; a whole drag is one space.
    r = notches(dx=-1, count=20, every=0.016, pen=True)
    t.ok("a pen's pan carrying the page left: one space on", where() == 1, (where(), r))
    r = notches(dx=-1, count=20, every=0.016, pen=True, inverted=True)
    t.ok("the same, natural scrolling on: one more", where() == 2, (where(), r))
    r = notches(dx=1, count=20, every=0.016, points=4, pen=True, inverted=True)
    t.ok("a pen's pan in points carrying the page right: one space back", where() == 1, (where(), r))
    r = notches(dx=1, count=1)
    t.ok("a mouse's notch after it still goes as before", where() == 2, (where(), r))
finally:
    t.done()
    sv.finish()
