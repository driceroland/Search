#!/usr/bin/env python3
"""Replace Pinned Page with Current URL: a pin taken somewhere else makes
that its page, the one a double-click, ⌘W and a restart take it back to.

Build first (`./build.sh`), then `python3 Tests/pin_rehome.py`. It uses the
split suite's harness: started hidden, in a world of its own, everything
removed afterwards.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-rehome")

t = sv.T()
def tab(st, id): return next(x for x in st["tabs"] if x["id"] == id)
def last(url): return url.rsplit("/", 1)[-1]
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def homes(): return [last(p["home"]) for defs in json.load(open(f"{sv.SUPPORT}/pins.json")).values() for p in defs]
def wander(id, to):
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{to}"}); sv.cmd({"do": "wait", "id": id}); time.sleep(0.3)

try:
    sv.setup(sidebar=True, **{"pins.home": True, "pins.peek": False}); sv.launch()
    a = sv.page("a"); sv.page("b")
    said = pin(a)
    t.ok("pinned at a", last(said["home"]) == "a", said)

    # At home there is nothing to replace.
    said = pin(a, rehome=True)
    t.ok("at home: the page stays a", last(said["home"]) == "a", said)

    wander(a, "elsewhere")
    said = pin(a, rehome=True)
    t.ok("taken elsewhere: that is its page now", last(said["home"]) == "elsewhere", said)
    sv.sp("save")
    t.ok("pins.json holds the new page", homes() == ["elsewhere"], homes())

    # A double-click goes to the new page, not the old one.
    wander(a, "later")
    pin(a, home=True); sv.cmd({"do": "wait", "id": a}); time.sleep(0.3)
    t.ok("home: back at the new page", last(tab(sv.sp("state"), a)["url"]) == "elsewhere",
         tab(sv.sp("state"), a)["url"])

    # So does ⌘W, with Pins go back home on.
    wander(a, "later")
    sv.sp("close", id=a); st = sv.sp("state")
    t.ok("⌘W: put down at the new page", last(tab(st, a)["url"]) == "elsewhere", tab(st, a)["url"])

    # And the next launch.
    sv.sp("save"); sv.quit(); sv.launch(); time.sleep(0.5)
    st = sv.sp("state")
    t.ok("restarted: the pin opens at the new page", [last(tab(st, id)["url"]) for id in st["pins"]] == ["elsewhere"], st["pins"])
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
