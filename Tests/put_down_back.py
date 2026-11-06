#!/usr/bin/env python3
"""Back and Forward say what a tab's page can do after its view goes, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/put_down_back.py` from a
worktree. A pin put down with ⌘W lets its page go (Tab.rest); the view built
when it is clicked again has nothing to go back to, and Back showed lit from
the view before it, doing nothing. A tab that slept keeps its history and
says so again once woken.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("put-down-back")
t = sv.T()


def tab(id): return next((x for x in sv.sp("state")["tabs"] if x["id"] == id), None)
def walk(id, *names):
    for name in names:
        sv.ev(id, f"location.href = '{sv.BASE}/{name}'; true"); time.sleep(0.8)


try:
    sv.setup(); sv.launch()
    keep = sv.page("keep")

    # A pin put down and clicked again: Back off, as there is nothing behind it.
    p = sv.page("p1"); walk(p, "p2", "p3"); sv.cmd({"do": "pin", "id": p}); time.sleep(0.4)
    t.ok("pin: Back on before", tab(p)["canBack"], tab(p))
    sv.sp("close", id=p); time.sleep(0.5)
    t.ok("pin: put down, Back off", tab(p)["asleep"] and not tab(p)["canBack"], tab(p))
    sv.sp("select", id=p); time.sleep(2)
    t.ok("pin: woken, Back says what history has",
         tab(p)["canBack"] == (sv.ev(p, "history.length") > 1), (tab(p), sv.ev(p, "history.length")))
    # And it comes back on as the page goes on.
    walk(p, "p4"); time.sleep(0.3)
    t.ok("pin: a link followed, Back on", tab(p)["canBack"], tab(p))

    # A tab that slept: its history comes back, and Back with it.
    s = sv.page("s1"); walk(s, "s2"); sv.sp("select", id=keep); time.sleep(0.3)
    sv.sp("sleep", id=s); time.sleep(0.4)
    sv.sp("select", id=s); time.sleep(2)
    t.ok("slept: woken with Back on", tab(s)["canBack"] and sv.ev(s, "history.length") == 2, tab(s))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
