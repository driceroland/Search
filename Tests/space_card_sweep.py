#!/usr/bin/env python3
"""On past the last space to the card for a new one, its tabs stay gone.

Build first (`./build.sh`), then `python3 Tests/space_card_sweep.py`
(needs Pillow). A hidden probe in a world of its own (split_view.py's
harness): four spaces, the last one's tabs in the column, the address in
the column and one button per space under it. Two fingers on past the last
space (Bench "spacestroke", made up as the trackpad sends it) bring the
card for a new space, filmed meanwhile by Bench "layershot".

The card used to be carried in by one SwiftUI animation (SpaceSwipe.carry):
the rows' place was at the end of the way at once, so the last space's
rows, a whole page off there, were put out of the way at once too
(SwipeShift's park), and the animation slid them back across the column to
their parking place as they faded, over the card. Not on every stroke,
about one in three here, so it is tried several times; on each, once the
last space's rows have gone off the column, none of them comes back over
it. The card is now brought a frame at a time, as a space is (SwipeGlide).
"""
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

try:
    from PIL import Image
except ImportError:
    sys.exit("space_card_sweep needs Pillow (python3 -m pip install pillow)")

sv.use("space-card-sweep")
t = sv.T()
IDS = [sv.FIRST_SPACE.upper()] + [f"5E4C0000-0000-4000-8000-0000000000E{i}" for i in range(1, 4)]
OUT = Path(sv.SUPPORT) / "frames"
STROKES = 8


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump([{"id": x, "name": f"S{k}", "colour": k + 1, "sharesSignIns": True} for k, x in enumerate(IDS)],
              open(f"{sv.SUPPORT}/spaces.json", "w"))
    for k in range(len(IDS)):
        f = "session.json" if k == 0 else f"session-{IDS[k]}.json"
        json.dump({"tabs": [{"url": f"{sv.BASE}/s{k}-{i}", "title": f"s{k} {i}"} for i in range(4)], "active": 0},
                  open(f"{sv.SUPPORT}/{f}", "w"))
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "318"])


def rows_back(frames):
    """The frames, after the last space's rows have left the column, with
    some of them over it again: dark text in the band where its rows stand,
    right of where the card's own lines begin, above the card."""
    def ink(image):
        band = image.crop((200, 85, 318, 235)).convert("L")
        return sum(1 for v in band.getdata() if v < 175)
    seen = [ink(Image.open(f["file"])) for f in frames if "file" in f]
    gone = next((i for i, v in enumerate(seen) if i > 2 and v < 5), None)
    return [i for i, v in enumerate(seen) if gone is not None and i > gone and v >= 40]


def on_to_card(n):
    if n > 1:
        # Back from the card to the last space, its rows in the column.
        sv.cmd({"do": "spacestroke", "dx": 15, "steps": 10, "ms": 150, "glide": 0})
        time.sleep(1.5)
    filmed = {}
    film = threading.Thread(target=lambda: filmed.update(
        sv.cmd({"do": "layershot", "path": f"{OUT}/card{n}", "frames": 60, "every": 1 / 60})))
    film.start()
    time.sleep(0.05)
    r = sv.cmd({"do": "spacestroke", "dx": -60, "steps": 20, "ms": 300, "glide": 60})
    film.join()
    t.ok(f"stroke {n}: the card for a new space came", r["making"], (r["space"], r["events"][-3:]))
    back = rows_back(filmed.get("frames", []))
    t.ok(f"stroke {n}: the last space's rows don't come back over the column", not back, back)


try:
    sv.setup(sidebar=True, spaces=True, **{"layout.cards": True, "spaces.buttons": True, "address.shown": True})
    world()
    sv.launch()
    sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
    time.sleep(2)
    OUT.mkdir(exist_ok=True)
    sv.cmd({"do": "layershot", "stage": True, "path": f"{OUT}/staged", "frames": 1})
    time.sleep(1)
    # On to the last space.
    for _ in range(len(IDS) - 1):
        sv.cmd({"do": "spacestroke", "dx": -15, "steps": 10, "ms": 150, "glide": 60})
        time.sleep(1.5)
    for n in range(1, STROKES + 1):
        on_to_card(n)
        time.sleep(1)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
