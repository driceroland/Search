#!/usr/bin/env python3
"""New Tab in Group, from a group heading's menu, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/new_tab_in_group.py`. It
uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards.

As Chrome's "New tab in group": a new tab at the group's end, in front, the
group opened if it was folded; in the column and across the top alike.
With New tab in a floating field on, over a page, the field comes up and
no tab is made yet; Return makes the tab, at the group's end. The field
put away leaves nothing, and the next ⌘T's tab is in no group again.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-tab-in-group")


def press(code, ch, mods=()):
    return sv.cmd({"do": "press", "code": code, "chars": ch, "mods": list(mods)})


def st():
    return sv.sp("state")


def name(x):
    return x["url"].rsplit("/", 1)[-1] if x["url"] else ""


def groups():
    return {g["name"]: g for g in sv.cmd({"do": "group"})["groups"]}


def start(floating, sidebar):
    sv.setup(**{"tabs.groups": True, "sidebar": sidebar, "newtab.floating": floating})
    sv.launch()
    a, b, c = (sv.page(n) for n in ("a", "b", "c"))
    sv.cmd({"do": "group", "id": a, "new": True, "name": "Basics"})
    sv.cmd({"do": "group", "id": b, "name": "Basics"})
    sv.cmd({"do": "group", "id": c, "new": True, "name": "Later"})
    return a, b, c


def plain(t, sidebar):
    where = "column" if sidebar else "top row"
    a, b, c = start(False, sidebar)
    sv.sp("select", id=c); time.sleep(0.3)
    sv.cmd({"do": "group", "fold": True, "name": "Basics"})
    n = len(st()["tabs"])
    r = sv.cmd({"do": "group", "newTab": True, "name": "Basics"}); time.sleep(0.5)
    s, g = st(), groups()
    new = s["activeID"]
    t.ok(f"{where}: one tab more", len(s["tabs"]) == n + 1, len(s["tabs"]))
    t.ok(f"{where}: the new tab is in front and blank", new not in (a, b, c)
         and not next(x for x in s["tabs"] if x["id"] == new)["url"], (new, s["tabs"]))
    t.ok(f"{where}: at the group's end", g["Basics"]["tabs"] == [a, b, new], g["Basics"])
    t.ok(f"{where}: the folded group opened", not g["Basics"]["collapsed"], g["Basics"])
    t.ok(f"{where}: the other group untouched", g["Later"]["tabs"] == [c], g["Later"])
    t.ok(f"{where}: no field raised", not r["launching"], r)
    # A page typed into it stays in the group.
    sv.cmd({"do": "field", "text": f"{sv.BASE}/typed"}); time.sleep(0.3)
    press(36, "\r"); time.sleep(1.2)
    s, g = st(), groups()
    t.ok(f"{where}: the page typed loads in that tab, still in the group",
         g["Basics"]["tabs"] == [a, b, new] and name(next(x for x in s["tabs"] if x["id"] == new)) == "typed",
         (g["Basics"], [name(x) for x in s["tabs"]]))
    sv.quit()


def main():
    t = sv.T()
    try:
        plain(t, sidebar=False)
        plain(t, sidebar=True)

        # The floating field.
        a, b, c = start(True, False)
        sv.sp("select", id=c); time.sleep(0.3)
        n = len(st()["tabs"])
        r = sv.cmd({"do": "group", "newTab": True, "name": "Basics"}); time.sleep(0.5)
        t.ok("floating: the field comes up", r["launching"], r)
        t.ok("floating: no tab yet", len(st()["tabs"]) == n, len(st()["tabs"]))
        sv.cmd({"do": "field", "text": f"{sv.BASE}/fresh"}); time.sleep(0.4)
        press(36, "\r"); time.sleep(1.2)
        s, g = st(), groups()
        new = s["activeID"]
        t.ok("floating: Return makes one tab", len(s["tabs"]) == n + 1, len(s["tabs"]))
        t.ok("floating: it is the page typed, in front",
             name(next(x for x in s["tabs"] if x["id"] == new)) == "fresh", [name(x) for x in s["tabs"]])
        t.ok("floating: at the group's end", g["Basics"]["tabs"] == [a, b, new], g["Basics"])

        # Put away: nothing made, and ⌘T after is in no group.
        sv.sp("select", id=c); time.sleep(0.3)
        n = len(st()["tabs"])
        sv.cmd({"do": "group", "newTab": True, "name": "Basics"}); time.sleep(0.4)
        press(53, "\x1b"); time.sleep(0.5)
        t.ok("floating, put away: no tab made", len(st()["tabs"]) == n, len(st()["tabs"]))
        press(17, "t", ["cmd"]); time.sleep(0.6)
        sv.cmd({"do": "field", "text": f"{sv.BASE}/loose"}); time.sleep(0.4)
        press(36, "\r"); time.sleep(1.2)
        s, g = st(), groups()
        loose = next(x["id"] for x in s["tabs"] if name(x) == "loose")
        t.ok("then ⌘T's tab is in no group", all(loose not in gg["tabs"] for gg in g.values()), g)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
