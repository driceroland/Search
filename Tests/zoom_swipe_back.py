#!/usr/bin/env python3
"""Pinched in, a swipe back within the page lands where you were (#842).

Build first (`./build.sh`), then `python3 Tests/zoom_swipe_back.py`. Same
harness as `Tests/zoom_swipe.py`: a probe started hidden, in a world of its
own, driven through the bench, nothing made or shown, everything removed
afterwards.

Pinched in, the sides of a page still bounce, so the zoomed view can be
panned on to its left edge. A swipe back from that edge is a pull past it,
and when the back was within the same page — a #footnote, a #section, an
address changed by the page — the page was left about 50 points past its
left edge, with a blank strip down that side, and at the footnote rather
than where you were. Here: the page left at y 3000, the footnote at about
y 8130, pinched in to 2× at its left edge, then a #fn link or a pushState,
then a swipe back, with a glide after it once. Where the page is 5 s later is checked: lined up
(scrollX and visualViewport.pageLeft 0) and back at y 3000. The same at
its own size, and back to another page, as before.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("zoom-swipe-back")

LONG = """<!doctype html><meta charset=utf-8><title>long</title>
<style>body{margin:0;font:14px system-ui} main{width:600px;margin:0 auto} p{margin:0}</style>
<main><p><a id=to href="#fn">note</a></p>
<div style="height:8000px"></div><p id=fn>the footnote</p><div style="height:6000px"></div></main>"""
OTHER = "<!doctype html><meta charset=utf-8><title>other</title><p>other"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (OTHER if self.path.startswith("/other") else LONG).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"

t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")
def where(id): return [x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id][0]["url"]
def spot(id):
    v = ev(id, "JSON.stringify([scrollX, scrollY, visualViewport.pageLeft])")
    import json
    return [round(n) for n in json.loads(v)] if v else None


STEPS = {
    "#fn": "document.getElementById('to').click()",
    "pushState": "history.pushState({}, '', '/long/elsewhere')",
    "another page": None,
}


def run(step, zoom, glide=0):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/long"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5}); time.sleep(0.5)
    if zoom != 1:
        sv.cmd({"do": "magnify", "id": tab, "scale": zoom, "x": 0, "y": 0})
    ev(tab, "scrollTo(0, 3000)"); time.sleep(0.5)
    if STEPS[step]:
        ev(tab, STEPS[step])
    else:
        sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/other"})
        sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    time.sleep(1)
    away = where(tab)
    sv.cmd({"do": "wheel", "id": tab, "dx": 300, "dy": 0, "steps": 10, "ms": 150, "glide": glide})
    time.sleep(5)
    got = spot(tab)
    back = where(tab) == f"{BASE}/long"
    sv.cmd({"do": "close", "id": tab}); time.sleep(0.3)
    return away, back, got


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "ui", "swipepages": True}); time.sleep(0.3)
        for zoom in (2.0, 1):
            for step in STEPS:
                for _ in range(rounds):
                    away, back, got = run(step, zoom)
                    print(f"    {step} -> back, {zoom:g}x: [scrollX, scrollY, pageLeft] = {got}")
                    t.ok(f"{step}, {zoom:g}x: the swipe went back", back, away)
                    t.ok(f"{step}, {zoom:g}x: lined up at its left edge, no blank strip",
                         got is not None and got[0] == 0 and got[2] == 0, got)
                    t.ok(f"{step}, {zoom:g}x: back where you were", got is not None and abs(got[1] - 3000) <= 2, got)
        # Fingers lifted with a glide after, as a trackpad's swipe ends: the
        # glide is the swipe's, never the page's (PageView.went).
        away, back, got = run("#fn", 2.0, glide=12)
        print(f"    #fn -> back with a glide, 2x: [scrollX, scrollY, pageLeft] = {got}")
        t.ok("#fn with a glide, 2x: back, lined up, where you were",
             back and got is not None and got[0] == 0 and got[2] == 0 and abs(got[1] - 3000) <= 2, (away, got))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
