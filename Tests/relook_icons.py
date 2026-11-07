#!/usr/bin/env python3
"""A tab wears an icon all the way through a dark-to-light switch.

Build first (`./build.sh`), then `python3 Tests/relook_icons.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. Two pages of one site each declare a red
icon, and a blue one for `prefers-color-scheme: dark`; the second page's red
one comes 2 s late. Search starts dark, so each page is kept with its blue
icon only, then goes light: each tab keeps its blue icon until its own red
one comes, and the second keeps it when the first page's red one lands.
Then the site's home page is seen in the light, with a green icon, and a
third page in the dark only: going light again, that page's tab wears the
home page's green icon before its own blue one, until its own red one comes.
"""
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

sv.use("relook-icons")
RED = png((220, 40, 40), side=32)
BLUE = png((40, 90, 220), side=32)
GREEN = png((40, 180, 40), side=32)  # as much red as blue: neither reddish nor bluish

class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        kind, body, status = "text/html", b"", 200
        if self.path == "/inbox":
            body = b"<!doctype html><title>inbox</title><link rel=icon href='/red.png'><link rel=icon href='/blue.png' media='(prefers-color-scheme: dark)'><p>inbox"
        elif self.path == "/sent":
            body = b"<!doctype html><title>sent</title><link rel=icon href='/late-red.png'><link rel=icon href='/blue.png' media='(prefers-color-scheme: dark)'><p>sent"
        elif self.path == "/drafts":
            body = b"<!doctype html><title>drafts</title><link rel=icon href='/drafts-red.png'><link rel=icon href='/blue.png' media='(prefers-color-scheme: dark)'><p>drafts"
        elif self.path == "/":
            body = b"<!doctype html><title>home</title><link rel=icon href='/green.png'><p>home"
        elif self.path == "/red.png":
            kind, body = "image/png", RED
        elif self.path == "/late-red.png":
            time.sleep(2); kind, body = "image/png", RED
        elif self.path == "/drafts-red.png":
            time.sleep(2); kind, body = "image/png", RED
        elif self.path == "/green.png":
            kind, body = "image/png", GREEN
        elif self.path == "/blue.png":
            kind, body = "image/png", BLUE
        else:
            status = 404
        self.send_response(status); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

def worn(tab_id, want):
    seen = [icon(tab_id)]
    while not want(seen[-1]) and len(seen) < 200: time.sleep(0.05); seen.append(icon(tab_id))
    return seen

srv = ThreadingHTTPServer(("127.0.0.1", 0), Site); threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_port}"
t = sv.T()
try:
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"])
    sv.launch()
    inbox = sv.cmd({"do": "open", "url": f"{base}/inbox"})["id"]
    sent = sv.cmd({"do": "open", "url": f"{base}/sent"})["id"]
    t.ok("dark: each page wears its dark icon: blue", bluish(wait(inbox, bluish)) and bluish(wait(sent, bluish)), [icon(inbox), icon(sent)])

    sv.cmd({"do": "ui", "look": "light"})
    seen = worn(sent, reddish)
    t.ok("light: the late page's tab wears an icon until its light one comes", "" not in seen, sorted(set(seen)))
    t.ok("light: the late page's tab ends on its light icon: red", reddish(seen[-1]), seen[-1])
    t.ok("light: the other page's tab wears its light icon: red", reddish(wait(inbox, reddish)), icon(inbox))

    home = sv.cmd({"do": "open", "url": f"{base}/"})["id"]
    t.ok("light: the home page wears its icon: green", greenish(wait(home, greenish)), icon(home))
    sv.cmd({"do": "ui", "look": "dark"})
    wait(inbox, bluish)
    drafts = sv.cmd({"do": "open", "url": f"{base}/drafts"})["id"]
    t.ok("dark: the third page wears its dark icon: blue", bluish(wait(drafts, bluish)), icon(drafts))
    sv.cmd({"do": "ui", "look": "light"})
    seen = worn(drafts, reddish)
    t.ok("light: the third page's tab wears the home page's icon until its own light one comes: green, then red", any(greenish(c) for c in seen) and reddish(seen[-1]), sorted(set(seen)))
finally:
    sv.finish()
    srv.shutdown()
t.done()
sys.exit(1 if t.failed else 0)
