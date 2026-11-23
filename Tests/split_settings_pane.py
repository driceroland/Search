#!/usr/bin/env python3
"""Settings in Split View stays in its own pane (idea 833), in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/split_settings_pane.py`.
Search's own pages (Settings, History…) are drawn by SwiftUI over the stage
(SplitView.swift), placed from the frames the stage tells. Settings is wider
than a narrow pane can hold, and was drawn centred on its pane, past both
edges: over the tabs column and the page beside it.

Checked from pictures of the hidden window, never shown: Settings on the
left of a pair beside a web page, column on the left, and the Liquid Glass tab off and on. The same pair is pictured again with a web page where
Settings was; outside Settings' pane — the column under its rows, and the
other page — the two pictures must be the same.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageChops

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("split-settings-pane")
GUTTER = 7
PICTURES = tempfile.mkdtemp(prefix="split-settings-pane-")


def picture(name):
    path = f"{PICTURES}/{name}.png"
    sv.cmd({"do": "picture", "path": path, "page": False})
    return Image.open(path).convert("RGB")


def differs(one, other, box):
    """How many pixels in box (points, from the top left) are not the same."""
    scale = one.width / WIDTH
    box = tuple(round(v * scale) for v in box)
    diff = ImageChops.difference(one.crop(box), other.crop(box)).convert("L").point(lambda v: 255 if v > 24 else 0)
    return diff.histogram()[255]


def case(t, glass):
    global WIDTH
    kind = "the liquid tab" if glass else "plain"
    sv.setup(splitView=True, **{"tabs.liquid": glass})
    sv.launch()
    a = sv.page("a")
    sv.cmd({"do": "ui", "show": "search://settings"}); time.sleep(1)
    s = next(x["id"] for x in sv.sp("state")["tabs"] if x.get("internal", "").startswith("search://settings"))
    sv.sp("pair", id=s, **{"with": a}, side="left"); time.sleep(1)
    st = sv.sp("state")
    pair = st["splits"][0]
    t.ok(f"{kind}: Settings on the left of a pair", pair["tabs"] == [s, a], pair)
    p = sv.cmd({"do": "probe"})
    WIDTH = next(w for w in p["windows"] if w["kind"] == "AppKitWindow")["frame"][2]
    side = p["sideWidth"]
    for fraction in (0.3, 0.5):
        sv.sp("focus", id=s)
        sv.sp("fraction", split=pair["id"], fraction=fraction); time.sleep(1.5)
        page = next(f for f in sv.sp("state")["paneFrames"] if f["id"] == a)
        shown = picture(f"settings-{glass}-{fraction}")
        sv.sp("focus", id=s); time.sleep(0.3)
        sv.cmd({"do": "ui", "go": f"{sv.BASE}/b"}); time.sleep(2)
        st = sv.sp("state")
        t.ok(f"{kind} {fraction}: the pair holds a web page where Settings was",
             st["splits"] and st["splits"][0]["tabs"] == [s, a] and len(st["paneFrames"]) == 2, st["splits"])
        web = picture(f"web-{glass}-{fraction}")
        height = shown.height * WIDTH / shown.width
        # The column below its rows, and the page beside Settings.
        column = (2, height * 0.45, side - 2, height * 0.9)
        other = (page["x"] + 2, page["y"] + 40, page["x"] + page["width"] - 2, page["y"] + page["height"] - 2)
        settings_room = page["x"] - GUTTER - side
        t.ok(f"{kind} {fraction} (Settings' pane {settings_room:.0f} pt): nothing of Settings over the column",
             differs(shown, web, column) == 0, f"{differs(shown, web, column)} pixels differ, see {PICTURES}")
        t.ok(f"{kind} {fraction}: nothing of Settings over the page beside it",
             differs(shown, web, other) == 0, f"{differs(shown, web, other)} pixels differ, see {PICTURES}")
        sv.sp("focus", id=s); time.sleep(0.3)
        sv.cmd({"do": "ui", "go": "search://settings"}); time.sleep(1.5)


def main():
    t = sv.T()
    for glass in (False, True):
        try:
            case(t, glass)
        except Exception as error:
            t.ok(f"glass={glass} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
