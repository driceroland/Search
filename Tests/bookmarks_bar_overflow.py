#!/usr/bin/env python3
"""The bookmarks bar's » for what it has no room for, and a middle-click on
its folders, in a hidden probe (ideas 958, 959).

Build first (`./build.sh`), then `python3 Tests/bookmarks_bar_overflow.py`.
It uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards. The window
is sized while hidden (bench `bar` width), on no screen.

The bar was a row that scrolled sideways with nothing to show it, so what
ran off the window's right edge could only be reached with a trackpad. Now
what doesn't fit is left out and a » at the end lists exactly those, in
order, folders as submenus; a pick from it opens as a click on the bar does.
With room for all, there is no ». A middle-click on a folder of the bar
opens its bookmarks, not its folders', each in a new tab, as a bookmark's
middle-click opens it in one.
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-bar-overflow")


def mark(title, url):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "url": url}


def folder(title, children):
    return {"id": str(uuid.uuid4()).upper(), "title": title, "children": children}


def world(roots):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump(roots, open(f"{sv.SUPPORT}/bookmarks.json", "w"))


def main():
    t = sv.T()
    try:
        # Few: room for all, no ».
        sv.setup(sidebar=False, **{"bookmarks.bar": True})
        world([mark(f"Site {i}", f"{sv.BASE}/few{i}") for i in range(3)])
        sv.launch()
        b = sv.cmd({"do": "bar", "width": 1100})
        t.ok("three bookmarks in a wide window: all on the bar, no »", b["hidden"] == [] and len(b["roots"]) == 3, b)
        sv.quit()

        # Many, a folder among them and one first.
        inner = folder("Inner", [mark("In 1", f"{sv.BASE}/in1")])
        deep = folder("Deep", [mark("Deep 1", f"{sv.BASE}/deep1"), mark("Deep 2", f"{sv.BASE}/deep2"), inner])
        first = folder("First", [mark("F1", f"{sv.BASE}/f1"), mark("F2", f"{sv.BASE}/f2"), mark("F3", f"{sv.BASE}/f3"),
                                 folder("Sub", [mark("S1", f"{sv.BASE}/s1")])])
        many = [first] + [mark(f"Bookmark number {i}", f"{sv.BASE}/m{i}") for i in range(30)]
        many.insert(25, deep)
        sv.setup(sidebar=False, **{"bookmarks.bar": True})
        world(many)
        sv.launch()
        b = sv.cmd({"do": "bar", "width": 900})
        roots, hidden = b["roots"], b["hidden"]
        k = len(roots) - len(hidden)
        t.ok("thirty-two at 900 points: some are left for the »", 0 < len(hidden) < len(roots), b)
        t.ok("the » holds exactly the last ones, in order", hidden == roots[k:], (roots, hidden))
        frames = b["frames"]
        last_shown = frames[k - 1]
        t.ok("the last one shown ends before the » (22 points and air at the end)",
             last_shown[0] + last_shown[2] <= 900 - 10 - 26 + 0.5, (last_shown, b["width"]))
        t.ok("the next one wouldn't have fitted beside the »",
             frames[k][0] + frames[k][2] > 900 - 10 - 26, frames[k])
        top = [m["title"] for m in b["menu"] if m["depth"] == 0]
        t.ok("the menu lists the hidden ones, no more", top == hidden, (top, hidden))
        deep_rows = [m for m in b["menu"] if m["depth"] >= 1]
        t.ok("a folder among them opens as a submenu, folders in it too",
             any(m["title"] == "Deep" and m["folder"] for m in b["menu"])
             and [m["title"] for m in deep_rows] == ["Deep 1", "Deep 2", "Inner", "In 1"], b["menu"])

        # A pick from the » opens as a click on the bar does: the empty
        # first tab takes it.
        pick = hidden[-1]
        p = sv.cmd({"do": "bar", "pick": pick})
        t.ok("a bookmark picked from the » opens", p["active"].endswith("/m29"), p)

        # Wider: fewer hidden; wide enough for all: no ».
        wide = sv.cmd({"do": "bar", "width": 1500})
        t.ok("wider, fewer go to the »", len(wide["hidden"]) < len(hidden) and wide["hidden"] == roots[len(roots) - len(wide["hidden"]):], wide["hidden"])

        # A middle-click on a folder of the bar: its three bookmarks, not
        # its folder's, each in a new tab behind.
        f = wide["frames"][0]
        before = sv.sp("state")
        m = sv.cmd({"do": "hit", "x": f[0] + f[2] / 2, "y": f[1] + f[3] / 2, "middle": True})
        time.sleep(0.5)
        after = sv.sp("state")
        urls = [x["url"] for x in after["tabs"]]
        t.ok("a middle-click on a folder opens its three bookmarks in new tabs",
             m.get("tabsAfter", 0) - m.get("tabsBefore", 0) == 3
             and [u.rsplit("/", 1)[-1] for u in urls[-3:]] == ["f1", "f2", "f3"], (m, urls))
        t.ok("…behind the tab in front", after.get("active") == before.get("active"), (before.get("active"), after.get("active")))

        # And still one bookmark's: one tab.
        g = wide["frames"][1]
        m2 = sv.cmd({"do": "hit", "x": g[0] + g[2] / 2, "y": g[1] + g[3] / 2, "middle": True})
        t.ok("a middle-click on a bookmark still opens it in one new tab", m2.get("tabsAfter", 0) - m2.get("tabsBefore", 0) == 1, m2)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
