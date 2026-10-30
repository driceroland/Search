#!/usr/bin/env python3
"""Tabs picked in the column (⌘- or ⇧-click), then ⌘W or the tab menu's
Close Tabs: every picked tab closes, not only the one in front, and one ⇧⌘T
brings them all back. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_picked.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. `split pick` makes the ⌘-clicks the column makes
(Browser.extendTabSelection), ⌘W is pressed as a real key, and `split
closePicked` is the menu item's action. That the menu reads "Close 3 Tabs" is
looked at by hand on a release candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own (see use()).
sv.use("close-picked")

t = sv.T()
def state(): return sv.sp("state")
def pick(*ids): return sv.sp("pick", ids=list(ids))
def cmd_w(): sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]}); time.sleep(0.6); return state()
def urls(st): return [x["url"].rsplit("/", 1)[-1] for x in st["tabs"]]


def case_command_w(t):
    """⌘W with three picked: all three close, one ⇧⌘T brings them back"""
    sv.setup(sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d"); e = sv.page("e")
    sv.sp("select", id=b)
    before = urls(state())
    # b is in front, so the first ⌘-click picks it too, as in the column.
    st = pick(b, c, e)
    t.ok("pick: b, c and e", sorted(st["selected"]) == sorted([b, c, e]), st["selected"])
    st = cmd_w()
    ids = sv.order(st)
    t.ok("⌘W: b, c and e are closed", not any(x in ids for x in (b, c, e)), urls(st))
    t.ok("⌘W: a and d stay", a in ids and d in ids, urls(st))
    t.ok("⌘W: off the closed tabs, onto one still open", st["activeID"] in (a, d), st["activeID"])
    t.ok("⌘W: the selection is done with", st["selected"] == [], st["selected"])
    t.ok("⌘W: ⇧⌘T offers all three as one", st["reopenTitle"] == "Reopen 3 Closed Tabs", st["reopenTitle"])
    st = sv.sp("reopen"); time.sleep(0.5)
    t.ok("⇧⌘T: all three back where they were", urls(st) == before, (before, urls(st)))
    back = next(x["id"] for x in st["tabs"] if x["url"].endswith("/b"))
    t.ok("⇧⌘T: the one in front is in front again", st["activeID"] == back, st["activeID"])

    # Nothing picked: ⌘W closes the tab in front, as always.
    st = state(); front = st["activeID"]; count = len(st["tabs"])
    st = cmd_w()
    t.ok("nothing picked: ⌘W closes only the tab in front", len(st["tabs"]) == count - 1 and front not in sv.order(st), urls(st))


def case_not_in_front(t):
    """picked tabs that leave out the one in front: those close, it stays"""
    sv.setup(sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.sp("select", id=c)
    # ⌘-clicking c (in front) again takes it out of the picked.
    st = pick(a, b, c)
    t.ok("pick: a and b, not c", sorted(st["selected"]) == sorted([a, b]), st["selected"])
    st = cmd_w()
    ids = sv.order(st)
    t.ok("⌘W: a and b are closed", a not in ids and b not in ids, urls(st))
    t.ok("⌘W: c stays in front", c in ids and st["activeID"] == c, (urls(st), st["activeID"]))


def case_menu(t):
    """the menu's Close Tabs, and every tab picked"""
    sv.setup(sidebar=True, **{"tabs.groups": False}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.sp("select", id=a)
    pick(b, c)
    st = sv.sp("closePicked")
    ids = sv.order(st)
    t.ok("menu: b and c are closed", b not in ids and c not in ids, urls(st))
    t.ok("menu: a stays in front", a in ids and st["activeID"] == a, (urls(st), st["activeID"]))
    t.ok("menu: ⇧⌘T offers both as one", st["reopenTitle"] == "Reopen 2 Closed Tabs", st["reopenTitle"])

    # Every tab in the window picked: a new tab is left, as the last tab
    # closed leaves one, and the window stays.
    b = sv.page("b2"); sv.sp("select", id=a)
    # a, in front, first: the first ⌘-click picks it; a later one would let go.
    everything = [x["id"] for x in state()["tabs"]]
    st = pick(a, *[x for x in everything if x != a])
    t.ok("all picked: every tab", sorted(st["selected"]) == sorted(everything), (st["selected"], everything))
    st = cmd_w()
    t.ok("all picked: one new tab left", len(st["tabs"]) == 1 and st["tabs"][0]["blank"], urls(st))


def case_pair_and_pin(t):
    """a picked Split View pair goes whole; a picked pin is put down"""
    sv.setup(splitView=True, sidebar=True, **{"tabs.groups": False}); sv.launch()
    p = sv.page("p"); a = sv.page("a"); l = sv.page("l"); r = sv.page("r"); z = sv.page("z")
    sv.cmd({"do": "pin", "id": p})
    sv.sp("pair", id=r, **{"with": l}, side="right")
    sv.sp("select", id=z)
    st = pick(p, l, r)
    t.ok("pick: the pin and both halves", sorted(st["selected"]) == sorted([p, l, r]), st["selected"])
    st = cmd_w()
    ids = sv.order(st)
    t.ok("⌘W: both halves are closed", l not in ids and r not in ids, urls(st))
    t.ok("⌘W: no pair left", st["splits"] == [], st["splits"])
    t.ok("⌘W: the pin keeps its place, put down", p in ids, urls(st))
    t.ok("⌘W: a and z stay, z in front", a in ids and z in ids and st["activeID"] == z, (urls(st), st["activeID"]))
    st = sv.sp("reopen"); time.sleep(0.5)
    t.ok("⇧⌘T: the pair comes back a pair", len(st["splits"]) == 1, st["splits"])


def case_group(t):
    """picked tabs in a group are put away, as ⌘W puts one away"""
    sv.setup(sidebar=True, **{"tabs.groups": True}); sv.launch()
    loose = sv.page("loose"); a = sv.page("a"); b = sv.page("b")
    for x in (a, b):
        sv.cmd({"do": "group", "id": x, **({"new": True} if x == a else {}), "name": "Work"})
    sv.sp("select", id=a)
    st = pick(a, b, loose)
    t.ok("pick: a, b and the loose tab", sorted(st["selected"]) == sorted([a, b, loose]), st["selected"])
    st = cmd_w()
    rows = {x["id"]: x for x in st["tabs"]}
    t.ok("⌘W: the loose tab is closed", loose not in rows, urls(st))
    t.ok("⌘W: a and b stay in the row, asleep", all(x in rows and rows[x]["asleep"] for x in (a, b)), [rows.get(x) for x in (a, b)])
    t.ok("⌘W: off them", st["activeID"] not in (a, b, loose), st["activeID"])


def main():
    for case in [case_command_w, case_not_in_front, case_menu, case_pair_and_pin, case_group]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
