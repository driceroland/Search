#!/usr/bin/env python3
"""Close Tab on a tab in a group puts it away (idea 398), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_in_group.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown
or brought forward, everything removed afterwards. As Arc keeps a folder's
tabs: ⌘W (the bench's `closeTab`, the user's Close Tab) on a tab in a group
lets its page go and leaves its row in the group, asleep, at the page it was
on; going to it opens that page again. Asked of a row already put away, it
goes for good and ⇧⌘T brings it back into its group. A tab in no group and
Close Other Tabs still close for real (Close Group: close_group.py). A page
of a pair in a group is put away out of its pair.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-in-group")

t = sv.T()
def st(): return sv.sp("state")
def by(s, id): return next((x for x in s["tabs"] if x["id"] == id), None)
def gid(s, id):
    ids = [x["id"] for x in s["tabs"]]
    return s["groupIDs"][ids.index(id)] if id in ids else None
def group(name): return next((g for g in sv.cmd({"do": "group"})["groups"] if g["name"] == name), None)
def name(s, id): return (by(s, id) or {}).get("url", "").rsplit("/", 1)[-1]
def put(id): sv.sp("closeTab", id=id); time.sleep(0.4); return st()


def main():
    try:
        sv.setup(**{"tabs.groups": True, "sidebar": True, "splitView": True}); sv.launch()
        c = sv.page("c")
        a, b, d = (sv.page(n) for n in ("a", "b", "d"))
        sv.sp("select", id=c)
        for x in (a, b, d):
            sv.cmd({"do": "group", "id": x, **({"new": True} if x == a else {}), "name": "Work"})
        work = group("Work")["tabs"]
        t.ok("a, b and d in Work", sorted(work) == sorted([a, b, d]), work)

        # ⌘W on the tab on screen, in the group: put away, not closed.
        sv.sp("select", id=a); s0 = st(); ghosts = s0["ghosts"]
        s = put(a)
        t.ok("⌘W: a is still in the row", by(s, a) is not None, [x["id"] for x in s["tabs"]])
        t.ok("…still in Work", gid(s, a) == gid(s0, a) != "", (gid(s0, a), gid(s, a)))
        t.ok("…its page let go (asleep)", (by(s, a) or {}).get("asleep") is True, by(s, a))
        t.ok("…at the page it was on", name(s, a) == "a", name(s, a))
        t.ok("…and you are off it", s["activeID"] != a, s["activeID"])
        t.ok("…nothing to reopen: it never closed", s["ghosts"] == ghosts, (ghosts, s["ghosts"]))

        # A click on it opens it again where it was.
        sv.sp("select", id=a); time.sleep(0.8); s = st()
        t.ok("going to it: awake again, on its page", by(s, a)["asleep"] is False and name(s, a) == "a" and s["activeID"] == a, by(s, a))

        # The row's cross on a tab not on screen: put away where it stands.
        s = put(b)
        t.ok("the cross on b, not on screen: b asleep, in Work", (by(s, b) or {}).get("asleep") is True and gid(s, b) != "", by(s, b))
        t.ok("…and you stay where you were", s["activeID"] == a, s["activeID"])

        # Again, on the row already put away: it goes, and ⇧⌘T brings it back.
        s = put(b)
        t.ok("again on b, put away: closed for real", by(s, b) is None, [x["id"] for x in s["tabs"]])
        t.ok("…remembered for ⇧⌘T", s["ghosts"] == ghosts + 1, s["ghosts"])
        sv.sp("reopen"); time.sleep(0.6); s = st()
        back = next((x["id"] for x in s["tabs"] if name(s, x["id"]) == "b"), None)
        t.ok("⇧⌘T: b back in Work", back is not None and back in group("Work")["tabs"], (back, group("Work")))

        # A tab in no group closes as it always did.
        s = put(c)
        t.ok("⌘W on c, in no group: closed", by(s, c) is None, [x["id"] for x in s["tabs"]])

        # A pair in the group: the page closed is put away out of the pair,
        # the other stays open, both still in Work.
        sv.sp("pair", id=d, **{"with": a}, side="right"); time.sleep(0.6); s = st()
        t.ok("a and d side by side", len(s["splits"]) == 1, s["splits"])
        sv.sp("select", id=d)
        s = put(d)
        t.ok("⌘W on d in its pair: the pair is undone", len(s["splits"]) == 0, s["splits"])
        t.ok("…d put away in Work", (by(s, d) or {}).get("asleep") is True and gid(s, d) != "", by(s, d))
        t.ok("…a still open, in Work", (by(s, a) or {}).get("asleep") is False and gid(s, a) != "", by(s, a))

        # Close Other Tabs keeps its meaning: the others close, grouped too.
        e = sv.page("e")
        s = st(); others = [x["id"] for x in s["tabs"] if x["id"] != e]
        sv.sp("closeOthers", id=e); time.sleep(0.6); s = st()
        t.ok("Close Other Tabs: the group's other tabs close for real", [x["id"] for x in s["tabs"]] == [e],
             ([x["id"] for x in s["tabs"]], others))

    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
