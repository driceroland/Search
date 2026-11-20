#!/usr/bin/env python3
"""A window a page opens for the middle button goes behind (#1243).

Google Drive's folders aren't links: a middle-click on one has the page call
window.open, and that tab came to the front. Build with ./build.sh debug,
then python3 Tests/middle_window.py. Local fixture only, hidden world.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("middle-window")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/drive":
            body = """<div id="folder" style="padding:40px;background:#ddd">Folder</div>
            <div id="plain" style="padding:40px;background:#eee">Open</div>
            <script>
            folder.addEventListener('auxclick', e => { if (e.button === 1) { e.preventDefault(); window.open('/folder'); } });
            folder.addEventListener('mousedown', e => { if (e.button === 1) e.preventDefault(); });
            plain.addEventListener('click', () => window.open('/plain'));
            </script>"""
        else:
            body = "opened " + path
        data = ("<!doctype html><meta charset=utf-8><title>t</title>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def tabs():
    return sv.cmd({"do": "tabs", "window": 1})["tabs"]


def tap(tab, selector, **options):
    sv.cmd({"do": "select", "id": tab, "window": 1})
    time.sleep(0.2)
    sv.cmd({"do": "tap", "id": tab, "selector": selector, "window": 1, **options})
    time.sleep(1)


def active():
    return next(t for t in tabs() if t["active"])


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        page = sv.page("drive")
        tap(page, "#folder", button="middle")
        made = [x for x in tabs() if urlparse(x["url"]).path == "/folder"]
        t.ok("a middle press's window opens one tab", len(made) == 1, tabs())
        t.ok("and the page you were on stays in front", active()["id"] == page, active())
        tap(page, "#plain")
        made = [x for x in tabs() if urlparse(x["url"]).path == "/plain"]
        t.ok("a plain click's window still comes to the front", len(made) == 1 and active()["id"] == made[0]["id"], tabs())
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
