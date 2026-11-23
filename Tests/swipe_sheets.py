#!/usr/bin/env python3
"""Sideways swipes over a grid the page moves itself, as Google Sheets' (idea 990).

Build first (`./build.sh debug`), then `python3 Tests/swipe_sheets.py`
(`--sheets` adds a public, signed-out Google Sheet). Same harness as
`Tests/swipe_scrollers.py`: a probe started hidden, in a world of its own,
driven through the bench, nothing made or shown, everything removed after.

The grid is a canvas-like strip moved by a wheel handler that calls
preventDefault, never native overflow. Each case is a swipe back (two
fingers to the right) with its trackpad phases and a glide after:
- the grid scrolled away from its left edge: never back;
- the grid at its left edge, still taking every wheel event: never back;
- the grid at its left edge, letting events through there: back;
- set off with a little up or down in it: as the same swipe without;
- a page with nothing sideways: back;
- the same, on a page whose root says overscroll-behavior-x: none or
  contain, as Sheets' does: never back, as in Chrome.

Hidden, Sheets itself never scrolls (its grid moves in animation frames,
which a hidden page doesn't get) and lets every wheel event through, so
`--sheets` only checks its root's word is heard: a swipe there stays.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("swipe-sheets")

HEAD = "<!doctype html><meta charset=utf-8><style>body{margin:0;font:14px system-ui;overflow:hidden}</style>"
PAGES = {
    "/start": HEAD + "<title>start</title><p>start",
    "/plain": HEAD + "<title>plain</title><p>nothing sideways<script>"
    "document.documentElement.style.overscrollBehaviorX=new URLSearchParams(location.search).get('ob')||''</script>",
    # x: where the grid starts (0 is its left edge). edge=1: at an edge the
    # handler lets the event go instead of taking it. ob: the root's
    # overscroll-behavior-x.
    "/grid": HEAD + """<title>grid</title>
<canvas id=c width=1200 height=800 style="width:100vw;height:100vh;display:block"></canvas>
<script>
var q=new URLSearchParams(location.search), x=+(q.get('x')||0), edge=q.get('edge')==='1', seen=0, taken=0;
var c=document.getElementById('c'), g=c.getContext('2d');
function draw(){g.clearRect(0,0,1200,800);for(var i=0;i<40;i++){g.fillStyle=i%2?'#ccc':'#eee';g.fillRect(i*100-x,0,100,800);}}
draw(); document.documentElement.style.overscrollBehaviorX=q.get('ob')||'';
document.addEventListener('wheel', function (e) {
  seen++;
  var nx = Math.max(0, x + e.deltaX);
  if (edge && nx === x && Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
  e.preventDefault(); taken++;
  x = nx; draw();
}, { passive: false });
window.state=function(){return JSON.stringify({x:x,seen:seen,taken:taken});};
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
SHEET = "https://docs.google.com/spreadsheets/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit"

t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


SLOW = {"dx": 300, "dy": 0, "steps": 20, "ms": 600, "glide": 12}
FLICK = {"dx": 300, "dy": 0, "steps": 6, "ms": 120, "glide": 12}
TILT = {"dx": 300, "dy": 60, "steps": 20, "ms": 600, "glide": 12}
STEEP = {"dx": 300, "dy": 150, "steps": 20, "ms": 600, "glide": 12}
# A little up or down first, then sideways, in one gesture.
LEAD = {"lead": 4, "dx": 300, "dy": 0, "steps": 20, "ms": 600, "glide": 12}

CASES = [
    # (name, page, swipe, goes back)
    ("grid away from its edge", "/grid?x=2000", SLOW, False),
    ("grid away from its edge, flicked", "/grid?x=2000", FLICK, False),
    ("grid away from its edge, tilted", "/grid?x=2000", TILT, False),
    ("grid away from its edge, steep", "/grid?x=2000", STEEP, False),
    ("grid away from its edge, up or down first", "/grid?x=2000", LEAD, False),
    ("grid near its edge, reaching it mid-swipe", "/grid?x=60&edge=1", SLOW, False),
    ("grid at its edge, taking every event", "/grid?x=0", SLOW, False),
    ("grid at its edge, taking every event, flicked", "/grid?x=0", FLICK, False),
    ("grid at its edge, taking every event, tilted", "/grid?x=0", TILT, False),
    ("grid at its edge, taking every event, up or down first", "/grid?x=0", LEAD, False),
    ("grid at its edge, letting it through", "/grid?x=0&edge=1", SLOW, True),
    ("grid at its edge, letting it through, tilted", "/grid?x=0&edge=1", TILT, True),
    ("nothing sideways", "/plain", SLOW, True),
    ("nothing sideways, flicked", "/plain", FLICK, True),
    ("grid at its edge, letting it through, root none", "/grid?x=0&edge=1&ob=none", SLOW, False),
    ("grid at its edge, letting it through, root none, flicked", "/grid?x=0&edge=1&ob=none", FLICK, False),
    ("grid at its edge, letting it through, root none, up or down first", "/grid?x=0&edge=1&ob=none", LEAD, False),
    ("grid at its edge, letting it through, root contain", "/grid?x=0&edge=1&ob=contain", SLOW, False),
    ("nothing sideways, root none", "/plain?ob=none", SLOW, False),
    ("nothing sideways, root auto", "/plain?ob=auto", SLOW, True),
]


def wheel(tab, swipe): return sv.cmd({"do": "wheel", "id": tab, **swipe})


def run(first, page, swipe, settle=0.8):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/start"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    sv.cmd({"do": "go", "id": tab, "url": page})
    sv.cmd({"do": "wait", "id": tab, "seconds": 15}); time.sleep(settle)
    for s in first: wheel(tab, s); time.sleep(0.8)
    before = ev(tab, "location.href")
    wheel(tab, swipe)
    time.sleep(2.5)
    after = ev(tab, "location.href")
    state = ev(tab, "window.state ? state() : ''")
    sv.cmd({"do": "close", "id": tab}); time.sleep(0.3)
    return before, after, state


def main():
    args = sys.argv[1:]
    sheets = "--sheets" in args
    only = [a for a in args if not a.startswith("--")]
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "ui", "swipepages": True}); time.sleep(0.3)
        for name, page, swipe, goes in CASES:
            if only and not any(o in name for o in only): continue
            before, after, state = run([], BASE + page, swipe)
            went = "/start" in (after or "")
            print(f"    {name}: {before.split('/', 3)[-1]} -> {after.split('/', 3)[-1]} {state}")
            t.ok(f"{name}: {'back' if goes else 'stays'}", went == goes, (before, after))
        if sheets:
            for name, swipe in [("Sheets", SLOW), ("Sheets, flicked", FLICK), ("Sheets, up or down first", LEAD)]:
                if only and not any(o in name for o in only): continue
                before, after, _ = run([], SHEET, swipe, settle=4)
                print(f"    {name}: {(before or '')[:50]} -> {(after or '')[:50]}")
                t.ok(f"{name}: stays", "docs.google.com" in (before or "") and after == before, (before, after))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
