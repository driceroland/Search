#!/usr/bin/env python3
"""Closing a pin goes back to the tab before it, pins included (idea 1063).

Build first (`./build.sh`), then `python3 Tests/close_pin_back.py` from a
worktree. It uses the split suite's harness: started hidden in a world of its
own, no window shown or brought forward, everything removed afterwards.

With Settings › Tabs › Closing a tab goes back to the one before on, ⌘W on a
pin (put down, not removed) landed on the most recent tab that wasn't a pin,
often the new tab, rather than the other pin looked at just before. Off,
putting a pin down still prefers a tab over another pin, as before.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-pin-back")
t = sv.T()


def st(): return sv.sp("state")
def active(): return st()["activeID"]
def pin(id): sv.cmd({"do": "pin", "id": id}); time.sleep(0.3)
def go(*ids):
    for id in ids: sv.sp("select", id=id); time.sleep(0.4)
def close(id): sv.sp("closeTab", id=id); time.sleep(0.6); return active()
def asleep(id): return next(x for x in st()["tabs"] if x["id"] == id).get("asleep")


def run(goes_back):
    tag = "back on" if goes_back else "back off"
    sv.setup(**{"tabs.closeGoesBack": goes_back, "tabs.groups": True, "sidebar": True})
    sv.launch()
    try:
        blank = st()["activeID"]
        a, b = sv.page("pin-a"), sv.page("pin-b")
        pin(a); pin(b)
        # Two pins: A then B, B closed.
        go(blank, a, b)
        landed = close(b)
        t.ok(f"{tag}: two pins, closing B lands on A" if goes_back else f"{tag}: closing a pin prefers a tab",
             landed == (a if goes_back else blank), (landed, a, b, blank))
        t.ok(f"{tag}: B put down", asleep(b), st()["tabs"])

        # Mixed: a tab, a pin, a pin. Closing the last pin goes to the pin
        # before it; closing that goes to the tab, not to the pin put down.
        c = sv.page("loose-c")
        go(b, c, a, b)
        landed = close(b)
        t.ok(f"{tag}: tab, pin A, pin B: closing B", landed == (a if goes_back else c), (landed, a, c))
        landed = close(a)
        t.ok(f"{tag}: then closing A lands on the tab, not the pin put down", landed == c, (landed, c))

        # A pin with a peek over it: the peek goes with it, back to the tab.
        go(a, c, b)
        sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"}); time.sleep(0.8)
        landed = close(b)
        t.ok(f"{tag}: pin with a peek, closing it", landed == c and not st().get("peek"), (landed, c, st().get("peek")))

        # A tab in a group, put away, after a pin: back to the pin when asked.
        g = sv.page("grouped")
        sv.cmd({"do": "group", "id": g, "new": True, "name": "G"}); time.sleep(0.3)
        go(c, a, g)
        landed = close(g)
        t.ok(f"{tag}: grouped tab put away after a pin", landed == (a if goes_back else c), (landed, a, c))
        # A plain tab closed after a pin, the setting's original case.
        d = sv.page("loose-d")
        go(c, a, d)
        landed = close(d)
        if goes_back:
            t.ok(f"{tag}: plain tab closed after a pin", landed == a, (landed, a))
    finally:
        sv.finish()


try:
    run(True)
    run(False)
finally:
    t.done()
sys.exit(1 if t.failed else 0)
