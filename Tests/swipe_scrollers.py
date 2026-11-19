#!/usr/bin/env python3
"""A sideways scroll scrolls what is under it before it means Back (idea 751, #1219, #1184).

Build first (`./build.sh debug`), then `python3 Tests/swipe_scrollers.py`.
Same harness as `Tests/zoom_swipe_back.py`: a probe started hidden, in a
world of its own, driven through the bench, nothing made or shown,
everything removed afterwards.

In Google Sheets a two-finger scroll to the left went back a page instead of
scrolling the grid. Each page here comes after another, so there is a page
to go back to, and gets a swipe back (two fingers to the right) over it:

- a div that scrolls sideways, in its middle: it scrolls, nothing else;
- the same div at its left edge: back, as in Safari;
- the same div a little way in: it reaches its edge during the swipe, and
  that is not a swipe back;
- a grid moved by the page's own wheel handler, which calls preventDefault,
  as Sheets' is: never back;
- that grid on a page busy for 0.3 s with each wheel event, as Sheets can
  be with a large sheet, swiped slowly and flicked: never back. Search
  waited 0.18 s for the page's word, then took silence for a yes; now the
  fingers lifting wait for the page to have answered every event;
- a page with nothing to scroll sideways: back, swiped and flicked.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("swipe-scrollers")

HEAD = "<!doctype html><meta charset=utf-8><style>body{margin:0;font:14px system-ui}</style>"
PAGES = {
    "/start": HEAD + "<title>start</title><p>start",
    "/plain": HEAD + "<title>plain</title><div style='height:3000px'>nothing sideways</div>",
    # A wide strip filling the window, so the pointer in its middle is over it.
    "/strip": HEAD + """<title>strip</title>
<div id=s style="overflow-x:auto;width:100vw;height:100vh"><div style="width:6000px;height:100%;
background:repeating-linear-gradient(90deg,#eee 0 100px,#ccc 100px 200px)"></div></div>
<script>var s=document.getElementById('s'); s.scrollLeft=+(new URLSearchParams(location.search).get('at')||0);</script>""",
    # A grid moved by the page itself: overflow hidden, a wheel handler that
    # takes every event. BUSY: milliseconds it spends on each one.
    "/grid": HEAD + """<title>grid</title>
<div id=g style="overflow:hidden;width:100vw;height:100vh"><div id=c style="width:6000px;height:100%;
background:repeating-linear-gradient(90deg,#eee 0 100px,#ccc 100px 200px)"></div></div>
<script>
var busy=+(new URLSearchParams(location.search).get('busy')||0), x=-2000, c=document.getElementById('c');
c.style.transform='translateX('+x+'px)';
document.getElementById('g').addEventListener('wheel', function (e) {
  e.preventDefault();
  var until = performance.now() + busy; while (performance.now() < until) {}
  x = Math.min(0, x - e.deltaX); c.style.transform='translateX('+x+'px)';
}, { passive: false });
</script>""",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?")[0], PAGES["/start"]).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"

t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


def path(id): return ev(id, "location.pathname")


# A swipe back: two fingers to the right, 300 points. Slow, over 0.6 s; a
# flick, over 0.12 s.
SLOW = {"dx": 300, "dy": 0, "steps": 20, "ms": 600}
FLICK = {"dx": 300, "dy": 0, "steps": 6, "ms": 120}

CASES = [
    # (name, page, swipe, goes back)
    ("a sideways div, in its middle", "/strip?at=3000", SLOW, False),
    ("a sideways div, flicked in its middle", "/strip?at=3000", FLICK, False),
    ("a sideways div, at its left edge", "/strip?at=0", SLOW, True),
    ("a sideways div, reaching its edge mid-swipe", "/strip?at=60", SLOW, False),
    ("a grid the page moves itself", "/grid", SLOW, False),
    ("a grid the page moves itself, flicked", "/grid", FLICK, False),
    ("a busy page's grid", "/grid?busy=300", SLOW, False),
    ("a busy page's grid, flicked", "/grid?busy=300", FLICK, False),
    ("nothing sideways", "/plain", SLOW, True),
    ("nothing sideways, flicked", "/plain", FLICK, True),
]


def run(page, swipe):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/start"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    sv.cmd({"do": "go", "id": tab, "url": f"{BASE}{page}"})
    sv.cmd({"do": "wait", "id": tab, "seconds": 5}); time.sleep(0.8)
    before = path(tab)
    sv.cmd({"do": "wheel", "id": tab, **swipe})
    time.sleep(2.5)
    after = path(tab)
    sv.cmd({"do": "close", "id": tab}); time.sleep(0.3)
    return before, after


def main():
    only = sys.argv[1:]
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "ui", "swipepages": True}); time.sleep(0.3)
        for name, page, swipe, goes in CASES:
            if only and not any(o in name for o in only): continue
            before, after = run(page, swipe)
            went = after == "/start"
            print(f"    {name}: {before} -> {after}")
            t.ok(f"{name}: {'back' if goes else 'stays'}", before == page.split("?")[0] and went == goes, (before, after))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
