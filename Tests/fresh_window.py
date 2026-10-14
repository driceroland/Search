#!/usr/bin/env python3
"""Settings › General › Start with a fresh window (#406), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fresh_window.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. windows.json's trimming isn't run live, since a failure
there would open a second window.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout: it quits
# and relaunches with settings of its own between runs (see use()).
sv.use("fresh-window")

t = sv.T()
def urls(st): return [x["url"] for x in st["tabs"]]
try:
    sv.setup(splitView=True, spaces=True, **{"tabs.groups": True}); sv.launch()
    m = sv.page("mail"); a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.cmd({"do": "pin", "id": m})
    sv.sp("pair", id=b, **{"with": a}, side="right"); sv.sp("group", id=c)
    first = sv.sp("state")["spaceID"]
    sv.sp("space", spaceAction="new", name="Two"); time.sleep(1)
    n = sv.page("notes"); x = sv.page("x"); sv.cmd({"do": "pin", "id": n})
    two = sv.sp("state")["spaceID"]
    sv.sp("space", spaceAction="go", spaceID=first); time.sleep(0.8)
    sv.sp("save"); pins_before = json.load(open(f"{sv.SUPPORT}/pins.json"))
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "start.fresh", "-bool", "true"])
    sv.launch()
    st = sv.sp("state")
    t.ok("fresh: the pin is back", f"{sv.BASE}/mail" in urls(st) and len(st["pins"]) == 1, urls(st))
    t.ok("fresh: last time's other tabs aren't", not any(u.endswith(("/a", "/b", "/c")) for u in urls(st)), urls(st))
    front = [x for x in st["tabs"] if x["id"] == st["activeID"]]
    t.ok("fresh: an empty tab in front", front and front[0]["blank"], front)
    t.ok("fresh: no group, no pair left", st["groups"] == [] and st["splits"] == [], (st["groups"], st["splits"]))
    pins_after = json.load(open(f"{sv.SUPPORT}/pins.json"))
    t.ok("fresh: the pins file untouched (letters, homes, ids)", pins_after == pins_before)
    sv.sp("space", spaceAction="go", spaceID=two); time.sleep(1); st = sv.sp("state")
    t.ok("fresh: another space keeps its pin, not its tabs", f"{sv.BASE}/notes" in urls(st) and not any(u.endswith("/x") for u in urls(st)), urls(st))
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "start.fresh", "-bool", "false"])
    sv.launch(); sv.page("d"); sv.sp("save"); sv.quit(); sv.launch()
    st = sv.sp("state")
    t.ok("switch off: last time's tabs come back again", f"{sv.BASE}/d" in urls(st), urls(st))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
