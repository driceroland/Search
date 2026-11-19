#!/usr/bin/env python3
"""A PDF zooms in with ⌘+ as far as WebKit's own bar over it goes (idea 749).

On a PDF the page zoom is the PDF's scale, where 1 is the paper's actual
size. ⌘+ stopped at three times that, which on a wide window left the page
not much wider than the window; WebKit's bar and Safari go to six. Pinch
and ⌘+ read back the same scale, ⌘− stops at WebKit's fifth, ⌘0 brings
the paper back to its actual size, and a PDF's zoom is not kept for its
site. A web page still stops at three times.

The bar itself only exists over a page on screen, so it is not pressed
here: what is measured is the paper as drawn, through the bench's picture
of the page, a blue stripe down the middle of it.

Build first (`./build.sh debug`), then `python3 Tests/pdf_zoom.py`. It uses
the split suite's harness: started hidden, no window shown, everything
removed afterwards.
"""
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


def paper():
    """An A4 PDF, two pages, a 30-point blue stripe down the middle of each."""
    content = b"0 0 1 rg 282.5 0 30 842 re f"
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>",
    ]
    out, offsets = b"%PDF-1.4\n", []
    for n, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % n + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return out


PDF = paper()


class Serve(BaseHTTPRequestHandler):
    def do_GET(self):
        pdf = self.path.endswith(".pdf")
        body = PDF if pdf else b"<!doctype html><title>page</title><p>a page"
        self.send_response(200)
        self.send_header("Content-Type", "application/pdf" if pdf else "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Serve)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def pixels(path):
    """An 8-bit RGB or RGBA PNG, not interlaced, as rows of bytes."""
    data = open(path, "rb").read()
    pos, idat = 8, b""
    while pos < len(data):
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + size
    assert depth == 8 and color in (2, 6), (depth, color)
    bpp = 4 if color == 6 else 3
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, bpp, rows


def stripe(id):
    """How wide the blue stripe is drawn, as a share of the page's width."""
    path = f"{sv.SUPPORT}/pdf-zoom.png"
    sv.cmd({"do": "shot", "id": id, "path": path, "width": 600})
    w, bpp, rows = pixels(path)
    # The widest it is across a few rows: zoomed out and back, the window
    # can show the gap between two pages, or the end of the second.
    best = 0
    for row in rows[::max(1, len(rows) // 12)]:
        blue = [x for x in range(w) if row[x * bpp + 2] > 200 and row[x * bpp] < 80 and row[x * bpp + 1] < 80]
        best = max(best, (blue[-1] - blue[0] + 1) / w if blue else 0)
    return best


def mag(id, **f):
    return sv.cmd({"do": "magnify", "id": id, **f})


t = sv.T()
sv.use("bug-pdf-zoom")
try:
    sv.setup()
    sv.launch()
    # A wide window, where the paper at its actual size fills a third or so.
    sv.cmd({"do": "resize", "width": 1900, "height": 1000})
    time.sleep(1)
    doc = sv.sp("open", url=f"{BASE}/paper.pdf")["resultID"]
    sv.sp("select", id=doc)
    time.sleep(3)
    first = mag(doc)
    t.ok("the page is a PDF", first.get("pdf") is True, first)
    start = stripe(doc)
    t.ok("the stripe is drawn", 0 < start < 0.2, start)

    for _ in range(30):
        last = mag(doc, by=1.1)
    t.ok("⌘+ goes on past three times, to six", abs(last["zoom"] - 6) < 0.01, last)
    big = stripe(doc)
    t.ok("and the paper is drawn six times as wide", big > start * 5.4, (start, big))

    # Pinch and ⌘+ are one scale on a PDF.
    pinched = mag(doc, scale=4)
    t.ok("a pinch reads back as the same zoom", abs(pinched["zoom"] - 4) < 0.01 and abs(pinched["magnification"] - 4) < 0.01, pinched)
    after = mag(doc, by=1.1)
    t.ok("⌘+ goes on from where the pinch left it", abs(after["zoom"] - 4.4) < 0.02, after)

    for _ in range(40):
        last = mag(doc, by=1 / 1.1)
    t.ok("⌘− stops at a fifth, WebKit's own floor", abs(last["zoom"] - 0.2) < 0.01, last)

    reset = mag(doc, reset=True)
    t.ok("⌘0 brings the paper back to its actual size", abs(reset["zoom"] - 1) < 0.01 and abs(reset["magnification"] - 1) < 0.01, reset)
    back = stripe(doc)
    t.ok("drawn as it opened", abs(back - start) < 0.01, (start, back))

    mag(doc, zoom=2.5)
    kept = subprocess.run(["defaults", "read", sv.SUITE, "zoom.127.0.0.1"], capture_output=True, text=True)
    t.ok("a PDF's zoom is not kept for its site", kept.returncode != 0, kept.stdout)

    web = sv.sp("open", url=f"{BASE}/page")["resultID"]
    sv.sp("select", id=web)
    time.sleep(1.5)
    for _ in range(20):
        last = mag(web, by=1.1)
    t.ok("a web page still stops at three times", abs(last["zoom"] - 3) < 0.01 and last.get("pdf") is False, last)
finally:
    sv.finish()
    srv.shutdown()
t.done()
sys.exit(1 if t.failed else 0)
