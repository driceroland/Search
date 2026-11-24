#!/usr/bin/env python3
"""⌘S moves the column, the page's card and the window's buttons together.

Build first (`./build.sh`), then `python3 Tests/fold_card.py`. A hidden probe
in a world of its own (split_view.py's harness); Bench "foldframes" stages
its window far off every screen and records, at every display frame of two
presses (away, then back), where the page is seen (the web view cut by every
layer above it that clips), the column's edge and the buttons' slide.

Before: the page was given its new size before the column slid away, and
kept it until the column was back, its card's round corners and edge
running 216 points past the window's right edge both ways; folded, a gap
and round corners stayed round the page; and the buttons, on an animation
of their own, ran a frame or two ahead of the column.
"""
import os, sys, time, json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import subprocess

sv.use("fold-card")
# A page of one colour, unlike any ground of the column's, served here.
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
class Red(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>red</title><body style='margin:0;background:#c00'>"
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
red = ThreadingHTTPServer(("127.0.0.1", 0), Red)
threading.Thread(target=red.serve_forever, daemon=True).start()
RED = f"http://127.0.0.1:{red.server_port}/red"
t = sv.T()

try:
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "layout.cards", "-bool", "true"])
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": f"{sv.BASE}/tall", "title": "tall"}, {"url": f"{sv.BASE}/a", "title": "a"}], "active": 0},
              open(f"{sv.SUPPORT}/session.json", "w"))
    sv.launch()
    sv.cmd({"do": "resize", "width": 1200, "height": 760, "steps": 1})
    time.sleep(2)
    sv.cmd({"do": "foldframes", "times": 2})  # staged, warmed up
    a = sv.cmd({"do": "foldframes", "times": 2, "track": True, "span": 0.6, "rest": 0.8})
    t.ok("staged off every screen", a["frame"][0] <= -10000, a["frame"])
    for p in a["presses"]:
        name = "away" if not p["was"] else "back"
        tr = [f for f in p["track"] if "card" in f]
        W, H = tr[0]["window"][2], tr[0]["window"][3]
        over = max(max(f["card"][0] + f["card"][2] - W, f["card"][1] + f["card"][3] - H) for f in tr)
        t.ok(f"{name}: the page never past the window's edge", over <= 0.5, over)
        widths = p["pageWidths"]
        t.ok(f"{name}: the page laid out at most once more", len(widths) <= 2, widths)
        rest = max(f["column"] for f in tr)
        lag = max(abs(f["lights"] - (f["column"] - rest)) for f in tr if not f["lightsHidden"])
        t.ok(f"{name}: the buttons ride the column's frames", lag <= 9, lag)
        folded = tr[-1] if name == "away" else tr[0]
        t.ok(f"{name}: folded, the page is the whole window, square",
             folded["card"] == [0, 0, W, H] and folded["radius"] == 0, folded)
        out = tr[0] if name == "away" else tr[-1]
        t.ok(f"{name}: out, the card has its gap and corners",
             W - out["card"][0] - out["card"][2] == 8 and out["radius"] == 10, out)
    # The column out over the folded page is a floating card: its corners
    # round, the page showing in them, not the column's own ground (its
    # square background covered the rounded one). Light and dark, and
    # with the window's glass on, a picture of the layers each time.
    from PIL import Image

    def corners(tag):
        """The card's corner and the column's ground, in the frames where
        the column is all the way out. Pictured as it comes out: the real
        pointer, wherever it is, sends a peeked column back in."""
        path = f"{os.environ.get('FOLD_CARD_SHOTS', sv.SUPPORT)}/peek-{tag}"
        shot = sv.cmd({"do": "layershot", "path": path, "wide": True, "stage": True,
                       "frames": 16, "every": 1 / 60, "action": "peek"})
        time.sleep(0.4)
        sv.cmd({"do": "ui", "peek": False}); time.sleep(0.6)
        s = shot["scale"]
        found = []
        for f in shot["frames"]:
            if "file" not in f: continue
            im = Image.open(f["file"]).convert("RGB")
            H = im.size[1] / s
            px = lambda x, y: im.getpixel((int(x * s), int(y * s)))
            page = px(1200 - 20, H / 2)
            edge = px(12, H - 40)       # the column's own left edge, above the corner's curve
            ground = px(48, H - 68)
            gap = px(4, H - 40)         # the gap between the window's edge and the card
            # All the way out: the gap is the page's again, the column's edge beyond it.
            if edge != page and ground != page and sum(abs(a - b) for a, b in zip(gap, page)) < 40:
                found.append((px(8.5, H - 8.5), ground, page))
        return found

    def run_corners(glass):
        # A page of its own colour, unlike any ground of the column's.
        if not glass:
            tab = sv.cmd({"do": "open", "url": RED})
            time.sleep(1.5)
            sv.cmd({"do": "select", "id": tab["id"]}); time.sleep(0.8)
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look, "folded": True}); time.sleep(0.8)
            found = corners(f"{look}-{'glass' if glass else 'plain'}")
            near = lambda a, b: sum(abs(x - y) for x, y in zip(a, b)) < 40
            # The corner's pixel is the page's (under the card's shadow), not the column's ground.
            ok = bool(found) and all(near(c, p) and not near(c, g) for c, g, p in found)
            t.ok(f"peek, {look}{', glass' if glass else ''}: the floating card's corner is round", ok, found[:2])
            sv.cmd({"do": "ui", "folded": False}); time.sleep(0.6)

    run_corners(False)
    sv.quit()
    sv.setup(sidebar=True)
    for k in ("layout.cards", "window.glass"):
        subprocess.run(["defaults", "write", sv.SUITE, k, "-bool", "true"])
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"tabs": [{"url": RED, "title": "red"}], "active": 0}, open(f"{sv.SUPPORT}/session.json", "w"))
    sv.launch()
    sv.cmd({"do": "resize", "width": 1200, "height": 760, "steps": 1})
    time.sleep(2)
    sv.cmd({"do": "foldframes", "times": 2})
    run_corners(True)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
