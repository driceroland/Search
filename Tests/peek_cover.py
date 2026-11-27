#!/usr/bin/env python3
"""The page under a peek is covered as ⌘T's and ⌘L's field covers it.

Build first (`./build.sh`), then `python3 Tests/peek_cover.py`. A hidden
probe in a world of its own (split_view.py's harness).

Before: the peek dimmed the page with black at 22%, where the field lays
the window's ground over it at 74%: two looks for the same thing, a page
still there but out of the way, and the peek's barely there in dark. Both
now have Palette.cover.

The cover is read from a picture of the window's layers beside the panel,
then beside ⌘L's field over the same page, light and dark. The tabs are
across the top, so the page starts at the window's left edge.
"""
import os, sys, time, json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from PIL import Image

sv.use("peek-cover")
t = sv.T()

try:
    sv.setup(sidebar=False)
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"{sv.BASE}/tall", "title": "tall"}], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))
    sv.launch()
    sv.cmd({"do": "resize", "width": 1200, "height": 760, "steps": 1}); time.sleep(0.8)
    shots = os.environ.get("PEEK_COVER_SHOTS", sv.SUPPORT)

    def cover(tag):
        shot = sv.cmd({"do": "layershot", "path": f"{shots}/{tag}", "wide": True, "frames": 1})
        im = Image.open(shot["frames"][0]["file"]).convert("RGB")
        # 12 points in, halfway down: under the cover, clear of the panel
        # and its shadow, and of the field and its list.
        return im.getpixel((int(12 * shot["scale"]), im.size[1] // 2))

    seen = {}
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"}); time.sleep(1.2)
    for look in ("light", "dark"):
        sv.cmd({"do": "ui", "look": look}); time.sleep(0.6)
        seen[("peek", look)] = cover(f"peek-{look}")
    sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.6)
    sv.cmd({"do": "field", "text": "a"}); time.sleep(0.8)
    for look in ("light", "dark"):
        sv.cmd({"do": "ui", "look": look}); time.sleep(0.6)
        seen[("field", look)] = cover(f"field-{look}")
    for look in ("light", "dark"):
        a, b = seen[("peek", look)], seen[("field", look)]
        t.ok(f"{look}: the page under a peek is covered as under the field",
             sum(abs(x - y) for x, y in zip(a, b)) <= 6, {"peek": a, "field": b})
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
