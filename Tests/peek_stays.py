#!/usr/bin/env python3
"""Peek stays with its tab (Settings › Keyboard & Mouse), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/peek_stays.py`. It uses
the split suite's harness in a world of its own (peek-stays): started hidden,
everything removed afterwards.

Off, as it is unless turned on: another tab puts a peek away, as it always
has. On: another tab hides it, coming back shows it, and ⌘W on the other tab
closes that tab, not the hidden peek. Closing the peek's own tab, or going to
another space, puts it away, so its page doesn't keep running out of sight.
In Split View the peek stays while either page of its pair is on screen.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("peek-stays")
t = sv.T()


def probe(): return sv.cmd({"do": "probe"})
def tabs(): return [x["id"] for x in sv.cmd({"do": "tabs"})["tabs"]]
def select(id): sv.cmd({"do": "select", "id": id}); time.sleep(0.4)
def press(code, chars, *mods): sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)}); time.sleep(0.4)


def until(check, seconds=4):
    """Polled, not slept: a peek's page loads in its own time."""
    for _ in range(int(seconds * 10)):
        if check(): return True
        time.sleep(0.1)
    return False


def pair_and_a_peek():
    """Two pages side by side, and a peek from the right one."""
    # Real tabs: a bench tab never goes into a pair (Browser.canSplit).
    left, right = sv.page("left"), sv.page("right")
    sv.sp("pair", id=right, **{"with": left, "side": "right"}); time.sleep(0.4)
    if not sv.sp("state")["splits"]: raise RuntimeError("no pair made")
    sv.sp("focus", id=right); time.sleep(0.3)
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"})
    until(lambda: probe()["peekShown"])
    return left, right


def two_tabs_and_a_peek():
    under = sv.cmd({"do": "open", "url": f"{sv.BASE}/under"})["id"]
    other = sv.cmd({"do": "open", "url": f"{sv.BASE}/other"})["id"]
    time.sleep(1)
    select(under)
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"})
    until(lambda: probe()["peek"].endswith("/peeked"))
    return under, other


peeked = lambda st: st["peekFrom"] != ""

try:
    # Off: another tab puts the peek away.
    sv.setup(); sv.launch()
    under, other = two_tabs_and_a_peek()
    st = probe()
    t.ok("off: a peek opens over its tab", st["peek"].endswith("/peeked") and st["peekShown"], st["peek"])
    select(other)
    st = probe()
    t.ok("off: another tab puts it away", not peeked(st) and not st["peekShown"], (st["peek"], st["peekFrom"]))
    select(under)
    t.ok("off: coming back, no peek", not peeked(probe()))
    left, right = pair_and_a_peek()
    sv.sp("focus", id=left); time.sleep(0.4)
    t.ok("off: the other page of a pair puts the peek away", not peeked(probe()), probe()["peekFrom"])

    # On: the peek waits for its tab.
    sv.setup(**{"links.peek.stays": True, "spaces": True}); sv.launch()
    under, other = two_tabs_and_a_peek()
    select(other)
    st = probe()
    t.ok("on: another tab hides the peek", peeked(st) and not st["peekShown"], st)
    t.ok("on: hidden, it is still the tab's", st["peekFrom"].lower().startswith(under.lower()), (st["peekFrom"], under))
    select(under)
    st = probe()
    t.ok("on: coming back shows the same peek", st["peekShown"] and st["peek"].endswith("/peeked"), st)

    # ⌘W where the peek is hidden closes that tab, not the peek.
    third = sv.cmd({"do": "open", "url": f"{sv.BASE}/third"})["id"]; time.sleep(0.8)
    select(third)
    press(13, "w", "cmd")
    t.ok("on: ⌘W on another tab closes that tab", until(lambda: third not in tabs()), tabs())
    t.ok("on: and leaves the hidden peek", peeked(probe()), probe()["peekFrom"])
    select(under)
    t.ok("on: back on its tab, the peek is there", probe()["peekShown"])
    press(13, "w", "cmd")
    t.ok("on: ⌘W over the peek puts the peek away", until(lambda: not peeked(probe())), probe()["peekFrom"])
    t.ok("on: and keeps its tab", under in tabs(), tabs())

    # Its tab closed while hidden: the peek goes with it.
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"})
    until(lambda: probe()["peekShown"])
    select(other)
    sv.cmd({"do": "close", "id": under}); time.sleep(0.4)
    t.ok("on: closing its tab puts the hidden peek away", not peeked(probe()), probe()["peekFrom"])

    # Another space: no peek left running out of sight.
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"})
    until(lambda: probe()["peekShown"])
    sv.cmd({"do": "space", "action": "new", "name": "Two"}); time.sleep(0.5)
    sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(0.8)
    t.ok("on: another space puts the peek away", not peeked(probe()), probe()["peekFrom"])

    # Split View: either page of the pair is on screen, so the peek stays.
    left, right = pair_and_a_peek()
    st = probe()
    t.ok("on: a peek from the right page of a pair", st["peekShown"] and st["peekFrom"].lower().startswith(right.lower()), st)
    sv.sp("focus", id=left); time.sleep(0.4)
    t.ok("on: the other page of the pair keeps it in front", probe()["peekShown"], probe())
    lone = sv.cmd({"do": "open", "url": f"{sv.BASE}/lone"})["id"]; time.sleep(0.8)
    select(lone)
    st = probe()
    t.ok("on: a tab out of the pair hides it", peeked(st) and not st["peekShown"], st)
    select(left)
    t.ok("on: back on the pair, it is in front again", probe()["peekShown"], probe())
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
