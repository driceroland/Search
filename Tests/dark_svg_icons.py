#!/usr/bin/env python3
"""An SVG icon with a dark look of its own wears it when Search is dark (#807).

Build first (`./build.sh`), then `python3 Tests/dark_svg_icons.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. Two sites' SVG is black, and white under its
own `prefers-color-scheme: dark` rule, declared the way chatgpt.com does it;
another's is red in both looks, and one more's icon is a blue PNG. Search
starts dark, goes light, then dark again: each SVG is asked for once, and a
tab wears its icon all the way through a switch; the SVG it was drawn from is
kept beside the drawing, and goes with it. First, one more
black-and-white SVG comes 2 s late, and Search goes light and back while it's
on its way. Last, a page that declares no icon, on a site whose pages agree
on a green PNG in the light and not in the dark, wears no other page's when
Search goes dark again.
"""
import hashlib
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from arc_icons import png  # noqa: E402
from sub_path_icons import bluish, greenish, icon, reddish, wait  # noqa: E402

sv.use("dark-svg-icons")
INK = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><style>:root{fill:#000}@media (prefers-color-scheme: dark){:root{fill:#fff}}</style><rect width="32" height="32"/></svg>'
RED = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#f00"/></svg>'
BLUE = png((40, 90, 220), side=32)
GREEN = png((40, 200, 60), side=32)
asked = []

class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        asked.append(self.path)
        kind, body, status = "text/html", b"", 200
        if self.path == "/ink":
            body = b"<!doctype html><title>ink</title><link rel=icon href='/ink.svg' type='image/svg+xml'><link rel=icon href='/ink.svg' type='image/svg+xml' media='(prefers-color-scheme: dark)'><p>ink"
        elif self.path == "/late":
            body = b"<!doctype html><title>late</title><link rel=icon type='image/svg+xml' href='/late.svg'><p>late"
        elif self.path == "/red":
            body = b"<!doctype html><title>red</title><link rel=icon type='image/svg+xml' href='/red.svg'><p>red"
        elif self.path == "/blue":
            body = b"<!doctype html><title>blue</title><link rel=icon href='/blue.png'><p>blue"
        elif self.path == "/mail":
            body = b"<!doctype html><title>mail</title><link rel=icon href='/green.png'><link rel=icon href='/mail-dark.png' media='(prefers-color-scheme: dark)'><p>mail"
        elif self.path == "/chat":
            body = b"<!doctype html><title>chat</title><link rel=icon href='/green.png'><p>chat"
        elif self.path == "/notes":
            body = b"<!doctype html><title>notes</title><p>notes"
        elif self.path == "/ink.svg":
            kind, body = "image/svg+xml", INK
        elif self.path == "/late.svg":
            time.sleep(2); kind, body = "image/svg+xml", INK
        elif self.path == "/red.svg":
            kind, body = "image/svg+xml", RED
        elif self.path in ("/blue.png", "/mail-dark.png"):
            kind, body = "image/png", BLUE
        elif self.path == "/green.png":
            kind, body = "image/png", GREEN
        else:
            status = 404
        self.send_response(status); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

def serve():
    s = ThreadingHTTPServer(("127.0.0.1", 0), Site); threading.Thread(target=s.serve_forever, daemon=True).start(); return s.server_port

def white(c): return len(c) == 6 and min(int(c[i:i + 2], 16) for i in (0, 2, 4)) > 200
def black(c): return len(c) == 6 and max(int(c[i:i + 2], 16) for i in (0, 2, 4)) < 60
def red(c): return reddish(c) and int(c[0:2], 16) > 200 and int(c[2:4], 16) < 60
def worn(tab_id, want):
    seen = [icon(tab_id)]
    while not want(seen[-1]) and len(seen) < 200: time.sleep(0.05); seen.append(icon(tab_id))
    return seen
def ident(url): return hashlib.sha256(url.encode()).hexdigest()[:32]

t = sv.T()
try:
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"])
    sv.launch()
    p1, p2, p3, p4, p5, p6 = serve(), serve(), serve(), serve(), serve(), serve()
    late = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p5}/late"})["id"]
    wait(late, lambda _: "/late.svg" in asked)
    sv.cmd({"do": "ui", "look": "light"})
    time.sleep(4)
    sv.cmd({"do": "ui", "look": "dark"})
    t.ok("dark: an SVG that came in while Search was light is drawn dark: white", white(wait(late, white)), icon(late))
    ink = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p1}/ink"})["id"]
    t.ok("dark: an SVG with a dark look of its own is drawn in it: white", white(wait(ink, white)), icon(ink))
    red_ = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p2}/red"})["id"]
    t.ok("dark: an SVG with one colour keeps it: red", red(wait(red_, red)), icon(red_))
    blue = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p3}/blue"})["id"]
    t.ok("dark: a PNG is worn", bluish(wait(blue, bluish)), icon(blue))
    mail = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p6}/mail"})["id"]
    chat = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p6}/chat"})["id"]
    wait(mail, bluish); wait(chat, greenish)
    notes = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p6}/notes"})["id"]

    sv.cmd({"do": "ui", "look": "light"})
    seen = worn(ink, black)
    t.ok("light: the SVG's tab wears an icon until the light one comes", "" not in seen, sorted(set(seen)))
    t.ok("light: the same SVG is drawn in its light look: black", black(wait(ink, black)), icon(ink))
    t.ok("light: the red one is still red", red(wait(red_, red)), icon(red_))
    ink2 = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{p4}/ink"})["id"]
    t.ok("light: an SVG first seen in the light is black", black(wait(ink2, black)), icon(ink2))
    time.sleep(2)
    t.ok("light: the PNG isn't asked for again", asked.count("/blue.png") == 1, asked.count("/blue.png"))
    guess = wait(notes, greenish)

    sv.cmd({"do": "ui", "look": "dark"})
    t.ok("dark again: that SVG turns white", white(wait(ink2, white)), icon(ink2))
    time.sleep(2)
    t.ok("dark again: a page with no icon whose site's pages now differ shows its letter", greenish(guess) and icon(notes) == "", [guess, icon(notes)])
    t.ok("dark again: each site's SVG was asked for once", [asked.count("/ink.svg"), asked.count("/red.svg")] == [2, 1], [asked.count("/ink.svg"), asked.count("/red.svg")])
    source = Path(f"{sv.SUPPORT}/icons/{ident(f'http://127.0.0.1:{p1}/ink.svg dark')}.svg")
    t.ok("the SVG is kept beside its dark drawing", source.exists(), source)
    address = f"http://127.0.0.1:{p1}/ink"
    sv.cmd({"do": "history", "take": address}); sv.cmd({"do": "history", "forget": address})
    for _ in range(40):
        if not source.exists(): break
        time.sleep(0.25)
    t.ok("forgotten from History, the kept SVG goes with its page", not source.exists(), source)
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
