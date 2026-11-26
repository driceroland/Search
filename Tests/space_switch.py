#!/usr/bin/env python3
"""Switching spaces: the rows land where they slid in, and quick strokes count.

Build first (`./build.sh`), then `python3 Tests/space_switch.py` (needs
Pillow). It uses the split suite's harness: started hidden in a world of its
own, no window shown or brought forward, everything removed afterwards.

A space's rows slide in drawn ahead, scrolled to its tab in front, and the
space is taken only once they stand still (SpaceSwipe.bring). So, whether
⌃1–⌃9 or two fingers bring it:

- the column is scrolled where it ends up from the first moment it scrolls,
  never at the top first or still where the last space was;
- after a swipe the rows are exactly where they were drawn coming in, with
  pinned rows above them too;
- as the fingers set off, the rows they move are drawn where they stood,
  scrolled as the column was, wheeled away from its tab in front or not;
- strokes the same way, quickly one after another, each bring a space,
  and a quick stroke back brings back the space just left;
- the card for a new space takes a longer stroke than a space, and quick
  strokes back from it go on past the last space;
- a short quick flick brings one too, where the same short stroke made
  slowly snaps back.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit("space_switch needs Pillow (python3 -m pip install pillow)")

sv.use("space-switch")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper()] + [f"5E4C0000-0000-4000-8000-0000000000C{i}" for i in range(1, 4)]


def world(rows):
    """Spaces of the given (tabs, tab in front), in the session files."""
    os.makedirs(sv.SUPPORT, exist_ok=True)
    names = ["One", "Two", "Three", "Four"][:len(rows)]
    json.dump([{"id": x, "name": n, "colour": 0, "sharesSignIns": True} for x, n in zip(IDS, names)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k, (n, front) in enumerate(rows):
        f = "session.json" if k == 0 else f"session-{IDS[k]}.json"
        tabs = [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} {i}"} for i in range(n)]
        json.dump({"tabs": tabs, "active": front}, open(f"{sv.SUPPORT}/{f}", "w"))


def start(rows, **prefs):
    sv.setup(sidebar=True, spaces=True, **prefs)
    world(rows)
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(1.5)


def landed(r):
    """The column's scroll from the pass that took the space on, as it is
    shown: before, the map's rows stand in for it."""
    # The pass the space was taken in: by its name where the bench says
    # it; by the rows made otherwise (only those in sight are made since
    # perf-many-tabs, fewer than 50 for a long space).
    took = next((p["at"] for p in r["passes"] if p.get("space") == r["space"]), None) if any("space" in p for p in r["passes"]) \
        else next((p["at"] for p in r["passes"] if p["rows"] >= 50), None)
    return [p["offset"] for p in r["passes"]
            if took is not None and "offset" in p and p["at"] >= took and p.get("shown", True)]


def steady(values):
    return bool(values) and max(values) - min(values) < 2


