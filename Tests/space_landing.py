#!/usr/bin/env python3
"""Which tab a space lands on, and how its folders look on the way in.

Build first (`./build.sh`), then `python3 Tests/space_landing.py`. A hidden
probe (spaces and tab groups on, Start with a fresh window off) gets a
second space holding a folded group of three pages and an empty tab in
front (Varun, 1.0.5):

- mid-swipe, the space coming in is drawn with its group folded, as it will
  be once it lands, not with every page of the group out (Parked.drawn);
- gone to again, in the same run and after ⌘Q and a relaunch, it opens on
  what was in front when it was left — the empty tab, as an empty tab —
  never on the last page of the folded group;
- a page in front is still the page in front after a relaunch.

Nothing here makes, shows or brings forward a window.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hub-va-land")


def space(**f): return sv.cmd({"do": "space", **f})


def group(**f): return sv.cmd({"do": "group", **f})


def state(): return sv.sp("state")


def front():
    st = state()
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None), st


def two_id():
    return next(s["id"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json")) if s["name"] == "Two")


def main():
    t = sv.T()
    try:
        sv.setup(**{"spaces": True, "tabs.groups": True, "start.fresh": False})
        sv.launch()
        space(action="new", name="Two")
        time.sleep(0.8)
        t.ok("in the second space", space()["current"] == "Two")
        pages = [sv.page(n) for n in ("alpha", "beta", "gamma")]
        group(id=pages[0], new=True, name="Folder")
        for p in pages[1:]: group(id=p, name="Folder")
        g = group()
        t.ok("the three pages are in one group", len(g["groups"]) == 1 and len(g["groups"][0]["tabs"]) == 3, g)
        sv.sp("newTab"); time.sleep(0.5)
        blank, st = front()
        t.ok("an empty tab in front", blank and blank["blank"], blank)
        group(name="Folder", fold=True)
        t.ok("the group is folded", group()["groups"][0]["collapsed"] is True)

        # Point 3: the space coming in, drawn folded.
        space(action="go", index=1); time.sleep(0.8)
        r = space(action="hold", dx=-30)
        d = r.get("drawn", {}).get("Two", {})
        t.ok("mid-swipe, the space coming in draws its group folded",
             r.get("swipe", 0) != 0 and [(x["name"], x["collapsed"], x["tabs"]) for x in d.get("groups", [])]
             == [("Folder", True, [])], d)
        t.ok("and none of the folded pages among its loose tabs",
             not set(d.get("loose", [])) & set(pages) and blank["id"] in d.get("loose", []), d)
        space(action="release"); time.sleep(0.6)
        t.ok("a short swipe stays where it was", space()["current"] != "Two")

        # Point 5: gone to again, in the same run.
        space(action="go", index=2); time.sleep(0.8)
        f, st = front()
        t.ok("back in the space: the empty tab it was left on", f and f["id"] == blank["id"], f)
        space(action="go", index=1); time.sleep(0.8)
        shape = json.load(open(f"{sv.SUPPORT}/session-{two_id()}.json"))
        t.ok("its file says nothing was in front, not the group's last page",
             shape.get("active") == -1, shape.get("active"))

        # After ⌘Q and a relaunch.
        sv.quit(); time.sleep(1); sv.launch(); time.sleep(1)
        space(action="go", index=2); time.sleep(1)
        f, st = front()
        g = group()
        t.ok("after a relaunch: an empty tab in front, not a page of the folded group",
             f and f["blank"] and f["id"] not in (g["groups"][0]["tabs"] if g["groups"] else []), (f, g))
        t.ok("the group is still folded with its three pages",
             g["groups"] and g["groups"][0]["collapsed"] and len(g["groups"][0]["tabs"]) == 3, g)

        # A page in front stays the page in front.
        loose = sv.page("delta")
        sv.sp("select", id=loose); time.sleep(0.4)
        space(action="go", index=1); time.sleep(0.8)
        sv.quit(); time.sleep(1); sv.launch(); time.sleep(1)
        space(action="go", index=2); time.sleep(1)
        f, st = front()
        t.ok("a page left in front is in front after a relaunch", f and f["url"].endswith("/delta"), f)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
