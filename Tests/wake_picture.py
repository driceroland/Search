#!/usr/bin/env python3
"""A sleeping tab's picture is the page's size, not twice it (#781), in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/wake_picture.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The picture is taken at the screen's pixels, two to a
point on a Retina screen, and kept as a JPEG; read back without its density
it said it was twice the page in points, and a layout that asked for its own
size drew it at twice the page's size, cropped, while the tab woke.
"""
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("wake-picture")

# A page that answers at once, or, while a tab wakes, a few seconds late, so
# the picture is still up to be measured; never kept, so waking asks again.
held = threading.Event()
held.set()
class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        held.wait(6)
        body = b"<!doctype html><title>picture</title><body style='margin:0;background:#c33'><h1>Saved page</h1>"
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
SLOW = f"http://127.0.0.1:{server.server_port}/page"

t = sv.T()
def size(text): return tuple(float(v) for v in re.findall(r"[\d.]+", text or ""))
# The picture's points come from its pixels and the screen's scale, so a side
# can land a fraction away from the page's whole CSS pixels.
def near(a, b): return len(a) == len(b) == 2 and all(abs(x - y) <= 1 for x, y in zip(a, b))
def case(label, **ui):
    for k, v in ui.items(): sv.cmd({"do": "ui", k: v})
    time.sleep(1)
    a = sv.page("a"); sv.cmd({"do": "go", "id": a, "url": SLOW}); sv.cmd({"do": "select", "id": a})
    sv.cmd({"do": "wait", "id": a, "seconds": 5}); time.sleep(0.5)
    page = size(sv.cmd({"do": "eval", "id": a, "js": "JSON.stringify([innerWidth, innerHeight])"}).get("value"))
    b = sv.page("b"); sv.cmd({"do": "select", "id": b}); time.sleep(1)
    slept = sv.cmd({"do": "sleep", "id": a})
    t.ok(f"{label}: asleep, with a picture kept", slept.get("asleep") is True, slept)
    kept = sv.cmd({"do": "kept", "id": a})
    pixels = size((kept.get("pixels") or "").replace("x", " "))
    if near(pixels, page):
        print(f"  skip  {label}: a screen of one pixel a point, where the picture was always the page's size")
    else:
        t.ok(f"{label}: the picture is the page's size in points", near(size(kept.get("image")), page), (kept, page))
    held.clear()
    sv.cmd({"do": "select", "id": a}); time.sleep(0.8)
    woken = sv.cmd({"do": "kept", "id": a})
    t.ok(f"{label}: the picture shown while waking says it is the page's size", near(size(woken.get("cover")), page), (woken, page))
    held.set(); time.sleep(1.5)
    sv.sp("close", id=a); sv.sp("close", id=b); time.sleep(0.5)
try:
    sv.setup(); sv.launch()
    case("tabs across the top")
    case("sidebar", sidebar=True)
    # The column tucked away, not out over the page as when picking a tab.
    case("a sidebar that hides", sidebar=True, hides=True)
finally:
    held.set(); t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
