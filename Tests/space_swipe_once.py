#!/usr/bin/env python3
"""One stroke between spaces, one slide (idea 834), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/space_swipe_once.py`.
A two-finger stroke over the column is made up as the trackpad sends it —
may-begin, began, moves, ended, then its glide (momentum) — and read by the
swipe as the real events are (Bench "spacestroke"). With the trackpad set to
swipe between pages, the same stroke can be told again as a swipe between
pages; that swipe is sent too, at times a real one comes. Each case: how
many slides set off, how many spaces on it ends, and the rows' place every
1/120 s — out to the next space once, never back and out again.
Nothing is shown on screen.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("space-swipe-once")
IDS = [sv.FIRST_SPACE.upper()] + [f"5E4C0000-0000-4000-8000-0000000000D{i}" for i in range(1, 5)]


def world(count):
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": x, "name": f"S{k}", "colour": 0, "sharesSignIns": True} for k, x in enumerate(IDS[:count])],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k in range(count):
        f = "session.json" if k == 0 else f"session-{IDS[k]}.json"
        json.dump({"tabs": [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} {i}"} for i in range(4)], "active": 0},
                  open(f"{sv.SUPPORT}/{f}", "w"))


def outs(samples, width):
    """How many times the rows set off a page's way: from near their place to
    past half a page off it."""
    count, away = 0, False
    for s in samples:
        off = abs(s[1])
        if not away and off > width / 2:
            count, away = count + 1, True
        elif away and off < width / 4:
            away = False
    return count


def stroke(t, name, **f):
    r = sv.cmd({"do": "spacestroke", **f})
    width = r["width"]
    spaces = [s[2] for s in r["samples"]]
    start = spaces[0] if spaces else -1
    t.ok(f"{name}: one space on, no card for a new one", r["space"] == start + 1 and not r["making"],
         (start, r["space"], r["making"], r["events"][-3:]))
    t.ok(f"{name}: one slide", r["slides"] == 1, r["slides"])
    t.ok(f"{name}: the rows go out once", outs(r["samples"], width) == 1, outs(r["samples"], width))
    time.sleep(1)
    return r


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, spaces=True)
        world(5)
        sv.launch()
        time.sleep(1.5)
        # From the first space of five: each case one on, none at the last.
        stroke(t, "told again as a swipe between pages as its glide ends",
               dx=-15, steps=10, ms=150, glide=75, swipeAfter=0.05)
        stroke(t, "told again as a swipe between pages as the fingers lift",
               dx=-15, steps=10, ms=150, glide=0, swipeAfter=0.05)
        stroke(t, "a stroke and its glide", dx=-15, steps=10, ms=150, glide=60)
        stroke(t, "a quick flick and a long glide", dx=-10, steps=4, ms=50, glide=150, glideEvery=1 / 120)
        # On the last space now: back one first, for a mouse's swipe on.
        r = sv.cmd({"do": "spacestroke", "dx": 15, "steps": 10, "ms": 150, "glide": 0}); time.sleep(1.5)
        r = sv.cmd({"do": "spacestroke", "dx": 0.0001, "steps": 2, "ms": 2, "glide": 0, "swipeAfter": 1.0})
        t.ok("a mouse's swipe on its own (Logitech's back and forward) still brings a space",
             r["slides"] == 1, (r["slides"], r["events"][-2:]))
    except Exception as error:
        t.ok("ran to the end", False, error)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
