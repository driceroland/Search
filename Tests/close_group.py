#!/usr/bin/env python3
"""Close Group, from a tab group's menu (Browser.closeTabGroup), in a hidden probe.

Build first, then `python3 Tests/close_group.py` from a worktree. Three pages
go into a group and one stays out; the group is closed as its menu closes
it; then ⇧⌘T three times. The group and its tabs must go, the other tab
stay, and the three come back into a group of the same name.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("close-group")


def groups():
    return sv.cmd({"do": "group"})["groups"]


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True}); sv.launch()
        a, b, c, d = (sv.page(n) for n in ("a", "b", "c", "d"))
        sv.cmd({"do": "group", "id": a, "new": True, "name": "Work"})
        sv.cmd({"do": "group", "id": b, "name": "Work"})
        sv.cmd({"do": "group", "id": c, "name": "Work"})
        work = next((g for g in groups() if g["name"] == "Work"), None)
        t.ok("three pages in Work", work is not None and sorted(work["tabs"]) == sorted([a, b, c]), groups())

        after = sv.cmd({"do": "group", "close": True, "name": "Work"})["groups"]
        t.ok("Close Group: the group is gone", all(g["name"] != "Work" for g in after), after)
        left = [x["id"] for x in sv.sp("state")["tabs"]]
        t.ok("its tabs are closed, the one outside stays", d in left and not ({a, b, c} & set(left)), left)

        for _ in range(3):
            sv.sp("reopen")
        back = next((g for g in groups() if g["name"] == "Work"), None)
        t.ok("⇧⌘T three times: Work is back with its three tabs", back is not None and len(back["tabs"]) == 3, groups())
        urls = sorted(x["url"].rsplit("/", 1)[-1] for x in sv.sp("state")["tabs"] if x["id"] in (back or {}).get("tabs", []))
        t.ok("the same three pages", urls == ["a", "b", "c"], urls)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
