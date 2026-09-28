#!/usr/bin/env python3
"""Settings › Tabs › Pinned rows (#183): squares, rows, and the line's Clear.

Build first (`./build.sh`), then `python3 Tests/pin_tiers.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. What can only be seen (the rows under the squares, the
line, and Clear under the pointer) is checked by hand.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own: another checkout running the split suite at the same
# time answers on split-tests' socket, with its own build.
sv.W = "pin-tiers"
sv.SUPPORT = f"{sv.HOME}/Library/Application Support/Search ({sv.W})"
sv.SUITE = f"com.officecommun.search.test.{sv.W}"
sv.SOCK = f"{sv.SUPPORT}/bench.sock"

t = sv.T()
def by_url(st): return {x["id"]: x["url"].rsplit("/", 1)[-1] for x in st["tabs"]}
def names(st, ids): m = by_url(st); return [m[i] for i in ids]
def pins(st): return names(st, st["pins"])
def rows(st): return names(st, st["listed"])
def loose(st): return [x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] not in st["pins"] and not x["blank"]]
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def relaunch(**prefs):
    sv.sp("save"); sv.quit()
    for k, v in prefs.items(): subprocess.run(["defaults", "write", sv.SUITE, k, "-bool", "true" if v else "false"])
    sv.launch(); time.sleep(0.5)
    return sv.sp("state")

try:
    sv.setup(sidebar=True, **{"pins.list": True, "tabs.groups": True}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d"); e = sv.page("e")
    pin(a); pin(b, listed=True); pin(c, listed=True); pin(d)
    st = sv.sp("state")
    t.ok("squares first, then rows, each in the order pinned", pins(st) == ["a", "d", "b", "c"], pins(st))
    t.ok("the rows are the two pinned as rows", rows(st) == ["b", "c"], rows(st))

    sv.sp("move", id=b, to=0); st = sv.sp("state")
    t.ok("a row isn't carried among the squares", pins(st) == ["a", "d", "b", "c"], pins(st))
    sv.sp("move", id=a, to=3); st = sv.sp("state")
    t.ok("nor a square among the rows", pins(st) == ["a", "d", "b", "c"] and "a" not in rows(st), (pins(st), rows(st)))
    sv.sp("move", id=c, to=2); st = sv.sp("state")
    t.ok("a row is carried among the rows", pins(st) == ["a", "d", "c", "b"], pins(st))

    pin(d, listed=True); st = sv.sp("state")
    t.ok("a square made a row goes to the top of the rows", pins(st) == ["a", "d", "c", "b"] and rows(st) == ["d", "c", "b"], (pins(st), rows(st)))
    pin(b, listed=False); st = sv.sp("state")
    t.ok("a row made a square goes to the end of the squares", pins(st) == ["a", "b", "d", "c"] and rows(st) == ["d", "c"], (pins(st), rows(st)))

    sv.sp("save")
    kept = json.load(open(f"{sv.SUPPORT}/pins.json"))
    defs = next(iter(kept.values()))
    t.ok("pins.json marks the rows and only them",
         [(x["home"].rsplit("/", 1)[-1], x.get("listed")) for x in defs] == [("a", None), ("b", None), ("d", True), ("c", True)], defs)
    entries = [x for x in sv.session()["tabs"] if x.get("pin")]
    t.ok("the session marks the rows and only them",
         [(x["url"].rsplit("/", 1)[-1], x.get("listed")) for x in entries] == [("a", None), ("b", None), ("d", True), ("c", True)], entries)

    st = relaunch()
    t.ok("after a restart: the same squares and rows", pins(st) == ["a", "b", "d", "c"] and rows(st) == ["d", "c"], (pins(st), rows(st)))

    ids = {v: k for k, v in by_url(st).items()}
    pin(ids["c"], off=True); st = sv.sp("state")
    t.ok("an unpinned row is a loose tab again, and no row", "c" not in pins(st) and "c" in loose(st) and rows(st) == ["d"], (pins(st), loose(st), rows(st)))
    t.ok("…at the head of the loose tabs", loose(st)[0] == "c", loose(st))

    # Clear: the loose tabs go, the pins and a group stay, an empty tab in front.
    g = sv.page("g"); sv.sp("group", id=g)
    ids = {v: k for k, v in by_url(sv.sp("state")).items()}
    sv.sp("select", id=ids["e"]); st = sv.sp("state")
    before = [by_url(st)[x["id"]] for x in st["tabs"] if not x["blank"]]
    sv.sp("clear"); time.sleep(0.5); st = sv.sp("state")
    t.ok("Clear: ⇧⌘T's menu item says what it brings back", st["reopenTitle"] == "Reopen 2 Cleared Tabs", st["reopenTitle"])
    # One ⇧⌘T undoes all of it: the same row, the same tab in front.
    sv.sp("reopen"); time.sleep(0.5); st = sv.sp("state")
    after = [by_url(st)[x["id"]] for x in st["tabs"] if not x["blank"]]
    t.ok("undo: one ⇧⌘T brings every cleared tab back, each in its place", after == before, (after, before))
    t.ok("undo: the tab you were on is in front again", by_url(st)[st["activeID"]] == "e", by_url(st)[st["activeID"]])
    t.ok("undo: the empty tab Clear left is gone", not any(x["blank"] for x in st["tabs"]), st["tabs"])
    t.ok("undo: nothing left to reopen", st["ghosts"] == 0 and st["reopenTitle"] == "Reopen Closed Tab", (st["ghosts"], st["reopenTitle"]))
    ids = {v: k for k, v in by_url(st).items()}
    sv.sp("select", id=ids["e"]); sv.sp("clear"); time.sleep(0.5); st = sv.sp("state")
    t.ok("Clear: the loose tabs are gone", loose(st) == ["g"], loose(st))
    t.ok("Clear: the pins stay, squares and rows", pins(st) == ["a", "b", "d"] and rows(st) == ["d"], (pins(st), rows(st)))
    front = [x for x in st["tabs"] if x["id"] == st["activeID"]]
    t.ok("Clear: an empty tab in front", front and front[0]["blank"], front)
    sv.sp("select", id=ids["a"]); sv.page("h"); sv.sp("select", id=ids["a"]); sv.sp("clear"); st = sv.sp("state")
    t.ok("Clear from a pin: the pin stays in front", st["activeID"] == ids["a"] and loose(st) == ["g"], (st["activeID"], loose(st)))

    # Off: the rows are drawn as squares, and a pin carried across the
    # hidden line becomes the kind it landed among.
    st = relaunch(**{"pins.list": False})
    t.ok("switch off: the rows are kept, only not drawn", rows(st) == ["d"], rows(st))
    ids = {v: k for k, v in by_url(st).items()}
    sv.sp("move", id=ids["d"], to=0); st = sv.sp("state")
    t.ok("switch off: a row carried among the squares becomes one", pins(st) == ["d", "a", "b"] and rows(st) == [], (pins(st), rows(st)))
    sv.sp("move", id=ids["a"], to=2); st = sv.sp("state")
    t.ok("switch off: squares move as they always did", pins(st) == ["d", "b", "a"], pins(st))

    # With the tabs across the top, too, every pin is a square to carry.
    st = relaunch(sidebar=False, **{"pins.list": True})
    ids = {v: k for k, v in by_url(st).items()}
    pin(ids["a"], listed=True); st = sv.sp("state")
    sv.sp("move", id=ids["a"], to=0); st = sv.sp("state")
    t.ok("across the top: a row carried among the squares becomes one", pins(st)[0] == "a" and rows(st) == [], (pins(st), rows(st)))

    # More than the twelve closed tabs ⇧⌘T keeps, a pair among them, cleared
    # from a pin: all of it comes back as one step, the pair a pair again.
    st = relaunch(splitView=True)
    ids = {v: k for k, v in by_url(st).items()}
    many = [sv.page(f"m{i}") for i in range(12)]
    x = sv.page("x"); y = sv.page("y"); sv.sp("pair", id=y, **{"with": x}, side="right")
    sv.sp("select", id=ids["b"]); before = loose(sv.sp("state"))
    sv.sp("clear"); time.sleep(0.5); st = sv.sp("state")
    t.ok("Clear of 14: the menu item counts them all", st["reopenTitle"] == f"Reopen {len(before) - 1} Cleared Tabs", (st["reopenTitle"], before))
    sv.sp("reopen"); time.sleep(0.5); st = sv.sp("state")
    t.ok("undo of 14: every one of them back, in order", loose(st) == before, (loose(st), before))
    t.ok("undo of 14: the pin you were on stays in front", st["activeID"] == ids["b"], st["activeID"])
    back = by_url(st)
    t.ok("undo of 14: the pair is a pair again", [[back[i] for i in p["tabs"]] for p in st["splits"]] == [["x", "y"]], st["splits"])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
