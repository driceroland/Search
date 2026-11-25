#!/usr/bin/env python3
"""A download never closes a tab that already shows a page.

Build first (`./build.sh`), then `python3 Tests/download_keeps_tab.py`. The
app starts hidden in a world of its own (split_view.use), is driven with
trusted clicks (`tap`), and is quit; its world is removed afterwards.

Reported (DM, flora.ai): downloading a file closed the tab. Search closes a
tab whose first page turned out to be a file, as Safari and Chrome do for a
download link that opens in a new tab. It judged "first page" by the tab's
committed address, which was only recorded for a page that arrived while
its tab was in the space on screen: a page a link opened, still loading as
you went to another space, came in with no address of its own, and its
first download later closed it under you.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("download-keeps-tab")

STYLE = 'style="display:block;font-size:30px;line-height:60px;padding:0 20px"'
LINKS = (f'<a id="dl" download="a.txt" href="/file.txt" {STYLE}>download attr</a>'
         f'<button id="blob" {STYLE} onclick="const a=document.createElement(\'a\');'
         f'a.href=URL.createObjectURL(new Blob([\'hi\']));a.download=\'b.txt\';document.body.append(a);a.click()">blob</button>'
         f'<button id="redir" {STYLE} onclick="location.href=\'/redirect\'">redirect to attachment</button>'
         f'<button id="open" {STYLE} onclick="window.open(\'/attachment\')">window.open attachment</button>'
         f'<a id="slow" target="_blank" href="/slow-app" {STYLE}>slow app in new tab</a>')


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/redirect":
            self.send_response(302); self.send_header("Location", "/attachment"); self.send_header("Content-Length", "0"); self.end_headers()
            return
        if path in ("/attachment", "/file.txt"):
            data = b"file contents"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            if path == "/attachment":
                self.send_header("Content-Disposition", 'attachment; filename="c.bin"')
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        if path == "/slow-app":
            time.sleep(3)
        body = f"<title>{path}</title>{LINKS}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def state():
    return sv.sp("state")


def paths():
    return [urlparse(x["url"]).path for x in state()["tabs"]]


def tap(tab, sel, wait=1.5):
    if state()["activeID"] != tab:
        sv.sp("select", id=tab); time.sleep(0.4)
    sv.cmd({"do": "tap", "id": tab, "selector": f"#{sel}"})
    time.sleep(wait)


def by_path(path):
    return next((x["id"] for x in state()["tabs"] if urlparse(x["url"]).path == path), None)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, spaces=True)
        sv.launch()
        sv.cmd({"do": "space", "action": "new", "name": "Other"}); time.sleep(0.5)
        sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.5)
        sv.page("left")
        s = sv.page("app")
        for sel, name in [("dl", "a download link"), ("blob", "a script's blob download"),
                          ("redir", "a redirect to an attachment")]:
            before = paths()
            tap(s, sel)
            t.ok(f"{name}: the page's tab stays", by_path("/app") == s and len(paths()) == len(before), paths())
        before = len(paths())
        tap(s, "open", wait=2.5)
        t.ok("window.open to an attachment: the tab opened for it closes, the page's stays",
             by_path("/app") == s and len(paths()) == before, paths())

        # A page a link opened, still loading while you are in another space.
        tap(s, "slow", wait=0.6)
        sv.cmd({"do": "space", "action": "go", "index": 2}); time.sleep(4.5)
        sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(1)
        opened = by_path("/slow-app")
        t.ok("the slow page opened by a link is in the row", opened is not None, paths())
        if opened:
            count = len(paths())
            tap(opened, "dl", wait=2)
            t.ok("a download from it leaves its tab open", by_path("/slow-app") == opened and len(paths()) == count, paths())
    finally:
        sv.finish()
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
