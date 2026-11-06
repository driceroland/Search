#!/usr/bin/env python3
"""A page sees the window it is in (#666), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/window_frame.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. A page reads `window.outerHeight` and `screenY` from the
window's frame, as in Safari, and `outerWidth` and `screenX` from its own
width and place: the column beside it is no chrome of Safari's, and counted,
`outerWidth - innerWidth` passed 160, which Discord takes for DevTools open
and signs you out (#916). The last part opens a
public Google Doc as Safari 26.3.1 would: Docs, on a Safari before 26.4, takes
`outerWidth / innerWidth` for the zoom, and drew its canvas at a quarter of
the screen's sharpness when the window read as having no size. It is skipped
when Docs doesn't load.
"""
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("window-frame")

DOC = "https://docs.google.com/document/d/195j9eDD3ccgjQRttHhJPymLJUCOUjs-jmwTrekvdjFE/edit"
SAFARI_26_3 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15"

t = sv.T()
def ev(js): return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")
def frame():
    f = sv.cmd({"do": "windows"})["windows"][0]["frame"]
    x, y, w, h = map(float, re.findall(r"-?[\d.]+", f)) if f else (0, 0, 0, 0)
    return x, y, w, h
# WebKit hands the page whole numbers; the window is on the main screen, whose
# bottom is y 0, so down from the top is the screen's height less its top.
def near(a, b): return abs(a - b) <= 1
RATIOS = "[].slice.call(document.querySelectorAll('canvas')).filter(function (c) { return c.getBoundingClientRect().width > 50 }).map(function (c) { return c.width / c.getBoundingClientRect().width })"
def docs(id, label):
    """A public Google Doc, as Safari 26.3.1 opens it: the canvas at the screen's sharpness."""
    ratios = sv.cmd({"do": "eval", "id": id, "js": RATIOS}).get("value")
    if not ratios:
        print(f"  skip  {label}: Google Docs didn't load"); return
    dpr = sv.cmd({"do": "eval", "id": id, "js": "devicePixelRatio"}).get("value")
    t.ok(f"{label}: the page at the screen's sharpness", all(abs(r - dpr) < 0.01 for r in ratios), (ratios, dpr))
try:
    sv.setup(); sv.launch()
    tab = sv.page("a"); sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 5})

    def reads(label):
        x, y, w, h = frame()
        seen = ev("[outerWidth, outerHeight, screenX, screenY, innerWidth, innerHeight, screen.height]")
        ow, oh, sx, sy, iw, ih, sh = seen
        t.ok(f"{label}: the window's height", near(oh, h), (seen, (x, y, w, h)))
        t.ok(f"{label}: where it is down, from the top of the screen", near(sy, sh - (y + h)), (seen, (x, y, w, h)))
        t.ok(f"{label}: as wide as the page, inside the window", near(ow, iw) and sx >= x - 1 and sx + ow <= x + w + 1, (seen, (x, y, w, h)))
        t.ok(f"{label}: no DevTools to Discord (outer less inner under 160)", ow - iw < 160 and oh - ih < 160, seen)
        return seen

    sv.cmd({"do": "ui", "sidebar": True}); time.sleep(1)
    reads("the column out")
    sv.cmd({"do": "ui", "sidebar": False}); time.sleep(1)
    reads("the strip across the top")
    sv.cmd({"do": "ui", "sidebar": True}); time.sleep(1)

    # Moved and resized, the page reads the new frame.
    sv.cmd({"do": "windows", "action": "frame", "n": 1, "frame": [60, 80, 1000, 700]}); time.sleep(0.5)
    reads("moved and resized")

    # Google Docs, as on Safari 26.3.1 (Docs' own sample document, from its
    # API's quickstart).
    sv.cmd({"do": "agent", "id": tab, "ua": SAFARI_26_3})
    t.ok("as Safari 26.3.1", "Version/26.3.1" in ev("navigator.userAgent"), ev("navigator.userAgent"))
    sv.cmd({"do": "go", "id": tab, "url": DOC}); sv.cmd({"do": "wait", "id": tab, "seconds": 25}); time.sleep(8)
    docs(tab, "Docs as Safari 26.3.1")

    # A tab shown once, then behind another, loading Docs there: it reads
    # this window, and keeps the screen's sharpness when it comes forward.
    other = sv.page("b"); sv.cmd({"do": "select", "id": other}); time.sleep(1.5)
    sv.cmd({"do": "go", "id": tab, "url": DOC}); sv.cmd({"do": "wait", "id": tab, "seconds": 25}); time.sleep(8)
    front = sv.cmd({"do": "eval", "id": other, "js": "outerWidth"}).get("value")
    t.ok("behind: it reads the page in front's width", near(ev("outerWidth"), front), (ev("outerWidth"), front))
    sv.cmd({"do": "select", "id": tab}); time.sleep(3)
    docs(tab, "loaded behind, then brought forward")
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
