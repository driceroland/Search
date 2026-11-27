#!/usr/bin/env python3
"""The space's name shows above its dot at the column's foot (SpaceDot).

Build first (`./build.sh debug`), then `python3 Tests/space_name_foot.py`
(needs Pillow). A hidden probe in a world of its own (split_view.py's
harness): spaces on, the column down the left, one icon per space off.
Switching spaces puts the new space's name above the dot for a moment, with
its shadow. The foot is clipped to hide it as it rises, and that clip took
the name away with it, leaving only the shadow it cast, lying flat across
the doors: the name is now in the room the foot's clip keeps above itself.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

try:
    from PIL import Image
except ImportError:
    sys.exit("space_name_foot needs Pillow (python3 -m pip install pillow)")

sv.use("space-name-foot")
OUT = Path(sv.SUPPORT) / "frames"


def still(name):
    r = sv.cmd({"do": "film", "action": "still", "bottom": True, "path": str(OUT / name),
                "frames": 2, "every": 0.05})
    image = Image.open(r["frames"][-1]["file"]).convert("RGB")
    return image, image.size[0] / 380  # the film is 380 points across


def pill(image, scale):
    """The name's capsule above the dot: its white ground and dark text.
    The dot stands 10 points in from the side and the bottom, 26 square; the
    name sits above it, so the strip looked at is clear of both."""
    h = image.size[1]
    # From the dot's top up, across the column only: right of it is the page.
    return image.crop((int(10 * scale), h - int(105 * scale), int(230 * scale), h - int(40 * scale)))


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, spaces=True, **{"spaces.buttons": False})
        # The name's ground is white, against the page and the dots alike.
        subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "light"])
        sv.launch()
        sv.cmd({"do": "resize", "width": 1100, "height": 820, "steps": 1})
        time.sleep(1.5)
        sv.cmd({"do": "space", "action": "new", "name": "Errands"})
        time.sleep(0.8)
        sv.cmd({"do": "space", "action": "colour", "colour": 4})
        time.sleep(0.4)
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1)
        sv.cmd({"do": "space", "action": "colour", "colour": 2})
        time.sleep(1)
        OUT.mkdir(exist_ok=True)

        sv.cmd({"do": "space", "action": "go", "index": 2})
        # The name comes a moment after the switch and goes 1.4 s later:
        # filmed, the frame it is best seen in is the one looked at.
        r = sv.cmd({"do": "film", "bottom": True, "path": str(OUT / "name-up"),
                    "frames": 24, "every": 0.05})
        frames = [Image.open(f["file"]).convert("RGB") for f in r["frames"]]
        scale = frames[0].size[0] / 380  # the film is 380 points across
        boxes = [pill(im, scale) for im in frames]
        data = [list(box.getdata()) for box in boxes]
        white = [[(i % box.width, i // box.width) for i, p in enumerate(pixels) if min(p) >= 248]
                 for box, pixels in zip(boxes, data)]
        best = max(range(len(white)), key=lambda i: len(white[i]))
        box, data, white = boxes[best], data[best], white[best]
        t.ok("the name's white capsule is above the dot at the foot",
             len(white) > 500 and white
             and (max(x for x, _ in white) - min(x for x, _ in white))
             * (max(y for _, y in white) - min(y for _, y in white)) > 800,
             (len(white), (min(x for x, _ in white), min(y for _, y in white),
                           max(x for x, _ in white), max(y for _, y in white)) if white else None))
        # Its whole height, not a band cut off at the foot's edge: the
        # capsule is about 24 points tall, and its dark words are inside it.
        t.ok("the capsule is whole: its height, and words in it",
             white and max(y for _, y in white) - min(y for _, y in white) >= int(20 * scale)
             and min(min(p) for p in data) <= 90,
             (max(y for _, y in white) - min(y for _, y in white) if white else None,))

        time.sleep(1.6)
        gone, scale = still("name-gone")
        left = [p for p in pill(gone, scale).getdata() if min(p) >= 248]
        t.ok("and it goes again, leaving the dot alone", len(left) < 100, len(left))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
