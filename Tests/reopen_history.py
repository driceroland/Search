#!/usr/bin/env python3
"""⇧⌘T brings a tab back with its own history, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/reopen_history.py` from a
worktree. A closed tab keeps WebKit's interactionState (Tab.keepsake) in its
Ghost, so reopened it has Back, Forward and its scroll position, as a tab
that slept does. Checked for one tab, one asleep when closed, the only tab,
a Clear undone, a half of a pair, and a window closed and brought back; a
private tab is still never remembered.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("reopen-history")
t = sv.T()


def st(window=None): return sv.cmd({"do": "split", "action": "state", **({"window": window} if window else {})})
def at(s, name): return next((x for x in s["tabs"] if x["url"] == f"{sv.BASE}/{name}"), None)
def walk(id, *names, window=None):
    for name in names:
        sv.cmd({"do": "eval", "id": id, "js": f"location.href = '{sv.BASE}/{name}'; true", **({"window": window} if window else {})})
        time.sleep(0.8)
def length(id): return sv.ev(id, "history.length")
def woken(name, window=None):
    """The tab now at `name`, woken if it came back asleep."""
    tab = at(st(window), name)
    if tab and tab["asleep"]:
        sv.cmd({"do": "split", "action": "select", "id": tab["id"], **({"window": window} if window else {})})
        time.sleep(1.5)
        tab = at(st(window), name)
    return tab


try:
    sv.setup(**{"splitView": True}); sv.launch()
    keep = sv.page("keep")

    # One tab: a→b→c, scrolled, closed, back.
    a = sv.page("a"); walk(a, "b", "long")
    sv.ev(a, "scrollTo(0, 6000); true"); time.sleep(0.3)
    sv.sp("close", id=a); time.sleep(0.4); sv.sp("reopen"); time.sleep(1.5)
    back = at(st(), "long")
    t.ok("tab: back in front", back is not None and st()["activeID"] == back["id"], back)
    t.ok("tab: its history comes with it", back and length(back["id"]) == 3, back and length(back["id"]))
    t.ok("tab: where it was scrolled to", back and sv.ev(back["id"], "scrollY") == 6000, back and sv.ev(back["id"], "scrollY"))
    sv.ev(back["id"], "history.back(); true"); time.sleep(1)
    t.ok("tab: Back goes to the page before", at(st(), "b") is not None, [x["url"] for x in st()["tabs"]])
    t.ok("tab: and Forward is there", at(st(), "b")["canForward"], at(st(), "b"))
    sv.sp("close", id=back["id"])

    # Asleep when it closed: the history it slept with.
    s = sv.page("s1"); walk(s, "s2"); sv.sp("select", id=keep); time.sleep(0.3)
    sv.sp("sleep", id=s); time.sleep(0.4)
    t.ok("asleep: is asleep", st()["tabs"] and next(x for x in st()["tabs"] if x["id"] == s)["asleep"])
    sv.sp("close", id=s); time.sleep(0.4); sv.sp("reopen"); time.sleep(1.5)
    back = woken("s2")
    t.ok("asleep: back with Back", back and back["canBack"], back)
    sv.sp("close", id=back["id"])

    # A Clear undone: every tab with its own.
    c = sv.page("c1"); walk(c, "c2"); d = sv.page("d1"); walk(d, "d2")
    sv.sp("clear"); time.sleep(0.6); sv.sp("reopen"); time.sleep(1)
    for name in ("c2", "d2"):
        back = woken(name)
        t.ok(f"clear: {name} back with Back", back and back["canBack"], back)

    # A half of a pair: beside its partner again, with its history.
    left = sv.page("left"); right = sv.page("r1"); walk(right, "r2")
    sv.sp("pair", id=right, **{"with": left}, side="right"); time.sleep(0.5)
    sv.sp("close", id=right); time.sleep(0.4); sv.sp("reopen"); time.sleep(1.5)
    s_ = st(); back = at(s_, "r2")
    t.ok("pair: paired again", back and any(back["id"] in p["tabs"] for p in s_["splits"]), s_["splits"])
    t.ok("pair: with Back", back and back["canBack"], back)

    # A private tab: never kept, history or not.
    ghosts = st()["ghosts"]; sv.sp("private"); time.sleep(0.5)
    shy = next(x["id"] for x in st()["tabs"] if x["shy"])
    sv.ev(shy, f"location.href = '{sv.BASE}/secret'; true"); time.sleep(0.8)
    sv.sp("close", id=shy); time.sleep(0.4)
    t.ok("private: not remembered", st()["ghosts"] == ghosts, (ghosts, st()["ghosts"]))

    # A second window closed and brought back.
    sv.cmd({"do": "windows", "action": "new"}); time.sleep(1)
    w = sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/w1", "window": 2})["resultID"]; time.sleep(0.8)
    walk(w, "w2", window=2)
    sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(1)
    sv.cmd({"do": "windows", "action": "reopen"}); time.sleep(1.5)
    back = woken("w2", window=2)
    t.ok("window: its tab back with Back", back and back["canBack"], back)

    # The only tab: a new one takes its place, and ⇧⌘T still has its history.
    sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(1)
    only = sv.page("o1")
    for x in st()["tabs"]:
        if x["id"] != only: sv.sp("close", id=x["id"])
    walk(only, "o2"); sv.sp("close", id=only); time.sleep(0.5); sv.sp("reopen"); time.sleep(1.5)
    back = at(st(), "o2")
    t.ok("only tab: back with Back", back and back["canBack"], back)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
