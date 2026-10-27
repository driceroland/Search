#!/usr/bin/env python3
"""Roomier tabs while a space is swiped in (Varun, 1.0.6).

Build first (`./build.sh`), then `python3 Tests/space_roomy.py` (needs
Pillow). A hidden probe with the tabs in the column, Roomier tabs on and
two spaces of a few pages; the bench films the window's corner while two
fingers bring the second space in (`film swipe`, drawn off screen, the
app staying hidden). The rows of the space coming in, mid-swipe, have to
be as far apart as they are once it has landed: 38 points with Roomier
tabs (36 and the gap), not 30.

Nothing here makes, shows or brings forward a window.
"""
import os
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

try:
    from PIL import Image
except ImportError:
    sys.exit("space_roomy needs Pillow (python3 -m pip install pillow)")

sv.use("bld-va2-roomy")


def pitch(path, left):
    """The distance between text lines, in points, right of `left` (px)."""
    im = Image.open(path).convert("L")
    w, h = im.size
    px = im.load()
    inked = [any(px[x, y] < 150 for x in range(left, w)) for y in range(120, h)]
    starts = [i for i in range(1, len(inked)) if inked[i] and not inked[i - 1]]
    gaps = [b - a for a, b in zip(starts, starts[1:])]
    return statistics.median(gaps) / 2 if len(gaps) >= 3 else None


def main():
    t = sv.T()
    out = tempfile.mkdtemp(prefix="space-roomy-")
    try:
        sv.setup(**{"spaces": True, "sidebar": True, "sidebar.roomy": True, "start.fresh": False})
        sv.launch()
        for n in ("a1", "a2", "a3"): sv.page(n)
        sv.cmd({"do": "space", "action": "new", "name": "Two"}); time.sleep(0.8)
        for n in ("b1", "b2", "b3", "b4", "b5"): sv.page(n)
        sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(1)
        r = sv.cmd({"do": "film", "action": "swipe", "path": f"{out}/f", "frames": 16, "every": 0.03})
        files = [x.get("file") for x in r["frames"]]
        t.ok("filmed", all(files), r["frames"][:2])
        t.ok("landed in the second space", sv.cmd({"do": "space"})["current"] == "Two")
        last = pitch(files[-1], 20)
        t.ok("landed: rows 38 points apart (roomy)", last and abs(last - 38) <= 1, last)
        # The frames with the new space part of the way in, the old one
        # mostly gone off to the left.
        mids = [pitch(f, 0) for f in files[1:5]]
        t.ok("mid-swipe: the space coming in is roomy too", all(m and abs(m - 38) <= 1 for m in mids), mids)
    finally:
        t.done()
        sv.finish()
        for f in os.listdir(out): os.remove(os.path.join(out, f))
        os.rmdir(out)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
