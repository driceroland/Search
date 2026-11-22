#!/usr/bin/env python3
"""A space coming in looks the same before and after it lands (ideas 954, 955).

Build first (`./build.sh`), then `python3 Tests/space_switch_paint.py`
(needs Pillow). A hidden probe in a world of its own (split_view.py's
harness): two spaces, blue and orange, each with a plain group, a red group
and loose tabs, tabs in the column. Bench "layershot" stages the window off
every screen, where its glides run at the display's pace and nobody sees
it, and pictures the column's layers as Core Animation holds them, frame
after frame, without asking a view to draw.

Switched with ⌃N or by two fingers, the space's rows come in drawn from the
map of every space's rows (SideBar.others), and the space itself is taken
only once the hand is still (SpaceSwipe.landSoon): 0.8 s, a pointer moving,
or a click, which with fingers resting on the trackpad could be the first
thing to come. Until 1.0.18 the map drew another space's grouped rows apart
from the column's own: a plain group's rows were not set in under its
heading, and its tabs holding no page were not dimmed; on landing they
jumped in and faded (955). And a swipe left the column in the last space's
colour until it landed (954). Checked, on the frames while the space is on
its way and once it has landed:

- the column wears the coming space's colour from the first frame its rows
  stand in;
- the rows stand exactly where, and as, they are once it has landed.
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
    sys.exit("space_switch_paint needs Pillow (python3 -m pip install pillow)")

sv.use("space-switch-paint")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper(), "5E4C0000-0000-4000-8000-0000000000D2"]
NAMES = ["One", "Two"]
GROUPS = ["6A000000-0000-4000-8000-0000000000%02d" % i for i in range(1, 5)]
OUT = Path(sv.SUPPORT) / "frames"


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": IDS[0], "name": "One", "colour": 1, "sharesSignIns": True},
               {"id": IDS[1], "name": "Two", "colour": 3, "sharesSignIns": True}],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k in range(2):
        tabs = [{"url": f"{sv.BASE}/s{k}g{g}-{i}", "title": f"s{k} g{g} tab {i}", "groupID": GROUPS[2 * k + g]}
                for g in range(2) for i in range(3)]
        tabs += [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} loose {i}"} for i in range(4)]
        groups = [{"id": GROUPS[2 * k], "name": f"Plain {k}", "collapsed": False},
                  {"id": GROUPS[2 * k + 1], "name": f"Red {k}", "collapsed": False, "colour": 4}]
        json.dump({"tabs": tabs, "active": len(tabs) - 1, "groups": groups},
                  open(f"{sv.SUPPORT}/" + ("session.json" if k == 0 else f"session-{IDS[k]}.json"), "w"))


def tint(image):
    """Blue or orange: the column's ground under its last rows."""
    r, g, b = image.getpixel((12, image.size[1] - 60))[:3]
    return "One" if b > r else "Two"


def rows(image, scale):
    """The column's rows from the first heading down to the loose tabs,
    short of the tab in front and the column's edge."""
    return image.crop((0, int(52 * scale), int(200 * scale), int(370 * scale))).convert("L")


def run(name, req, to):
    r = sv.cmd({"do": "layershot", "path": f"{OUT}/{name}", "frames": 40, "every": 1 / 60, **req})
    scale = r["scale"]
    frames = [(f["space"], Image.open(f["file"]).convert("RGB")) for f in r["frames"] if "file" in f]
    landed = [image for space, image in frames if space == to]
    coming = [image for space, image in frames[3:] if space != to]
    t.ok(f"{name}: the space landed while filmed, after a moment on its way", landed and coming,
         [space for space, _ in frames])
    if not landed or not coming:
        return
    # The rows stood still a while before it landed: the last frames on
    # the way, beside the last frame landed.
    after = rows(landed[-1], scale)
    held = coming[-3:]
    t.ok(f"{name}: on its way, the column already wears {to}'s colour",
         all(tint(image) == to for image in held), [tint(image) for image in held])
    boxes = [ImageChops.difference(rows(image, scale), after).point(lambda v: 255 if v > 24 else 0).getbbox()
             for image in held]
    t.ok(f"{name}: its rows stand where and as they do once it has landed (grouped rows set in, put away dimmed)",
         all(box is None for box in boxes), boxes)


try:
    sv.setup(sidebar=True, spaces=True)
    world()
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(2)
    OUT.mkdir(exist_ok=True)
    sv.cmd({"do": "layershot", "stage": True, "path": f"{OUT}/staged", "frames": 1})
    time.sleep(1)
    for name, req, to in [("⌃2", {"action": "space", "index": 2}, "Two"),
                          ("⌃1", {"action": "space", "index": 1}, "One"),
                          ("swipe on", {"action": "swipe", "dx": -200}, "Two"),
                          ("swipe back", {"action": "swipe", "dx": 200}, "One")]:
        run(name, req, to)
        time.sleep(1.2)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
