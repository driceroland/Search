#!/usr/bin/env python3
"""Closing a page a link just opened in front goes back to the page it came from.

Build first (`./build.sh debug`), then `python3 Tests/close_opened_link.py`.
The app starts hidden in a world of its own (see split_view.use), is driven
with trusted clicks (`tap`) and ⌘W (`press`), and is quit; its world is
removed afterwards.

With Settings › Tabs › Closing a tab goes back to the one before off (the
default), ⌘W on a page that a plain click on a target=_blank link had just
opened landed on whatever tab was last in the row, since that page opens at
the end of it, not on the page the link was clicked in.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("close-opened-link")

STYLE = 'style="display:block;font-size:30px;line-height:60px;padding:0 20px"'


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page.startswith("/links"):
            body = (f'<title>links</title>'
                    f'<a id="b1" target="_blank" href="/front-1" {STYLE}>front 1</a>'
                    f'<button id="w1" onclick="window.open(\'/script-1\')" {STYLE}>script 1</button>')
        else:
            body = f"<title>{page}</title>{page}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def state():
    return sv.sp("state")


def active_path(st=None):
    st = st or state()
    return next(urlparse(x["url"]).path for x in st["tabs"] if x["id"] == st["activeID"])


def click(tab, anchor, wait=1.2):
    if state()["activeID"] != tab:
        sv.sp("select", id=tab); time.sleep(0.4)
    sv.cmd({"do": "tap", "id": tab, "selector": f"#{anchor}"})
    time.sleep(wait)


def cmd_w():
    sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]})
    time.sleep(0.8)


def by_path(path):
    return next(x["id"] for x in state()["tabs"] if urlparse(x["url"]).path == path)


def run(t, goes_back):
    sv.setup(sidebar=True, **{"tabs.closeGoesBack": goes_back})
    sv.launch()
    tag = "goes back on" if goes_back else "default"
    try:
        sv.page("left")
        s = sv.page("links")
        sv.page("right")
        sv.sp("select", id=s); time.sleep(0.4)

        click(s, "b1")
        t.ok(f"{tag}: the clicked link's page is in front", active_path() == "/front-1", active_path())
        cmd_w()
        t.ok(f"{tag}: ⌘W on it goes back to the page the link was clicked in", active_path() == "/links", active_path())

        click(s, "w1", wait=1.6)
        cmd_w()
        t.ok(f"{tag}: the same for a page's window.open on a click", active_path() == "/links", active_path())

        if not goes_back:
            # Gone to another tab since: the opened page is a tab like any
            # other, and closing it lands beside it, as before.
            click(s, "b1")
            opened = by_path("/front-1")
            sv.sp("select", id=by_path("/left")); time.sleep(0.4)
            sv.sp("select", id=opened); time.sleep(0.4)
            cmd_w()
            t.ok("default: after going to another tab, closing it lands beside it as before",
                 active_path() == "/right", active_path())

            # A tab no link opened: unchanged.
            sv.sp("select", id=by_path("/left")); time.sleep(0.4)
            sv.sp("select", id=by_path("/right")); time.sleep(0.4)
            cmd_w()
            t.ok("default: a tab no link opened still lands on its neighbour", active_path() == "/links", active_path())
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        run(t, goes_back=False)
        run(t, goes_back=True)
    finally:
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/close_opened_link.py requires macOS and a built Search.app")
    sys.exit(main())
