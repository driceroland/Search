#!/usr/bin/env python3
"""The column's rows made only in sight (perf-many-tabs): the tab gone to is
drawn, in the scroll's room, however far down it is, in a group or not.

Build first (`./build.sh`), then `python3 Tests/column_lazy.py [N]`. The
world is perf_many_tabs.py's (N tabs over three spaces, a third in groups of
6, one group folded), started hidden in a world of its own; nothing is
shown or brought forward. Read through the bench's `columnscroll`: its
"live" (where the tab in front's row is drawn, test runs only) against its
"room" (the scroll's, both from the window's top).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_many_tabs as pm  # noqa: E402

sv = pm.sv
sv.use("column-lazy")
t = sv.T()


def col(**f):
    return sv.cmd({"do": "columnscroll", **f})


def seen(c):
    if not c.get("scrolls") or "live" not in c or "room" not in c:
        return False
    top, bottom = c["room"]
    a, b = c["live"]
    return a >= top - 1 and b <= bottom + 1


def settle(want, within=4):
    until = time.time() + within
    while True:
        c = col()
        if want(c) or time.time() > until:
            return c
        time.sleep(0.2)


def go(label, tab_id):
    sv.sp("select", id=tab_id)
    c = settle(seen)
    t.ok(f"{label}: its row is drawn in the column's room", seen(c), {k: c.get(k) for k in ("live", "room", "offset", "content", "window")})


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    try:
        sv.setup(sidebar=True, spaces=True, **{"tabs.groups": True})
        pm.world(n)
        pm.launch()
        sv.cmd({"do": "resize", "width": 1280, "height": 820, "steps": 1})
        time.sleep(3)
        state = sv.sp("state")
        tabs = state["tabs"]
        # By their pages (perf_many_tabs.world): /p/s0/I, the first third
        # in groups of 6 (the second group folded), the rest loose.
        first = pm.counts(n)[0]
        mine = {int(x["url"].rsplit("/", 1)[-1]): x for x in tabs if "/p/s0/" in x["url"]}
        loose = [mine[i] for i in sorted(mine) if i >= first // 3]
        grouped = [mine[i] for i in sorted(mine) if i < first // 3 and not 6 <= i < 12]
        t.ok("the world has loose and grouped tabs", len(loose) > 20 and len(grouped) > 12, (len(loose), len(grouped)))
        c = settle(lambda c: c.get("scrolls"))
        t.ok("the column scrolls", c.get("scrolls"), c)
        only_spaces = "spaces" in sys.argv
        if not only_spaces:
            checks(loose, grouped)
        spaces()
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


def checks(loose, grouped):
    if True:
        go("the first loose tab", loose[0]["id"])
        go("the last loose tab", loose[-1]["id"])
        go("a loose tab in the middle", loose[len(loose) // 2]["id"])
        go("the last loose tab again", loose[-1]["id"])
        # A tab of the last group, then of the first: far out of sight each time.
        go("a tab of the last group", grouped[-1]["id"])
        go("a tab of the first group", grouped[0]["id"])
        go("a tab of a middle group", grouped[len(grouped) // 2]["id"])
        go("the last loose tab, from a group", loose[-1]["id"])
        # From the first tab, the wheel to the top, then the last tab by ⌘9.
        go("the first loose tab again", loose[0]["id"])
        c = col()
        c = col(wheel=-(c.get("offset", 0) + 200))
        sv.cmd({"do": "press", "code": 25, "chars": "9", "mods": ["cmd"]})
        c = settle(seen)
        t.ok("⌘9 from the top: the last tab's row is drawn in the room", seen(c), {k: c.get(k) for k in ("live", "room", "offset", "content", "window", "measured")})
        # A new tab at the end, and closed again: the one before it in sight.
        new = sv.sp("open", url=f"{pm.BASE}/p/new/1")["resultID"]
        c = settle(seen)
        t.ok("a new tab: its row is drawn in the room", seen(c), {k: c.get(k) for k in ("live", "room", "offset", "content", "window", "measured")})
        sv.sp("close", id=new)
        c = settle(seen)
        t.ok("closed again: the tab in front's row is in the room", seen(c), {k: c.get(k) for k in ("live", "room", "offset", "content", "window", "measured")})



def spaces():
    if True:
        # The other spaces, and back: the tab in front of each in sight.
        for index in (2, 3, 1, 3, 2):
            sv.cmd({"do": "spacetime", "index": index})
            c = settle(seen)
            t.ok(f"space {index}: its tab in front's row is in the room", seen(c), {k: c.get(k) for k in ("live", "room", "offset", "content", "window", "measured")})


if __name__ == "__main__":
    main()
