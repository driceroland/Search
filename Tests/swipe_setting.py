#!/usr/bin/env python3
"""The swipe back and forward follows the Mac's Swipe between pages (#464), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/swipe_setting.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The Mac's own setting is never touched: a test run stands
in for it with `ui swipepages on|off`.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("swipe-setting")

t = sv.T()
def page(r): return r.rsplit("/", 1)[-1]
def pull(dx): return sv.cmd({"do": "pull", "dx": dx, "steps": 12, "ms": 240})
def go(id, name): sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{name}"}); sv.cmd({"do": "wait", "id": id, "seconds": 5})
def ui(**f): sv.cmd({"do": "ui", **f}); time.sleep(0.3)

try:
    sv.setup(); sv.launch()
    tab = sv.page("a"); sv.cmd({"do": "select", "id": tab}); go(tab, "b")

    # Swipe between pages on, as a Mac comes: two fingers back go back.
    ui(swipepages=True)
    r = pull(300)
    t.ok("setting on: the swipe goes back", page(r["before"]) == "b" and page(r["after"]) == "a", r)

    # Off, as the reporter has it: the same gesture leaves the page where it is.
    go(tab, "b")
    ui(swipepages=False)
    sv.cmd({"do": "eval", "id": tab, "js": "window.__wheels = 0; addEventListener('wheel', function () { window.__wheels++ }, { passive: true }); 0"})
    r = pull(300)
    t.ok("setting off: the swipe goes nowhere", page(r["before"]) == "b" and page(r["after"]) == "b", r)
    wheels = sv.cmd({"do": "eval", "id": tab, "js": "window.__wheels"})
    t.ok("setting off: the page still gets the scroll", (wheels.get("value") or 0) > 0, wheels)

    # Back on: it swipes again.
    go(tab, "b")
    ui(swipepages=True)
    r = pull(300)
    t.ok("setting on again: the swipe goes back", page(r["before"]) == "b" and page(r["after"]) == "a", r)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
