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
def counting(id): sv.cmd({"do": "eval", "id": id, "js": "window.__wheels = 0; addEventListener('wheel', function () { window.__wheels++ }, { passive: true }); 0"})
def wheels(id): return sv.cmd({"do": "eval", "id": id, "js": "window.__wheels"}).get("value") or 0

try:
    sv.setup(); sv.launch()
    tab = sv.page("a"); sv.cmd({"do": "select", "id": tab})
    # Loaded before the counter goes on, or it lands on the page a load replaces.
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})

    # Whether the bench's pull reaches a page at all here, before anything
    # depends on it: on the first page, with nothing to go back to, the swipe
    # has nowhere to go. On some Macs a page in a probe started hidden never
    # sees a made-up scroll; there the page's own check below is skipped,
    # rather than failing for the bench's sake.
    ui(swipepages=True)
    counting(tab); pull(300)
    reaches = wheels(tab) > 0
    go(tab, "b")

    # Swipe between pages on, as a Mac comes (still, from above): two fingers
    # back go back.
    r = pull(300)
    t.ok("setting on: the swipe goes back", page(r["before"]) == "b" and page(r["after"]) == "a", r)

    # Off, as the reporter has it: the same gesture leaves the page where it is.
    go(tab, "b")
    ui(swipepages=False)
    counting(tab)
    r = pull(300)
    t.ok("setting off: the swipe goes nowhere", page(r["before"]) == "b" and page(r["after"]) == "b", r)
    if reaches:
        t.ok("setting off: the page still gets the scroll", wheels(tab) > 0, wheels(tab))
    else:
        print("  skip  setting off: the page still gets the scroll (a made-up scroll didn't reach the page with the setting on)")

    # Back on: it swipes again.
    go(tab, "b")
    ui(swipepages=True)
    r = pull(300)
    t.ok("setting on again: the swipe goes back", page(r["before"]) == "b" and page(r["after"]) == "a", r)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
