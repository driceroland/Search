#!/usr/bin/env python3
"""Pull to any width, and the column's edge held, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/squeeze_column.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
made, shown or brought forward, everything removed afterwards. Checked
through the bench (`settings`, `icons`, `edgetime`): off unless turned on,
the column never narrower than 176 points; on, it keeps a width down to 52,
with titles above 80 and as icons, centred, under it, the lights stacked;
off again, it comes back out to 176; and the edge held past the line
slides the page without laying it out again (with the switch off, see
Tests/column_edge_held.py). How the edge feels under the hand is
on the RC list.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("squeeze-column")

t = sv.T()
def icons(): return sv.cmd({"do": "icons"})
def settings(**f): return sv.cmd({"do": "settings", **f})
def width(w):
    """The column let go at `w`, as its edge is."""
    sv.cmd({"do": "edgetime", "from": w, "to": w, "steps": 1, "held": False}); time.sleep(0.6)
def settle(want, within=4):
    until = time.time() + within
    r = icons()
    while not want(r) and time.time() < until:
        time.sleep(0.15); r = icons()
    return r
def stacked(lights): return len({x for x, _ in lights}) == 1 and len({y for _, y in lights}) == 3
def a_row(lights): return len({y for _, y in lights}) == 1
def held(start, end, steps=24):
    """The edge held from `start` to `end`, a frame at a time: the page's
    own width at every step after the first, and every sample. The first
    step is where the page is laid out once for the hold, and is drawn a
    frame late; the last sample is after it is let go."""
    r = sv.cmd({"do": "edgetime", "from": start, "to": end, "steps": steps, "held": True})
    drawn = r["drawn"]
    return {round(d["maxX"] - d["minX"]) for d in drawn[1:-1]}, drawn

try:
    sv.setup(sidebar=True)
    # A width kept from before, narrower than the switch off allows.
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "60"])
    sv.launch()
    sv.page("a"); sv.page("b"); sv.page("c")
    time.sleep(0.6)

    found = [x["id"] for x in settings(find="any width")["found"]]
    t.ok("settings: found as Pull to any width", "sidebar.squeeze" in found, found)

    # Off, as upstream: never under 176, whatever was kept.
    r = icons()
    t.ok("off: titles, at the least width there was", r["on"] is False and r["columnWidth"] == 176, r)
    t.ok("off: the lights in a row", a_row(r["lights"]), r["lights"])
    # Held with the switch off: Tests/column_edge_held.py.

    # On: narrower than 176, still titles above the line.
    settings(set="sidebar.squeeze", value=True); time.sleep(0.4)
    width(120)
    r = settle(lambda r: r["columnWidth"] == 120)
    t.ok("on: 120 pt is kept", r["columnWidth"] == 120 and r["sideWidth"] == 120, r)
    t.ok("on, 120: still titles", r["on"] is False and r["tiles"] == [], r)
    t.ok("on, 120: the lights a row, inside the column",
         a_row(r["lights"]) and all(x + 14 <= 120 for x, _ in r["lights"]), r["lights"])

    # Under the line: the column of icons at the width pulled to.
    width(60)
    r = settle(lambda r: r["on"] and len(r["tiles"]) == 3)
    t.ok("on, 60: the column of icons", r["on"] is True and r["columnWidth"] == 60, r)
    xs = {round(x["frame"][0]) for x in r["tiles"]}
    t.ok("on, 60: tiles centred in it", xs == {14}, xs)
    r = settle(lambda r: stacked(r["lights"]))
    t.ok("on, 60: the lights stacked", stacked(r["lights"]), r["lights"])

    # Held from wide to past the line: one layout, and icons once let go.
    width(340)
    sizes, drawn = held(340, 56, steps=32)
    t.ok("on, held narrower: the page laid out once, then only slid", len(sizes) == 1, sizes)
    r = settle(lambda r: r["on"] and r["columnWidth"] == 56)
    t.ok("on, let go at 56: icons, at 56", r["on"] is True and r["columnWidth"] == 56, r)
    sizes, drawn = held(56, 160, steps=16)
    t.ok("on, held wider: the page laid out once, then only slid", len(sizes) == 1, sizes)
    r = settle(lambda r: not r["on"] and r["columnWidth"] == 160)
    t.ok("on, pulled back out to 160: titles again", r["on"] is False and r["columnWidth"] == 160, r)
    r = settle(lambda r: a_row(r["lights"]))
    t.ok("on, 160: the lights a row again", a_row(r["lights"]), r["lights"])

    # Kept across a relaunch.
    width(64)
    sv.quit(); sv.launch(); time.sleep(0.6)
    r = settle(lambda r: r["on"] and r["columnWidth"] == 64)
    t.ok("relaunched: still icons at 64", r["on"] is True and r["columnWidth"] == 64, r)

    # Off again: back out to 176, titles.
    settings(set="sidebar.squeeze", value=False); time.sleep(0.6)
    r = settle(lambda r: not r["on"] and r["columnWidth"] == 176)
    t.ok("off again: back to 176, titles", r["on"] is False and r["columnWidth"] == 176 and r["sideWidth"] == 176, r)
    r = settle(lambda r: a_row(r["lights"]))
    t.ok("off again: the lights a row", a_row(r["lights"]), r["lights"])
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
