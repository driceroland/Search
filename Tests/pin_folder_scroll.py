#!/usr/bin/env python3
"""Opening a pin folder opens it in place, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_folder_scroll.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
shown, moved or resized, everything removed afterwards. A folder holding
more pins than the window has room for, folded, with the tab you are on
below it: opened, the column must start scrolling where the stack was, at
its top, not jump to the tab you are on (it went to the bottom, and the
folder's heading had to be scrolled back to). Opened again while the
column already scrolls, the offset stays where it was. A tab gone to is
still scrolled into sight. Read through the bench's `columnscroll`.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-folder-scroll")
t = sv.T()


def pf(**f): return sv.cmd({"do": "pinfolder", **f})
def col(**f): return sv.cmd({"do": "columnscroll", **f})


def settle(want, within=4):
    until = time.time() + within
    while True:
        c = col()
        if want(c) or time.time() > until: return c
        time.sleep(0.2)


try:
    sv.setup(sidebar=True); sv.launch()
    height = col()["height"]
    many = int(height / 30) + 6
    print(f"  window {height:.0f} tall: {many} pins in the folder")
    few = [sv.page(f"few{i}") for i in range(3)]
    pins = [sv.page(f"p{i}") for i in range(many)]
    front = sv.page("front")
    pf(action="on")
    for id in few + pins: pf(action="pin", id=id)
    pf(action="new", name="Few", id=few[0])
    for id in few[1:]: pf(action="move", id=id, folder="Few")
    pf(action="new", name="Many", id=pins[0])
    for id in pins[1:]: pf(action="move", id=id, folder="Many")
    pf(action="fold", name="Many")
    pf(action="fold", name="Few")
    sv.sp("select", id=front)
    c = settle(lambda c: not c["scrolls"])
    t.ok("folded: the rows fit, a plain stack", not c["scrolls"], c)

    # Opened: more rows than room. The column scrolls, from its top.
    pf(action="open", name="Many")
    c = settle(lambda c: c["scrolls"]); time.sleep(0.6); c = col()
    t.ok("opened: the column scrolls", c["scrolls"], c)
    t.ok("opened: …from its top, the folder's heading in place", c.get("offset", 99) < 2, c)

    # Already scrolling: another folder opened leaves the offset as it was.
    pf(action="open", name="Few"); time.sleep(0.6)
    c = col()
    t.ok("opened while scrolling at the top: still at the top", c["scrolls"] and c["offset"] < 2, c)
    pf(action="fold", name="Few"); time.sleep(0.4)
    c = col(wheel=90)
    was = c.get("offset", 0)
    pf(action="open", name="Few"); time.sleep(0.6)
    c = col()
    t.ok(f"opened while scrolled down ({was:.0f}): the offset is unchanged",
         c["scrolls"] and abs(c["offset"] - was) < 2, (was, c))

    # A tab gone to is still scrolled into sight.
    sv.sp("select", id=pins[0]); time.sleep(0.4)
    sv.sp("select", id=front)
    c = settle(lambda c: c["offset"] + c["visible"] >= c["content"] - 80)
    t.ok("the tab gone to is scrolled into sight", c["offset"] + c["visible"] >= c["content"] - 80, c)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
