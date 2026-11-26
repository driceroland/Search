#!/usr/bin/env python3
"""With only one space, a long stroke past it brings the card for a new one;
a short stroke, a flick and a mouse wheel's notch don't (#1610).
Build first (`./build.sh`), then `python3 Tests/space_swipe_alone.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
shown or brought forward, everything removed afterwards.

Spaces just turned on, a stroke over the tabs once brought a nameless card
that looked like a second space nobody made, so a stroke past the only space
was stopped altogether (e5620f4) — and the swipe Settings offers for spaces
then sprang back every time, and seemed broken. A stroke has a length to
tell a stray one by: three times a space's, with no flick, brings the card.
A notch has none, and stays stopped.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-alone")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper(), "5E4C0000-0000-4000-8000-0000000000C1"]


def start(spaces):
    sv.setup(sidebar=True, spaces=True)
    os.makedirs(sv.SUPPORT, exist_ok=True)
    names = ["One", "Two"][:spaces]
    json.dump([{"id": x, "name": n, "colour": 0, "sharesSignIns": True} for x, n in zip(IDS, names)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k in range(spaces):
        f = "session.json" if k == 0 else f"session-{IDS[k]}.json"
        tabs = [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} {i}"} for i in range(5)]
        json.dump({"tabs": tabs, "active": 0}, open(f"{sv.SUPPORT}/{f}", "w"))
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(1.5)


def making():
    return sv.cmd({"do": "space"})["making"]


def back():
    """Off the card again, to the space before it."""
    sv.cmd({"do": "space", "action": "swipe", "dx": 160}); time.sleep(1.2)


try:
    start(1)
    sv.cmd({"do": "space", "action": "swipe", "dx": -100}); time.sleep(1.2)
    t.ok("one space, 100 points toward the card (twice a space's): it snaps back", not making(), making())
    r = sv.cmd({"do": "swipetime", "dx": -70, "steps": 3, "every": 1 / 120}); time.sleep(1.2)
    t.ok("one space, a quick 70-point flick: it snaps back", not making(), making())
    r = sv.cmd({"do": "spacenotch", "dx": -1})
    t.ok("one space, a wheel's notch toward the card: nothing comes", not r["making"] and not r["precise"],
         (r["making"], r["precise"]))
    sv.cmd({"do": "space", "action": "swipe", "dx": -160}); time.sleep(1.2)
    t.ok("one space, 160 points (past three times a space's): the card for a new one", making(), making())
    back()
    t.ok("a stroke back from the card: the one space again", not making() and sv.cmd({"do": "space"})["current"] == "One",
         sv.cmd({"do": "space"}))
    sv.quit()

    # Two spaces: as before, twice a space's from the last, and a notch brings it.
    start(2)
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(1)
    sv.cmd({"do": "space", "action": "swipe", "dx": -110}); time.sleep(1.2)
    t.ok("two spaces, 110 points from the last: the card, as before", making(), making())
    back()
    r = sv.cmd({"do": "spacenotch", "dx": -1})
    t.ok("two spaces, a wheel's notch from the last: the card, as before", r["making"], r)
finally:
    t.done()
    sv.finish()
