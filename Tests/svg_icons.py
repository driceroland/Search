#!/usr/bin/env python3
"""A site whose only icon is an SVG wears it, not its letter (#680).

Build first (`./build.sh`), then `python3 Tests/svg_icons.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards. The SVG is drawn by WebKit in a process of its own and
kept as a PNG (see SVGIcons in Icons.swift); this checks the PNG lands, is
red where the SVG is red, and that a broken SVG leaves the letter.
"""
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-svg-icons")
RED = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#f00"/></svg>'
EMOJI = "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><rect width='10' height='10' fill='%2300f'/></svg>"

class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        kind, body, status = "text/html", b"", 200
        if self.path == "/svg":
            body = b"<!doctype html><title>svg</title><link rel=icon type='image/svg+xml' href='/i.svg'><p>svg"
        elif self.path == "/data":
            body = f"<!doctype html><title>data</title><link rel=icon href=\"{EMOJI}\"><p>data".encode()
        elif self.path == "/broken":
            body = b"<!doctype html><title>broken</title><link rel=icon href='/bad.svg'><p>broken"
        elif self.path == "/i.svg":
            kind, body = "image/svg+xml", RED
        elif self.path == "/bad.svg":
            kind, body = "image/svg+xml", b"<svg xmlns='http://www.w3.org/2000/svg'><rect" + b" " * 200
        else:
            status = 404
        self.send_response(status); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

def serve():
    s = ThreadingHTTPServer(("127.0.0.1", 0), Site); threading.Thread(target=s.serve_forever, daemon=True).start(); return s.server_port

def icon(host, within=12):
    end = time.time() + within
    while time.time() < end:
        found = sorted(Path(f"{sv.SUPPORT}/icons").glob(f"{host}*.png"))
        if found: return found[0]
        time.sleep(0.3)
    return None

def centre(path):
    """The middle pixel's colour, through sips into a BMP nothing else parses."""
    out = f"{path}.bmp"
    subprocess.run(["sips", "-s", "format", "bmp", str(path), "--out", out], capture_output=True)
    data = Path(out).read_bytes(); Path(out).unlink()
    off = int.from_bytes(data[10:14], "little"); w = int.from_bytes(data[18:22], "little"); h = abs(int.from_bytes(data[22:26], "little", signed=True)); bpp = int.from_bytes(data[28:30], "little") // 8
    row = (w * bpp + 3) // 4 * 4
    i = off + (h // 2) * row + (w // 2) * bpp
    b, g, r = data[i], data[i + 1], data[i + 2]
    return r, g, b

t = sv.T()
try:
    sv.setup(); sv.launch()
    p1, p2, p3 = serve(), serve(), serve()
    # Three sites: an icon each, by host and port.
    sv.sp("open", url=f"http://127.0.0.1:{p1}/svg"); time.sleep(1)
    got = icon(f"127.0.0.1:{p1}")
    t.ok("a site with only an SVG icon gets it", got is not None, got)
    if got:
        r, g, b = centre(got)
        t.ok("…drawn as the SVG is: red", r > 200 and g < 60 and b < 60, (r, g, b))

    sv.sp("open", url=f"http://localhost:{p2}/data"); time.sleep(1)
    got = icon(f"localhost:{p2}")
    t.ok("an SVG icon written into the page as data: too", got is not None, got)
    if got:
        r, g, b = centre(got)
        t.ok("…blue, as it says", b > 200 and r < 60 and g < 60, (r, g, b))

    sv.sp("open", url=f"http://127.0.0.1:{p3}/broken"); time.sleep(1)
    t.ok("a broken SVG keeps the letter: nothing kept", icon(f"127.0.0.1:{p3}", within=6) is None)
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
