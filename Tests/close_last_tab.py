#!/usr/bin/env python3
"""Closing the last tab that isn't a pin (Browser.close, #537), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_last_tab.py` from a
worktree. With Settings › Tabs › Leave a new tab when the last tab closes,
and only pins left beside it, the tab on screen closed leaves a new tab in
its place, not a pin; the pins stay, and ⇧⌘T brings the page back. Closed
in the background, it takes nothing from the pin on screen. With another
ordinary tab left, the neighbour is picked as before. With the switch off,
a pin is picked, as it always was.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("close-last-tab")


def name(st, id):
    return next((x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] == id), None)


def active(st):
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None)


def loose(st):
    return [x["id"] for x in st["tabs"] if x["id"] not in st["pins"]]


def only(*keep):
    """Every tab that isn't a pin closed, except those kept."""
    for id in loose(sv.sp("state")):
        if id not in keep:
            sv.sp("close", id=id)


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.newAfterLast": True}); sv.launch()
        a = sv.page("a"); p = sv.page("p")
        sv.cmd({"do": "pin", "id": a}); sv.cmd({"do": "pin", "id": p})
        b = sv.page("b")
        only(b)
        st = sv.sp("state")
        t.ok("two pins, and b the one tab beside them, on screen",
             sorted(st["pins"]) == sorted([a, p]) and loose(st) == [b] and st["activeID"] == b, st)

        # The case in the issue: ⌘W on the last ordinary tab.
        st = sv.sp("close", id=b)
        now = active(st)
        t.ok("a new tab is on screen, not a pin",
             now is not None and st["activeID"] not in st["pins"] and now["blank"], st)
        t.ok("the pins are still there", sorted(st["pins"]) == sorted([a, p]), st["pins"])
        t.ok("b is gone", b not in [x["id"] for x in st["tabs"]], st["tabs"])

        st = sv.sp("reopen")
        t.ok("⇧⌘T brings b back, on screen", name(st, st["activeID"]) == "b", st)

        # Closed in the background, it takes nothing from the pin on screen.
        c = sv.page("c")
        only(c)
        sv.cmd({"do": "select", "id": a})
        st = sv.sp("close", id=c)
        t.ok("closing it behind a pin leaves the pin on screen", st["activeID"] == a, st)

        # Another ordinary tab left: its neighbour, as before.
        d = sv.page("d"); e = sv.page("e")
        only(d, e)
        sv.cmd({"do": "select", "id": d})
        st = sv.sp("close", id=d)
        t.ok("with another tab left, that one is picked", st["activeID"] == e, st)
        t.ok("and no new tab is made for it", loose(st) == [e], st["tabs"])

        # The switch off, as it comes: a pin is picked, as before.
        sv.quit(); sv.setup(); sv.launch()
        a = sv.page("a"); sv.cmd({"do": "pin", "id": a})
        b = sv.page("b")
        only(b)
        st = sv.sp("close", id=b)
        t.ok("switch off: the pin is picked, as before", st["activeID"] == a, st)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
