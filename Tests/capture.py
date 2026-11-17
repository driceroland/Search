#!/usr/bin/env python3
"""View › Capture…, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/capture.py`. Off by default;
an area, an element and the whole page, the last on a page 5,000 points tall
whose last 200 are red, so a whole-page picture that only drew the screen
shows white at its foot. Nothing goes to the Mac's clipboard or Downloads.
"""
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("capture-tests")
t = sv.T()
out = tempfile.mkdtemp(prefix="search-capture-")


def bottom_pixel(png):
    """The colour near the middle of the picture's last row, read from a BMP
    sips makes (rows stored bottom first, 32-bit BGRA)."""
    bmp = png + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True)
    data = open(bmp, "rb").read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (width * bpp + 3) & ~3
    first = offset if height > 0 else offset + row * (abs(height) - 1)
    x = width // 2
    b, g, r = data[first + x * bpp: first + x * bpp + 3]
    return r, g, b


try:
    sv.setup(); sv.launch()
    tall = sv.page("tall")
    state = sv.cmd({"do": "snap", "id": tall, "mode": "state"})
    t.ok("off by default", state.get("on") is False, state)
    sv.cmd({"do": "ui", "captures": True})
    st = sv.cmd({"do": "snap", "id": tall, "mode": "start"})
    t.ok("start: the bar is on the page", st.get("live") is True, st)
    st = sv.cmd({"do": "snap", "id": tall, "mode": "stop"})
    t.ok("stop: the bar is gone", st.get("live") is False, st)

    area = sv.cmd({"do": "snap", "id": tall, "mode": "area", "x": 10, "y": 10, "w": 200, "h": 100, "path": f"{out}/area.png"})
    scale = (area.get("width") or 0) / 200
    t.ok("area: the size asked, at the screen's scale", scale >= 1 and area.get("height") == round(100 * scale), area)

    box = sv.cmd({"do": "snap", "id": tall, "mode": "element", "x": 100, "y": 100, "path": f"{out}/box.png"})
    t.ok("element: the box, 300×150", box.get("width") == round(300 * scale) and box.get("height") == round(150 * scale), box)
    r, g, b = bottom_pixel(f"{out}/box.png")
    t.ok("element: its colour, no bar or outline over it", g > 120 and r < 60 and b < 60, (r, g, b))

    sv.ev(tall, "window.scrollTo(0, 1500); 1")
    whole = sv.cmd({"do": "snap", "id": tall, "mode": "page", "path": f"{out}/page.png"})
    pts = (whole.get("points") or [0, 0])[1]
    t.ok("page: the whole height, scrolled or not", pts >= 5000 and whole.get("height") == round(pts * scale), whole)
    r, g, b = bottom_pixel(f"{out}/page.png")
    t.ok("page: its foot is drawn (red), not left blank", r > 200 and g < 60 and b < 60, (r, g, b))
finally:
    t.done(); sv.finish()
    os.system(f"rm -rf '{out}'; defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
sys.exit(1 if t.failed else 0)
