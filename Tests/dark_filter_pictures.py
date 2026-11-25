#!/usr/bin/env python3
"""Darken pages' filter keeps an SVG's pictures, and stays off Google's editors.

Build first (`./build.sh`), then `python3 Tests/dark_filter_pictures.py [SHOTS_DIR]`.
It uses the split suite's harness: started hidden, in a world of its own,
everything removed afterwards. Search is dark with Darken pages on, kept to
the filter (dusk.mode "filter", as where the colours give up on a page). The
page holds what Google Slides shows: a slide's thumbnail drawn as an SVG with
a picture in it, beside a black SVG icon, a photo and a canvas.

- the thumbnail is turned back whole, as the photo and the canvas are;
- the icon, with no picture in it, turns with the page;
- told the filter isn't wanted (as Search tells docs.google.com), the page is
  left as the site made it, while the colours still darken it.
"""
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("dark-filter-pictures")
SHOTS = sys.argv[1] if len(sys.argv) > 1 else None
RED = ("data:image/svg+xml," "%3Csvg xmlns='http://www.w3.org/2000/svg' width='200' height='120'%3E"
       "%3Crect width='200' height='120' fill='%23e02020'/%3E%3C/svg%3E")
PAGE = f"""<!doctype html><title>slides</title>
<style>body{{background:#fff;color:#222;font:15px -apple-system;margin:16px}} .row{{display:flex;gap:12px;align-items:center}}</style>
<h2>A light editor</h2>
<div class=row>
<svg id=thumb width=200 height=120 viewBox="0 0 200 120"><image href="{RED}" width=200 height=120 /></svg>
<svg id=icon width=24 height=24 viewBox="0 0 24 24"><path d="M2 2h20v20H2z" fill="#000"/></svg>
<img id=photo width=100 height=60 src="{RED}">
<canvas id=c width=100 height=60></canvas>
</div>
<script>var x=document.getElementById('c').getContext('2d');x.fillStyle='#e02020';x.fillRect(0,0,100,60)</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f"http://localhost:{srv.server_port}/slides"
t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js, "world": "search"}).get("value")
def state(id): return ev(id, "window.__officeDusk ? window.__officeDusk.state() : null")
# How many times an element is turned over on screen: its own filter and its
# ancestors', each invert counted.
TURNS = """(function (s) { var n = 0; for (var e = document.querySelector(s); e; e = e.parentElement)
  n += (getComputedStyle(e).filter.match(/invert/g) || []).length; return n; })"""
def turns(id, sel): return ev(id, f"{TURNS}('{sel}')")
def shot(id, name):
    if SHOTS: sv.cmd({"do": "shot", "id": id, "path": f"{SHOTS}/{name}.png", "width": 520})


try:
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"])
    subprocess.run(["defaults", "write", sv.SUITE, "dusk.mode", "-string", "filter"])
    sv.launch()
    if SHOTS: Path(SHOTS).mkdir(parents=True, exist_ok=True)
    sv.cmd({"do": "ui", "dusk": True}); time.sleep(0.8)
    id = sv.cmd({"do": "open", "url": URL})["id"]
    sv.cmd({"do": "wait", "id": id}); time.sleep(3)
    s = state(id) or {}
    t.ok("the page is darkened by the filter", s.get("mode") == "filter", s)
    t.ok("the photo is turned back (twice over: as it was)", turns(id, "#photo") == 2, turns(id, "#photo"))
    t.ok("the canvas is turned back", turns(id, "#c") == 2, turns(id, "#c"))
    t.ok("the SVG thumbnail is turned back whole", turns(id, "#thumb") == 2, turns(id, "#thumb"))
    t.ok("the SVG icon, no picture in it, turns with the page", turns(id, "#icon") == 1, turns(id, "#icon"))
    shot(id, "filter")

    told = "({on: true, host: location.hostname, mode: '%s', filter: false, choice: null, known: false})"
    ev(id, f"window.__officeDusk.update({told % 'filter'}); 1"); time.sleep(0.8)
    s = state(id) or {}
    t.ok("no filter wanted: the page is left as the site made it", s.get("shown") is False and turns(id, "body") == 0, (s, turns(id, "body")))
    shot(id, "no-filter")
    # A page the colours can do: darkened by them, filter or no filter.
    subprocess.run(["defaults", "delete", sv.SUITE, "dusk.mode"])
    time.sleep(0.5)
    two = sv.cmd({"do": "open", "url": URL})["id"]
    sv.cmd({"do": "wait", "id": two}); time.sleep(3)
    ev(two, f"window.__officeDusk.update({told % 'colours'}); 1"); time.sleep(2)
    s = state(two) or {}
    t.ok("…while the colours still darken it", s.get("shown") is True and s.get("mode") == "colours" and turns(two, "body") == 0, s)
    shot(two, "colours")
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
