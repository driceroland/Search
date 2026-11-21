#!/usr/bin/env python3
"""A click, or a key press the page takes, counts for WebKit's tracking
prevention as the user using that site, in a hidden probe (idea 838).

With Prevent cross-site tracking on, WebKit clears what a site keeps once
nobody has used it for a while; "used" is a click on it as the page in
front, or a key press the page takes (a scroll, a key it has no use for, or
a page merely open don't count, as in Safari). This checks that presses
handed through Search's own path reach WebKit as that: after one, the
world's own tracking-prevention database (ResourceLoadStatistics/
observations.db in its store) says the site was used, and before, it doesn't.

Build first (`./build.sh debug`), then `python3 Tests/itp_interaction.py`.
The site is localhost: WebKit keeps no record for a bare address like
127.0.0.1. Nothing here makes, shows or brings forward a window.
"""
import os
import sqlite3
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("itp-interaction")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        # /field: a text field with the focus, which takes what is typed.
        field = "<input autofocus id=f>" if self.path == "/field" else "<p>a page"
        body = f"<!doctype html><title>{self.path.strip('/')}</title>{field}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://localhost:{srv.server_port}"


def used(domain="localhost"):
    """Whether the world's database says the site was used, and when."""
    db = sv.stores()[0] + "/ResourceLoadStatistics/observations.db"
    if not os.path.exists(db):
        return None
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = c.execute("SELECT hadUserInteraction, mostRecentUserInteractionTime FROM ObservedDomains WHERE registrableDomain = ?",
                        (domain,)).fetchone()
    except sqlite3.Error:
        row = None
    c.close()
    return row


def waited(within=8):
    for _ in range(within * 2):
        row = used()
        if row and row[0]: return row
        time.sleep(0.5)
    return used()


def opened(name):
    sv.setup(); sv.launch()
    id = sv.cmd({"do": "split", "action": "open", "url": f"{SITE}/{name}"})["resultID"]
    time.sleep(3)
    return id


t = sv.T()
try:
    # A key press, typed on the page through Search (PageHands). WebKit
    # counts one only when the page takes it, as Safari does: a key a page
    # has no use for is no sign of using the site.
    id = opened("plain")
    row = used()
    t.ok("a page open and untouched is not used", not row or not row[0], row)
    sv.cmd({"do": "key", "id": id, "text": "x"})
    row = waited(within=4)
    t.ok("a key the page doesn't take doesn't count (WebKit's rule)", not row or not row[0], row)
    id = opened("field")
    before = time.time()
    sv.cmd({"do": "key", "id": id, "text": "x"})
    t.ok("the key reached the field", sv.ev(id, "document.getElementById('f').value") == "x")
    row = waited()
    t.ok("a key typed into the page marks the site used", bool(row and row[0]), row)
    t.ok("and when: just now", bool(row and row[1] >= before - 60), row)

    # A click, in a world of its own so the key press above can't count.
    id = opened("plain")
    frame = sv.frames(sv.sp("state")).get(id) or {}
    x = frame.get("x", 0) + frame.get("width", 800) / 2
    y = frame.get("y", 52) + frame.get("height", 600) / 2
    row = used()
    t.ok("a page open and untouched is not used (again)", not row or not row[0], row)
    sv.sp("mouse", points=[[x, y], [x, y]], to="view")
    row = waited()
    t.ok("a click marks the site used", bool(row and row[0]), row)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
