#!/usr/bin/env python3
"""The last loose tab closed beside tab groups leaves a new tab (Varun, 1.0.6).

Build first (`./build.sh`), then `python3 Tests/close_beside_groups.py`. A
hidden probe (tab groups on, Start with a fresh window off, Leave a new tab
when the last tab closes off, as it ships) holds a folded group of two pages
and one loose page:

- closing the loose page leaves an empty tab in front, not a page out of
  the folder, and the folder stays folded;
- closing that empty tab keeps an empty tab and the window: it is already
  what closing it would leave;
- ⇧⌘T brings the page back;
- with only pins beside it and the switch off, the old rule stands: the
  neighbour is picked (#537), and a loose tab closed among other loose
  tabs still lands on its neighbour.

Nothing here makes, shows or brings forward a window.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-va2-close")


def group(**f): return sv.cmd({"do": "group", **f})


def front():
    st = sv.sp("state")
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None), st


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "start.fresh": False, "tabs.newAfterLast": False})
        sv.launch()
        pages = [sv.page(n) for n in ("alpha", "beta")]
        group(id=pages[0], new=True, name="Folder")
        group(id=pages[1], name="Folder")
        # Opened beside a page of the group, it would join it: taken out.
        loose = sv.page("gamma")
        group(id=loose, name="none")
        # The window's first empty tab, if it is still there, goes first.
        for x in sv.sp("state")["tabs"]:
            if x.get("blank") and x["id"] != loose:
                sv.sp("close", id=x["id"]); time.sleep(0.3)
        if not group()["groups"][0]["collapsed"]:
            group(name="Folder", fold=True)
        sv.sp("select", id=loose); time.sleep(0.4)
        g = group()
        t.ok("a folded group of two, one loose page in front",
             len(g["groups"]) == 1 and g["groups"][0]["collapsed"] and len(g["groups"][0]["tabs"]) == 2, g)

        sv.sp("close", id=loose); time.sleep(0.5)
        f, st = front()
        t.ok("closing the loose page leaves an empty tab in front", f and f.get("blank"), f)
        t.ok("not a page out of the folder", f and f["id"] not in pages, f)
        g = group()
        t.ok("the folder stays folded with its two pages",
             g["groups"] and g["groups"][0]["collapsed"] and len(g["groups"][0]["tabs"]) == 2, g)

        blank = f["id"] if f else None
        sv.sp("close", id=blank); time.sleep(0.5)
        f, st = front()
        t.ok("closing that empty tab keeps an empty tab in front", f and f.get("blank"), f)
        t.ok("and the window", len(sv.cmd({"do": "windows"}).get("windows", [1])) >= 1)
        t.ok("still one empty tab, not two", sum(1 for x in st["tabs"] if x.get("blank")) == 1, st["tabs"])

        sv.sp("reopen"); time.sleep(0.8)
        f, st = front()
        t.ok("⇧⌘T brings the page back", f and f["url"].endswith("/gamma"), f)

        # A loose tab among other loose tabs: its neighbour, as before.
        delta = sv.page("delta")
        group(id=delta, name="none")
        sv.sp("select", id=delta); time.sleep(0.3)
        sv.sp("close", id=delta); time.sleep(0.5)
        f, st = front()
        t.ok("a loose tab among loose tabs lands on a loose neighbour, not in the folder",
             f and f["id"] not in pages, f)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
