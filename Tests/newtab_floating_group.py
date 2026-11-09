#!/usr/bin/env python3
"""The floating new tab, raised over a tab in a group, opens outside the group.

Build first (`./build.sh`), then `python3 Tests/newtab_floating_group.py`. It
uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards.

With the setting New tab in a floating field on, ⌘T over a page raises a
field and Return makes the tab. Over a tab in a group, that tab went into the group,
as a link opened from the page does, though nothing was opened from the page:
with the setting off, ⌘T from the same tab gives a tab in no group, at the end
of the row. The floating one now lands where that one does.

The same for ⌘K, whose field looks no different: an address typed into it
over a grouped tab gets a tab in no group.

Left as they were, and checked so the fix reaches no further: the field
raised over a tab in no group puts its tab beside that one, and ⌘Return from
the address of a grouped tab still opens in its group.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-floating-group")


def press(code, ch, mods=()):
    return sv.cmd({"do": "press", "code": code, "chars": ch, "mods": list(mods)})


def st():
    return sv.sp("state")


def name(x):
    return x["url"].rsplit("/", 1)[-1]


def row(s):
    """The row as (page, grouped?) in order, so two runs can be compared."""
    return [(name(x), s["groupIDs"][i] != "") for i, x in enumerate(s["tabs"])]


def gid(s, page):
    return next((s["groupIDs"][i] for i, x in enumerate(s["tabs"]) if name(x) == page), None)


def start(floating):
    """a and b in Basics, then two tabs in no group."""
    sv.setup(**{"tabs.groups": True, "sidebar": True, "newtab.floating": floating})
    sv.launch()
    a, b, c, d = (sv.page(n) for n in ("a", "b", "c", "d"))
    sv.cmd({"do": "group", "id": a, "new": True, "name": "Basics"})
    sv.cmd({"do": "group", "id": b, "name": "Basics"})
    return a, b, c, d


def new_tab(front, page, mods=()):
    """⌘T with `front` on screen, `page` typed, Return."""
    sv.sp("select", id=front); time.sleep(0.4)
    press(17, "t", ["cmd"]); time.sleep(0.6)
    sv.cmd({"do": "field", "text": f"{sv.BASE}/{page}"}); time.sleep(0.4)
    press(36, "\r", mods); time.sleep(1.2)
    return st()


def main():
    t = sv.T()
    try:
        # The setting off: what ⌘T has always done from a grouped tab.
        a, b, c, d = start(False)
        s0 = st()
        t.ok("a and b in one group, c and d in none",
             gid(s0, "a") == gid(s0, "b") != "" and gid(s0, "c") == gid(s0, "d") == "", row(s0))
        plain = new_tab(a, "fresh")
        t.ok("setting off: ⌘T from a grouped tab opens in no group", gid(plain, "fresh") == "", row(plain))
        sv.quit()

        # The setting on, the same tab in front.
        a, b, c, d = start(True)
        s0 = st()
        s = new_tab(a, "fresh")
        t.ok("floating: one tab more", len(s["tabs"]) == len(s0["tabs"]) + 1, row(s))
        t.ok("floating: the tab made over a grouped tab is in no group", gid(s, "fresh") == "", row(s))
        t.ok("…and it is the one in front", name(next(x for x in s["tabs"] if x["id"] == s["activeID"])) == "fresh",
             s["activeID"])
        t.ok("…the group keeps its two tabs", [p for p, g in row(s) if g] == ["a", "b"], row(s))
        # But for the empty tab the window opened with, which ⌘T with the
        # setting off takes for its own and the field leaves where it was.
        pages = [x for x in row(s) if x[0]]
        t.ok("…and the row is the one the setting off gives", pages == row(plain), (pages, row(plain)))

        # Over a tab in no group: beside it, as before.
        s = new_tab(c, "beside")
        order = [p for p, _ in row(s)]
        t.ok("floating, over a tab in no group: in no group", gid(s, "beside") == "", row(s))
        t.ok("…and right after that tab", order.index("beside") == order.index("c") + 1, order)

        # ⌘K over a grouped tab, an address typed: a tab of its own too.
        sv.sp("select", id=b); time.sleep(0.4)
        n = len(st()["tabs"])
        press(40, "k", ["cmd"]); time.sleep(0.6)
        sv.cmd({"do": "field", "text": f"{sv.BASE}/switched"}); time.sleep(0.4)
        press(36, "\r"); time.sleep(1.2)
        s = st()
        t.ok("⌘K over a grouped tab: one tab more", len(s["tabs"]) == n + 1, row(s))
        t.ok("…in no group", gid(s, "switched") == "", row(s))
        t.ok("…the group keeps its two tabs", [p for p, g in row(s) if g] == ["a", "b"], row(s))

        # ⌘Return from a grouped tab's address is a page opened from it.
        sv.sp("select", id=b); time.sleep(0.4)
        press(37, "l", ["cmd"]); time.sleep(0.5)
        sv.cmd({"do": "field", "text": f"{sv.BASE}/aside"}); time.sleep(0.4)
        press(36, "\r", ["cmd"]); time.sleep(1.2)
        s = st()
        t.ok("⌘Return from a grouped tab still opens in its group",
             gid(s, "aside") == gid(s, "b") != "", row(s))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
