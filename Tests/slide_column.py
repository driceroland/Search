#!/usr/bin/env python3
"""Settings › Appearance › Slide the column in and out, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/slide_column.py`. It uses the
split suite's harness: started hidden in a world of its own, no window shown,
moved or resized, everything removed afterwards.

Off by default: ⌘S folds the column on its short springs, as it always did.
On: the column comes out on a 0.26 s ease-out and goes on a 0.22 s ease-in,
the window's buttons riding with it on the same curve. Either way the page
takes its room before the column moves, and keeps its width through the
slide (see fold_flash.py). Under the Mac's Reduce Motion it fades in place
instead, where it did nothing at all; off, Reduce Motion still means at once.
Read through the bench's `foldtime` and `settings`.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("slide-column")
t = sv.T()


def fold(): return sv.cmd({"do": "foldtime"})
def setting(): return sv.cmd({"do": "settings"})["values"].get("sidebar.slides")


def steady(a):
    passes = a["passes"]
    final = passes[-1]["page"]
    moving = [p for p in passes if p["folded"]]
    return all(p["page"] == final for p in moving)


try:
    sv.setup(sidebar=True); sv.launch()
    sv.page("slide")
    t.ok("off by default", setting() is False, setting())
    found = sv.cmd({"do": "settings", "find": "slide column"}).get("found") or []
    t.ok("Find a setting finds it", any(f.get("id") == "sidebar.slides" for f in found), [f.get("id") for f in found])
    a = fold()
    t.ok("off: folded on a spring", a["folded"] and (a["lights"] or {}).get("kind") in ("spring", None), a["lights"])
    time.sleep(0.5); fold(); time.sleep(0.6)

    sv.cmd({"do": "settings", "set": "sidebar.slides", "value": True})
    t.ok("on: kept", setting() is True, setting())
    a = fold()
    lights = a["lights"] or {}
    t.ok("on: hidden, the column folded", a["folded"], a)
    t.ok("on: going in on a 0.22 s ease-in", lights.get("kind") == "eased" and abs(lights.get("duration", 0) - 0.22) < 0.01
         and "easeIn" in lights.get("timing", "") and "Out" not in lights.get("timing", ""), lights)
    t.ok("on: the page keeps its width through the slide", steady(a),
         [(p["at"], p["page"], p["folded"]) for p in a["passes"]][:6])
    time.sleep(0.5)
    b = fold()
    lights = b["lights"] or {}
    t.ok("on: shown, the column out", not b["folded"], b)
    t.ok("on: coming out on a 0.26 s ease-out", lights.get("kind") == "eased" and abs(lights.get("duration", 0) - 0.26) < 0.01
         and "easeOut" in lights.get("timing", ""), lights)
    narrowed = [p for p in b["passes"] if p["page"] < b["pageBefore"]]
    t.ok("on: the page gives up its room only after the slide",
         not narrowed or narrowed[0]["at"] >= 260, [(p["at"], p["page"]) for p in narrowed][:2])

    # Under the Mac's Reduce Motion the switch did nothing at all, which
    # read as a broken switch: the column now fades where it stands.
    time.sleep(0.6)
    a = sv.cmd({"do": "foldtime", "reduceMotion": True})
    lights = a["lights"] or {}
    xs = [p["column"] for p in a["passes"] if isinstance(p.get("column"), (int, float))]
    t.ok("Reduce Motion: hidden", a["folded"], a)
    t.ok("Reduce Motion: the buttons fade, 0.2 s", lights.get("path") == "opacity" and abs(lights.get("duration", 0) - 0.2) < 0.01, lights)
    held = [p["column"] for p in a["passes"] if p.get("held")]
    t.ok("Reduce Motion: the column fades in its place, never slides",
         bool(held) and min(held) == max(held) == xs[0] and set(xs) <= {xs[0], min(xs)}, xs)
    t.ok("Reduce Motion: …and is off the edge once faded", xs[-1] < 0 and not a["passes"][-1]["held"], xs[-3:])
    time.sleep(0.5)
    b = sv.cmd({"do": "foldtime"})
    xs = [p["column"] for p in b["passes"] if isinstance(p.get("column"), (int, float))]
    t.ok("Reduce Motion: shown, faded in where it stands", not b["folded"] and (b["lights"] or {}).get("path") == "opacity"
         and set(xs) <= {xs[0], max(xs)} and xs[-1] > 0, (b["lights"], xs[:6]))
    time.sleep(0.6)
    sv.cmd({"do": "settings", "set": "sidebar.slides", "value": False})
    t.ok("off again", setting() is False)
    a = sv.cmd({"do": "foldtime"})
    t.ok("off, Reduce Motion: at once, as before", a["folded"] and a["lights"] is None, a["lights"])
    time.sleep(0.4); sv.cmd({"do": "foldtime", "reduceMotion": None})
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
