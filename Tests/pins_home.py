#!/usr/bin/env python3
"""Settings › Tabs › Pins go back home: a pin closed with ⌘W, or open when
Search quits, comes back at the page it was pinned at, as in Arc.

Build first (`./build.sh`), then `python3 Tests/pins_home.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pins-home")

t = sv.T()
def tab(st, id): return next(x for x in st["tabs"] if x["id"] == id)
def last(url): return url.rsplit("/", 1)[-1]
def pinned(st): return [last(tab(st, id)["url"]) for id in st["pins"]]
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def relaunch(on):
    sv.sp("save"); sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "pins.home", "-bool", "true" if on else "false"])
    sv.launch(); time.sleep(0.5)
    return sv.sp("state")
def wander(id, to):
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{to}"}); sv.cmd({"do": "wait", "id": id}); time.sleep(0.3)

try:
    # Off, as some will have it: "Pins keep their site" is on by default
    # since 24 Oct 2026, and an explicit off on both its keys stands.
    sv.setup(sidebar=True, **{"pins.home": False, "pins.peek": False}); sv.launch()
    a = sv.page("a"); sv.page("b")
    pin(a)

    # Off: the pin keeps wherever it was taken.
    wander(a, "elsewhere")
    sv.sp("close", id=a); st = sv.sp("state")
    t.ok("off: ⌘W puts a pin down where it was", last(tab(st, a)["url"]) == "elsewhere", tab(st, a)["url"])
    st = relaunch(False)
    t.ok("off: after a restart it is still where it was", pinned(st) == ["elsewhere"], pinned(st))

    # On: Arc's pin.
    st = relaunch(True)
    t.ok("on: after a restart the pin is at the page it was pinned at", pinned(st) == ["a"], pinned(st))
    a = st["pins"][0]
    sv.sp("select", id=a); sv.cmd({"do": "wait", "id": a})
    wander(a, "away")
    t.ok("on: the pin goes where it is taken", last(tab(sv.sp("state"), a)["url"]) == "away")
    sv.sp("close", id=a); st = sv.sp("state")
    t.ok("on: ⌘W puts it down at its pinned page", last(tab(st, a)["url"]) == "a", tab(st, a)["url"])
    sv.sp("save")
    entry = next(x for x in sv.session()["tabs"] if x.get("pin"))
    t.ok("on: the session holds it at its pinned page", last(entry["url"]) == "a" and last(entry["home"]) == "a", entry)
    sv.sp("select", id=a); sv.cmd({"do": "wait", "id": a}); time.sleep(0.3)
    t.ok("on: picked again, it opens its pinned page", last(tab(sv.sp("state"), a)["url"]) == "a", tab(sv.sp("state"), a)["url"])

    # Taken somewhere and left open when Search quits.
    wander(a, "later")
    st = relaunch(True)
    t.ok("on: left elsewhere at quit, it opens again at home", pinned(st) == ["a"], pinned(st))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
