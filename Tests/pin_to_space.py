#!/usr/bin/env python3
"""Move to Space on a pin, to a space not opened before quitting, in a hidden
probe.

Build first (`./build.sh`), then `python3 Tests/pin_to_space.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The moved pin used to be kept only in the row of the
space it went to, never in that space's list in pins.json, so the next look
at that space's pins (a relaunch) found it in no list and closed it.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout: it quits
# and relaunches between runs (see use()).
sv.use("pin-to-space")

t = sv.T()
def urls(st): return [x["url"] for x in st["tabs"]]
def pinned(st): m = {x["id"]: x["url"] for x in st["tabs"]}; return [m[i] for i in st["pins"]]
def listed(space): return [d["home"] for d in json.load(open(f"{sv.SUPPORT}/pins.json")).get(space, [])]
def go(id): sv.sp("space", spaceAction="go", spaceID=id); time.sleep(0.8)
try:
    sv.setup(spaces=True); sv.launch()
    first = sv.sp("state")["spaceID"]
    sv.sp("space", spaceAction="new", name="Two"); time.sleep(1)
    two = sv.sp("state")["spaceID"]
    # A row there already: the square that comes in goes ahead of it.
    r = sv.page("r"); sv.cmd({"do": "pin", "id": r, "listed": True}); time.sleep(0.5)
    go(first)
    keep = sv.page("keep"); sv.cmd({"do": "pin", "id": keep})
    x = sv.page("x"); sv.cmd({"do": "pin", "id": x}); time.sleep(0.5)
    moved = sv.cmd({"do": "tospace", "id": x, "index": 2}); time.sleep(0.8)
    t.ok("moved: to Two", moved.get("space") == "Two", moved)
    st = sv.sp("state")
    t.ok("moved: gone from the space it left", f"{sv.BASE}/x" not in urls(st), urls(st))
    sv.sp("save")
    t.ok("moved: in pins.json under the space it went to, ahead of its row", [h.rsplit("/", 1)[-1] for h in listed(two)] == ["x", "r"], listed(two))
    t.ok("moved: not under the space it left", not any(h.endswith("/x") for h in listed(first)), listed(first))

    # Never opened before quitting: the pin is there after the relaunch.
    sv.quit(); sv.launch()
    go(two); st = sv.sp("state")
    t.ok("relaunch: the moved pin is a pin in the space it went to, ahead of its row", pinned(st) == [f"{sv.BASE}/x", f"{sv.BASE}/r"], pinned(st))
    go(first); st = sv.sp("state")
    t.ok("relaunch: the space it left keeps its other pin, not this one", pinned(st) == [f"{sv.BASE}/keep"], pinned(st))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
