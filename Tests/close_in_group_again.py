#!/usr/bin/env python3
"""A tab in a group can be closed on its own with ⌘W (idea 1189), in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_in_group_again.py`.
It uses the split suite's harness: started hidden in a world of its own, no
window shown or brought forward, everything removed afterwards.

⌘W on a grouped tab puts it away (idea 398, close_in_group.py), and you
land on another tab. ⌘W only ever reaches the tab on screen, so going back
to the row put away and pressing ⌘W again put it away again, for ever: the
tab could only be closed by taking it out of its group, or with the row's
cross while it wasn't the tab on screen. Now a tab gone back to on the page
it was put away at closes for real, remembered for ⇧⌘T; one that has gone
elsewhere since is put away again, as any open page in a group is.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-in-group-again")

t = sv.T()
def st(): return sv.sp("state")
def by(s, id): return next((x for x in s["tabs"] if x["id"] == id), None)
def put(id): sv.sp("closeTab", id=id); time.sleep(0.4); return st()


def main():
    try:
        sv.setup(**{"tabs.groups": True, "sidebar": True}); sv.launch()
        c = sv.page("c")
        a, b = (sv.page(n) for n in ("a", "b"))
        for x in (a, b):
            sv.cmd({"do": "group", "id": x, **({"new": True} if x == a else {}), "name": "Work"})

        # ⌘W on a: put away, as before.
        sv.sp("select", id=a); s0 = st(); ghosts = s0["ghosts"]
        s = put(a)
        t.ok("⌘W on a: put away, still in the row", (by(s, a) or {}).get("asleep") is True, by(s, a))

        # Back to it, then ⌘W again: it goes.
        sv.sp("select", id=a); time.sleep(0.8)
        t.ok("back on a, awake", st()["activeID"] == a and by(st(), a)["asleep"] is False, by(st(), a))
        s = put(a)
        t.ok("⌘W again on a, on the page it was put away at: closed", by(s, a) is None, [x["id"] for x in s["tabs"]])
        t.ok("…remembered for ⇧⌘T", s["ghosts"] == ghosts + 1, (ghosts, s["ghosts"]))

        # A tab put away, gone back to and taken elsewhere: put away again.
        sv.sp("select", id=b); time.sleep(0.4)
        s = put(b)
        t.ok("⌘W on b: put away", (by(s, b) or {}).get("asleep") is True, by(s, b))
        sv.sp("select", id=b); time.sleep(0.8)
        sv.cmd({"do": "go", "id": b, "url": f"{sv.BASE}/b2"}); time.sleep(1.2)
        s = put(b)
        t.ok("b gone elsewhere since: ⌘W puts it away again", (by(s, b) or {}).get("asleep") is True, by(s, b))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
