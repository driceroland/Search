#!/usr/bin/env python3
"""⌘T never reuses an empty tab that sits in a group (#1151).

Build first (`./build.sh`), then `python3 Tests/new_tab_grouped_blank.py`. It
uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards.

⌘T takes an empty tab it finds rather than make a second one. An empty tab
left in a group was taken too, so the page typed next opened in that group,
from a tab in no group. Now ⌘T's tab is in no group, and an empty tab in no
group is still reused.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-tab-grouped-blank")


def st():
    return sv.sp("state")


def gid(s, tab):
    return next((s["groupIDs"][i] for i, x in enumerate(s["tabs"]) if x["id"] == tab), None)


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "sidebar": True})
        sv.launch()
        a = sv.page("a")
        b = sv.page("b")
        sv.cmd({"do": "group", "id": a, "new": True, "name": "Basics"})
        # An empty tab, put in the group.
        blank = sv.sp("newTab")["activeID"]
        sv.cmd({"do": "group", "id": blank, "name": "Basics"})
        s = st()
        t.ok("an empty tab sits in the group", gid(s, blank) == gid(s, a) != "", s["groupIDs"])

        # ⌘T from b, in no group.
        sv.sp("select", id=b); time.sleep(0.4)
        made = sv.sp("newTab")["activeID"]; time.sleep(0.4)
        s = st()
        t.ok("⌘T doesn't take the grouped empty tab", made != blank, (made, blank))
        t.ok("…its tab is in no group", gid(s, made) == "", s["groupIDs"])
        t.ok("…the grouped empty tab stays where it was", gid(s, blank) == gid(s, a), s["groupIDs"])

        # And an empty tab in no group is still reused.
        sv.sp("select", id=b); time.sleep(0.4)
        again = sv.sp("newTab")["activeID"]
        t.ok("a second ⌘T reuses the empty tab in no group", again == made, (again, made))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
