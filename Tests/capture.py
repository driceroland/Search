#!/usr/bin/env python3
"""View › Capture…, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/capture.py`. Off by default;
an area, an element and the whole page, the last on a page 5,000 points tall
whose last 200 are red, so a whole-page picture that only drew the screen
shows white at its foot. Then the layer itself, as a hand works it: a
press on an element and a drag across an area, handed to the page's view,
take their picture; a link pressed is captured, not followed; and the
outline under the pointer shows on a dark page in dark mode. Nothing goes
to the Mac's clipboard or Downloads: a test run's pictures go to a folder
in the temporary one and a pasteboard of the bench's own.
SHOTS_DIR, if given, keeps the dark-mode outline's picture.
"""
import os
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("capture-tests")
t = sv.T()
out = tempfile.mkdtemp(prefix="search-capture-")


def pixel(png, x=None, y=None):
    """The colour at x, y of the picture (pixels from its top left), the
    middle of its last row by default, read from a BMP sips makes (32-bit
    BGRA, rows stored bottom first unless its height is negative)."""
    bmp = png + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True)
    data = open(bmp, "rb").read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (width * bpp + 3) & ~3
    high = abs(height)
    x = width // 2 if x is None else x
    y = high - 1 if y is None else y
    stored = high - 1 - y if height > 0 else y
    at = offset + row * stored + x * bpp
    b, g, r = data[at: at + 3]
    return r, g, b


def bottom_pixel(png):
    return pixel(png)


def taken(within=5):
    """What the layer itself took, once it has."""
    end = time.time() + within
    while time.time() < end:
        st = sv.cmd({"do": "snap", "id": tall, "mode": "state"})
        if st.get("taken"):
            return st
        time.sleep(0.2)
    return st


def press(points):
    """A press, or a drag through points, at the page's own points, handed
    to the page's view as a hand's would be (split mouse … to view)."""
    frame = sv.frames(sv.sp("state"))[tall]
    sv.sp("mouse", points=[[frame["x"] + x, frame["y"] + y] for x, y in points], to="view")


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

    # The layer as a hand works it.
    sv.ev(tall, "window.scrollTo(0, 0); 1")
    sv.cmd({"do": "snap", "id": tall, "mode": "start"})
    press([[100, 100], [100, 100]])
    st = taken()
    got = st.get("taken") or {}
    t.ok("a press on an element: the layer goes down", st.get("live") is False and st.get("snapping") is False, st)
    t.ok("…and takes that element, 300×150", got.get("kind") == "element" and got.get("width") == round(300 * scale)
         and got.get("height") == round(150 * scale), got)
    t.ok("…on the bench's own pasteboard, and in its file", st.get("copied") == [got.get("width"), got.get("height")]
         and os.path.exists(got.get("path") or ""), st)
    if got.get("path"):
        os.remove(got["path"])

    sv.ev(tall, "window.clicks = 0; document.addEventListener('click', function () { window.clicks++ }, true);"
                "var a = document.createElement('a'); a.href = '/elsewhere'; a.textContent = 'a link';"
                "a.style.cssText = 'display:block;position:absolute;left:400px;top:40px;width:200px;height:80px;background:#00f';"
                "document.body.appendChild(a); 1")
    sv.cmd({"do": "snap", "id": tall, "mode": "start"})
    press([[450, 60], [450, 60]])
    st = taken()
    got = st.get("taken") or {}
    time.sleep(0.8)
    t.ok("a link pressed: captured, 200×80", got.get("kind") == "element" and got.get("width") == round(200 * scale), got)
    t.ok("…not followed, and its click never reaches the page",
         sv.ev(tall, "location.pathname") == "/tall" and sv.ev(tall, "window.clicks") == 0,
         (sv.ev(tall, "location.pathname"), sv.ev(tall, "window.clicks")))
    if got.get("path"):
        os.remove(got["path"])

    sv.cmd({"do": "snap", "id": tall, "mode": "start"})
    press([[20, 220], [60, 260], [120, 300], [220, 320]])
    st = taken()
    got = st.get("taken") or {}
    t.ok("a drag: the area dragged, 200×100", got.get("kind") == "area" and got.get("width") == round(200 * scale)
         and got.get("height") == round(100 * scale), got)
    if got.get("path"):
        os.remove(got["path"])
    # The outline under the pointer, on a dark page in dark mode.
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"])
    sv.launch()
    tall = sv.page("tall")
    sv.ev(tall, "document.body.style.background = '#111'; document.getElementById('top').style.background = '#111';"
                "document.getElementById('box').style.background = '#1c1c1c'; 1")
    sv.cmd({"do": "snap", "id": tall, "mode": "start"})
    frame = sv.frames(sv.sp("state"))[tall]
    # A hidden window's view hears no pointer moving over it: the move the
    # layer listens for, sent to the page.
    sv.ev(tall, "window.dispatchEvent(new PointerEvent('pointermove', {clientX: 200, clientY: 110, bubbles: true})); 1")
    time.sleep(0.4)
    keep = sys.argv[1] if len(sys.argv) > 1 else out
    shot = sv.cmd({"do": "shot", "id": tall, "path": f"{keep}/capture-dark-outline.png"})
    s2 = shot["width"] / frame["width"]
    edge = pixel(shot["path"], round(41 * s2), round(110 * s2))
    inside = pixel(shot["path"], round(190 * s2), round(150 * s2))
    t.ok("dark: the outline stands out from the dark page", max(edge) > 150, edge)
    t.ok("dark: the element under it is lit, not left near-black", max(inside) > 0x1c + 12, inside)
    sv.cmd({"do": "snap", "id": tall, "mode": "stop"})
finally:
    t.done(); sv.finish()
    os.system(f"rm -rf '{out}'; defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
sys.exit(1 if t.failed else 0)