try:
    # Two long spaces, each with its tab in front far down.
    start([(200, 190), (200, 150)])
    for index, name in [(2, "Two"), (1, "One"), (2, "Two")]:
        r = sv.cmd({"do": "spacetime", "index": index, "glide": True})
        time.sleep(0.5)
        o = landed(r)
        t.ok(f"⌃{index} to {name}: the column is where it ends up from the first frame it scrolls",
             r["space"] == name and steady(o) and o[0] > 1000, (r["space"], o[:3], o[-1:]))
    # On Two now: back to One and over to Two again.
    for dx, name in [(200, "One"), (-200, "Two")]:
        r = sv.cmd({"do": "swipetime", "dx": dx})
        time.sleep(0.5)
        o = landed(r)
        t.ok(f"swipe to {name}: landed where the rows were drawn coming in, and stays",
             r["landed"] and steady(o) and r["preview"] is not None and abs(o[0] - r["preview"]) < 2,
             (r["space"], r["preview"], o[:3]))
    sv.quit()

    # Pinned rows above the tabs: nothing moves once a swipe has landed.
    start([(85, 82), (28, 10)], **{"pins.list": True})
    for k in (1, 2):
        if k == 2:
            sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(1)
        for tab in sv.sp("state")["tabs"][:4 if k == 1 else 10]:
            sv.cmd({"do": "pin", "id": tab["id"], "listed": True})
    sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(1.2)
    out = Path(sv.SUPPORT) / "frames"
    out.mkdir(exist_ok=True)
    width = sv.cmd({"do": "probe"})["columnWidth"]
    scale = 2  # pixels to a point, of the screen the window is on

    def shot(name):
        global scale
        r = sv.cmd({"do": "film", "action": "still", "path": f"{out}/{name}", "frames": 2, "every": 0.05})
        image = Image.open(r["frames"][-1]["file"]).convert("L")
        # The film is the window's corner, 380 points across.
        scale = image.size[0] / 380
        return image.crop((0, int(40 * scale), image.size[0], image.size[1]))

    for wheel, how in [(0, "as it came"), (-240, "wheeled up")]:
        if wheel:
            sv.cmd({"do": "columnscroll", "wheel": wheel}); time.sleep(0.6)
        rest = shot(f"rest-{wheel}")
        # Eight points along: a frame of the slide, the rows moved by it.
        sv.cmd({"do": "space", "action": "hold", "dx": -8}); time.sleep(0.4)
        held = shot(f"setoff-{wheel}")
        sv.cmd({"do": "space", "action": "release"}); time.sleep(1)
        # Eight points, in the screen's pixels, up to short of the
        # column's edge, which stands still.
        k, edge = round(8 * scale), round((width - 10) * scale)
        a = rest.crop((k, 0, edge, rest.size[1]))
        b = held.crop((0, 0, edge - k, held.size[1]))
        box = ImageChops.difference(a, b).point(lambda v: 255 if v > 24 else 0).getbbox()
        t.ok(f"pinned rows, scrolled {how}: the rows set off from where they stood", box is None, box)
    for dx, name in [(-width, "Two"), (width, "One")]:
        # Fingers held a whole column across: the space coming in is drawn
        # exactly where it will be, and stands still there.
        sv.cmd({"do": "space", "action": "hold", "dx": dx}); time.sleep(0.4)
        held = shot(f"held-{name}")
        sv.cmd({"do": "space", "action": "release"}); time.sleep(1)
        landed = shot(f"landed-{name}")
        t.ok(f"pinned rows, swipe to {name}: the rows land exactly where they were drawn coming in",
             sv.cmd({"do": "space"})["current"] == name and ImageChops.difference(held, landed).point(lambda v: 255 if v > 24 else 0).getbbox() is None,
             ImageChops.difference(held, landed).point(lambda v: 255 if v > 24 else 0).getbbox())
    sv.quit()

    # Quick strokes the same way, each 0.15 s after the last.
    start([(30, 15)] * 4)
    for _ in range(3):
        sv.cmd({"do": "space", "action": "swipe", "dx": -120})
        time.sleep(0.15)
    time.sleep(1)
    t.ok("three quick strokes the same way bring three spaces", sv.cmd({"do": "space"})["current"] == "Four",
         sv.cmd({"do": "space"})["current"])
    # A quick stroke back, 0.3 s after one: the space just left comes back.
    sv.cmd({"do": "space", "action": "swipe", "dx": 120})
    time.sleep(0.3)
    sv.cmd({"do": "space", "action": "swipe", "dx": -120})
    time.sleep(1.5)
    t.ok("a quick stroke back brings back the space just left", sv.cmd({"do": "space"})["current"] == "Four",
         sv.cmd({"do": "space"})["current"])
    # On the last space: the card for a new one takes a longer stroke.
    r = sv.cmd({"do": "swipetime", "dx": -70, "steps": 3, "every": 1 / 120}); time.sleep(0.5)
    t.ok("70 points toward the card, even quickly: it snaps back", not sv.cmd({"do": "space"})["making"],
         sv.cmd({"do": "space"})["making"])
    sv.cmd({"do": "space", "action": "swipe", "dx": -150}); time.sleep(1)
    t.ok("150 points: the card for a new space", sv.cmd({"do": "space"})["making"], sv.cmd({"do": "space"})["making"])
    # Two quick strokes back from it: two places back, not the last space again.
    sv.cmd({"do": "space", "action": "swipe", "dx": 120})
    time.sleep(0.3)
    sv.cmd({"do": "space", "action": "swipe", "dx": 120})
    time.sleep(1.5)
    now = sv.cmd({"do": "space"})
    t.ok("two quick strokes back from the card bring the space before the last", now["current"] == "Three" and not now["making"],
         (now["current"], now["making"]))
    # Back to Three, then 30 points: slowly, and as a flick.
    sv.cmd({"do": "space", "action": "go", "index": 3}); time.sleep(1)
    r = sv.cmd({"do": "swipetime", "dx": 30, "steps": 12, "every": 1 / 60}); time.sleep(0.5)
    t.ok("30 points slowly: not far enough, it snaps back", not r["landed"] and r["space"] == "Three", (r["landed"], r["space"]))
    r = sv.cmd({"do": "swipetime", "dx": 30, "steps": 3, "every": 1 / 120}); time.sleep(0.5)
    t.ok("30 points as a flick: the space before comes", r["landed"] and r["space"] == "Two", (r["landed"], r["space"]))
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
