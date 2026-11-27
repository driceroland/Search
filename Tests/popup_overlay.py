#!/usr/bin/env python3
"""Windows and redirects an invisible full-page overlay asks for, in a hidden
probe (idea 1417; the stand-ins are made up, no ad site is visited).

Build first (`./build.sh`), then `python3 Tests/popup_overlay.py`. World of
its own (bld-ovl-<checkout>, see split_view.use). Pages on
http://localhost:PORT are "the site"; 127.0.0.1:PORT is "another site". Clicks
are `tap`'s trusted ones. Nothing here shows a window.

A click on an element that covers the page and shows nothing (opacity 0, or
transparent and empty) is not a click on anything the person saw: the window
it asks for is refused and noted like any pop-up, and a jump of the page to
another site right after it is cancelled. Ordinary buttons, a dimmed
backdrop with a visible dialog, and a visible full-page element still open
what they ask for.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-ovl")
PORT = sv.srv.server_port
SITE = f"http://localhost:{PORT}"
OTHER = f"http://127.0.0.1:{PORT}"
COVER = "position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:2147483647;"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page == "/link":
            # An overlay that is a link to an ad, opacity 0.
            body = f"<button id=real style='font-size:40px'>real</button><a id=ov href='/opened-link' target=_blank style='{COVER}opacity:0'></a>"
        elif page == "/script":
            # An empty transparent div whose click handler opens the ad.
            body = f"<input id=search><div id=ov onclick=\"window.open('/opened-script')\" style='{COVER}background:transparent'></div>"
        elif page == "/redirect":
            # The same, jumping the page to another site.
            body = f"<div id=ov onclick=\"location.href='{OTHER}/jumped'\" style='{COVER}opacity:0'></div>"
        elif page == "/clear":
            # A transparent, empty cover over the page that a click closes; the
            # button under it is clicked through a second page below.
            body = f"<div id=ov onclick=\"this.remove()\" style='{COVER}background:rgba(0,0,0,0)'></div><button id=real onclick=\"window.open('/opened-real')\" style='font-size:40px'>real</button>"
        elif page == "/button":
            body = "<button id=real onclick=\"window.open('/opened-button')\" style='font-size:40px'>open</button>"
        elif page == "/dialog":
            # A dimmed backdrop (visible) with a dialog whose button opens a window.
            body = (f"<div style='{COVER}background:rgba(0,0,0,.5)'></div>"
                    "<button id=real onclick=\"window.open('/opened-dialog')\" style='position:fixed;left:40%;top:40%;z-index:2147483647;font-size:40px'>Sign in</button>")
        elif page == "/backdrop":
            # Clicking the dimmed backdrop itself opens a window: visible, so allowed.
            body = f"<div id=ov onclick=\"window.open('/opened-backdrop')\" style='{COVER}background:rgba(0,0,0,.5)'></div>"
        elif page == "/card":
            # A full-page link with visible content (a banner page): allowed.
            body = f"<a id=ov href='/opened-card' target=_blank style='{COVER}background:#fff;color:#000;font-size:40px'>Read the story</a>"
        elif page == "/part":
            # A transparent link over a small part of the page: a card link, allowed.
            body = "<a id=ov href='/opened-part' target=_blank style='display:block;width:200px;height:100px;opacity:0'></a>"
        else:
            body = f"plain {page}"
        data = ("<!doctype html><meta charset=utf-8><style>body{margin:0}</style>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def opened(name):
    return [t for t in tabs() if urlparse(t["url"]).path == f"/opened-{name}"]


def state(tab):
    return sv.cmd({"do": "popups", "id": tab})


anchor = None


def visit(path):
    req = {"do": "split", "action": "open", "url": f"{SITE}{path}"}
    if anchor:
        req["from"] = anchor
    tab = sv.cmd(req)["resultID"]
    time.sleep(1.5)
    return tab


def tap(tab, selector="#ov"):
    sv.cmd({"do": "tap", "id": tab, "selector": selector})
    time.sleep(1.5)


def main():
    global anchor
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        anchor = visit("/plain")

        page = visit("/link"); tap(page)
        t.ok("overlay link: no window", not opened("link"), opened("link"))
        t.ok("overlay link: noted as a refused pop-up", state(page)["sign"] is True, state(page))

        page = visit("/script"); tap(page)
        t.ok("overlay script: no window", not opened("script"), opened("script"))
        t.ok("overlay script: noted", state(page)["sign"] is True, state(page))

        page = visit("/redirect"); tap(page)
        url = next(x["url"] for x in tabs() if x["id"] == page)
        t.ok("overlay redirect to another site: cancelled", urlparse(url).path != "/jumped", url)

        page = visit("/clear"); tap(page)
        t.ok("a transparent cover that closes itself is untouched", sv.ev(page, "!document.getElementById('ov')") is True)
        tap(page, "#real")
        t.ok("and the button under it opens its window", len(opened("real")) == 1, opened("real"))

        for name, path, sel in [("button", "/button", "#real"), ("dialog", "/dialog", "#real"),
                                ("backdrop", "/backdrop", "#ov"), ("card", "/card", "#ov"), ("part", "/part", "#ov")]:
            page = visit(path); tap(page, sel)
            t.ok(f"{name}: opens what it asks for", len(opened(name)) == 1, opened(name))
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
