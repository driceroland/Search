#!/usr/bin/env python3
"""Close Group, from a tab group's menu (Browser.closeTabGroup), in a hidden probe.

Build first, then `python3 Tests/close_group.py` from a worktree. Three pages
go into a group and one stays out; the group is closed as its menu closes
it; then one ⇧⌘T. The group and its tabs must go, the other tab stay, and
the three come back together, in their order, into a group of the same name.
Then a group of thirteen, more than the twelve steps ⇧⌘T keeps, closed with
the page on screen in it: one ⇧⌘T brings all of it back, that page in front.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own: another checkout running the split suite at the same
# time answers on split-tests' socket, with its own build.
sv.W = "close-group"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"
sv.SOCK = f"{sv.SUPPORT}/bench.sock"


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

        t.ok("⇧⌘T's menu item says a group", sv.sp("state")["reopenTitle"] == "Reopen Closed Group", sv.sp("state")["reopenTitle"])
        sv.sp("reopen")
        back = next((g for g in groups() if g["name"] == "Work"), None)
        t.ok("one ⇧⌘T: Work is back with its three tabs", back is not None and len(back["tabs"]) == 3, groups())
        st = sv.sp("state")
        urls = [x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] in (back or {}).get("tabs", [])]
        t.ok("the same three pages, in their order", urls == ["a", "b", "c"], urls)
        t.ok("nothing left to reopen", st["ghosts"] == 0, st["ghosts"])

        # Thirteen, the page on screen among them.
        many = [sv.page(f"m{i}") for i in range(13)]
        sv.cmd({"do": "group", "id": many[0], "new": True, "name": "Big"})
        for tab in many[1:]:
            sv.cmd({"do": "group", "id": tab, "name": "Big"})
        sv.sp("select", id=many[6])
        sv.cmd({"do": "group", "close": True, "name": "Big"})
        t.ok("Big is closed", all(g["name"] != "Big" for g in groups()), groups())
        sv.sp("reopen")
        big = next((g for g in groups() if g["name"] == "Big"), None)
        st = sv.sp("state")
        urls = [x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] in (big or {}).get("tabs", [])]
        t.ok("one ⇧⌘T: all thirteen back in Big, in their order", urls == [f"m{i}" for i in range(13)], urls)
        front = next((x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] == st["activeID"]), None)
        t.ok("the page you were on is in front again", front == "m6", front)

        # Clear, then Close Group, then ⇧⌘T twice: the group's undo first,
        # then the Clear's, which still takes away the empty tab it left.
        # From d, outside any group: a page opened from a grouped tab joins
        # its group, and Clear would leave it.
        sv.sp("select", id=d); z = sv.page("z")
        st = sv.sp("state")
        t.ok("z is in no group", st["groupIDs"][[x["id"] for x in st["tabs"]].index(z)] == "", st["groupIDs"])
        sv.sp("clear")
        blanks = [x["id"] for x in sv.sp("state")["tabs"] if x["blank"]]
        t.ok("Clear leaves an empty tab in front", len(blanks) == 1 and sv.sp("state")["activeID"] == blanks[0], blanks)
        sv.cmd({"do": "group", "close": True, "name": "Work"})
        sv.sp("reopen"); sv.sp("reopen")
        st = sv.sp("state")
        names = [x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if not x["blank"]]
        t.ok("both undone: Work and the cleared tabs are back", any(g["name"] == "Work" for g in groups()) and "z" in names and "d" in names, (groups(), names))
        t.ok("…and the empty tab the Clear left is gone", not any(x["blank"] for x in st["tabs"]), [x["id"] for x in st["tabs"] if x["blank"]])
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
