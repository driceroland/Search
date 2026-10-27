#!/usr/bin/env python3
"""Fold All Groups and Unfold All Groups, in the View menu (⌥⌘[ and ⌥⌘])
and the space's menu, as in Arc.

Build first (`./build.sh`), then `python3 Tests/fold_all_groups.py`. A
hidden probe with two groups of two pages and a loose page; the menus'
own items are performed, as a click on them would be. Nothing here makes,
shows or brings forward a window, and no menu is popped up.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-va2-fold")


def group(**f): return sv.cmd({"do": "group", **f})


def folded(g): return [x["collapsed"] for x in g["groups"]]


def items(g, where): return {x["title"]: x for x in g[where]}


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "start.fresh": False, "spaces": True})
        sv.launch()
        g = group()
        t.ok("no groups: nothing in the space's menu", g["spaceItems"] == [], g["spaceItems"])
        a, b, c, d = (sv.page(n) for n in ("a", "b", "c", "d"))
        group(id=a, new=True, name="One"); group(id=b, name="One")
        group(id=c, new=True, name="Two"); group(id=d, name="Two")
        # Opened beside a page of a group, a page joins it: taken out.
        group(id=sv.page("loose"), name="none")
        g = group()
        t.ok("two open groups", folded(g) == [False, False], g)
        v = items(g, "viewItems")
        t.ok("View has both items", set(v) == {"Fold All Groups", "Unfold All Groups"}, v)
        # On the keys of ⌘[ and ⌘] (Back, Forward), whatever this keyboard
        # types there: ^ and $ on a French one.
        back, forward = g["brackets"]
        t.ok("Fold All Groups is ⌥ and Back's ⌘[", back and v.get("Fold All Groups", {}).get("key") == back
             and v["Fold All Groups"]["option"] and v["Fold All Groups"]["command"], (v, g["brackets"]))
        t.ok("Unfold All Groups is ⌥ and Forward's ⌘]", forward and v.get("Unfold All Groups", {}).get("key") == forward
             and v["Unfold All Groups"]["option"], (v, g["brackets"]))
        s = items(g, "spaceItems")
        t.ok("the space's menu has both, Unfold greyed while all are open",
             s.get("Fold All Groups", {}).get("enabled") is True and s.get("Unfold All Groups", {}).get("enabled") is False, s)

        g = group(all="fold", via="view"); time.sleep(0.3)
        t.ok("View › Fold All Groups folds both", folded(group()) == [True, True], g)
        s = items(group(), "spaceItems")
        t.ok("then Fold greyed, Unfold not", s["Fold All Groups"]["enabled"] is False and s["Unfold All Groups"]["enabled"] is True, s)

        group(all="unfold", via="space"); time.sleep(0.3)
        t.ok("the space's Unfold All Groups opens both", folded(group()) == [False, False])

        group(name="One", fold=True)
        group(all="fold", via="space"); time.sleep(0.3)
        g = group()
        t.ok("one folded by hand, Fold All folds the other too", folded(g) == [True, True], g)
        t.ok("each keeps its two pages", [len(x["tabs"]) for x in g["groups"]] == [2, 2], g)
        group(all="unfold", via="view"); time.sleep(0.3)
        t.ok("View › Unfold All Groups opens both", folded(group()) == [False, False])

        # Kept: the file says so after a relaunch.
        group(all="fold"); time.sleep(0.5)
        sv.quit(); time.sleep(1); sv.launch(); time.sleep(1)
        t.ok("folded all, still folded after a relaunch", folded(group()) == [True, True], group())
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
