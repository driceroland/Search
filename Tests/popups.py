#!/usr/bin/env python3
"""Popup security regressions in Search's own hidden, checkout-specific world.

Build on macOS (`./build.sh`), then `python3 Tests/popups.py`. Native tap and
linkmenu deliver trusted input. This does not use element.click() as proof
of user activation. The delayed GET models draw.io, and the POST body is
checked at the local server. No accounts, external sites or model APIs.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("popup-tests")
posts = []
menu_requests = []


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page == "/opened-menu":
            menu_requests.append(time.monotonic())
        if page == "/delay":
            time.sleep(2)
            body = "ready"
        elif page == "/load":
            body = "<script>setTimeout(() => window.open('/opened-load'), 300)</script>"
        elif page == "/next":
            body = "<script>window.open('/opened-next')</script>next page"
        elif page == "/navigate":
            body = """<button id="go" onclick="location.href='/next'">Next</button>
            <script>addEventListener('unload', () => window.open('/opened-unload'));</script>"""
        elif page == "/delayed":
            body = """<button id="go" onclick="run()">Authorize</button><script>
            async function run() {
              await fetch('/delay');
              window.open('/opened-delayed');
              window.open('/opened-duplicate');
            }</script>"""
        elif page == "/post":
            body = """<button id="go" onclick="run()">POST sign-in</button>
            <form id="signin" method="post" target="_blank" action="/opened-post">
            <input name="assertion" value="fake-test-only"></form><script>
            async function run() { await fetch('/delay'); document.querySelector('#signin').submit(); }
            </script>"""
        elif page == "/expired":
            body = """<button id="go" onclick="setTimeout(() => window.open('/opened-expired'), 6000)">Late</button>"""
        elif page == "/ads":
            body = f"""<button id="go">Activate parent only</button>
            <iframe src="http://localhost:{sv.srv.server_port}/ad"></iframe>"""
        elif page == "/ad":
            body = "<script>setInterval(() => window.open('/opened-ad'), 100)</script>ad frame"
        elif page == "/menu":
            body = '<a href="/opened-menu" style="display:block;font-size:60px;line-height:120px;padding:0 20px">a link</a>'
        else:
            body = f"opened {page}"
        self.respond(body)

    def do_POST(self):
        posts.append(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
        self.respond("POST received")

    def respond(self, body):
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def opened(name):
    return [tab for tab in sv.cmd({"do": "tabs"})["tabs"]
            if urlparse(tab["url"]).path == f"/opened-{name}"]


def tap(tab):
    sv.cmd({"do": "tap", "id": tab, "selector": "#go"})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        sv.page("load"); time.sleep(1)
        t.ok("load-time open is refused", not opened("load"))

        page = sv.page("navigate"); tap(page); time.sleep(1)
        t.ok("a click followed by next-page load cannot open", not opened("next"))
        t.ok("unload cannot spend the old page's gesture", not opened("unload"))

        page = sv.page("delayed"); tap(page); time.sleep(3)
        t.ok("draw.io-style 2-second delayed open succeeds", len(opened("delayed")) == 1)
        t.ok("the same click cannot open a second popup", not opened("duplicate"))

        page = sv.page("post"); tap(page); time.sleep(3)
        t.ok("async POST opens and preserves the body", len(opened("post")) == 1 and posts == ["assertion=fake-test-only"], posts)

        page = sv.page("expired"); tap(page); time.sleep(7)
        t.ok("an expired 6-second activation is refused", not opened("expired"))

        page = sv.page("ads"); tap(page); time.sleep(3)
        t.ok("repeated cross-origin ad-frame requests are refused", not opened("ad"))

        page = sv.page("menu")
        before = time.monotonic()
        result = sv.cmd({"do": "linkmenu", "id": page, "x": 60, "y": 60,
                         "pick": "Open Link in New Tab", "delay": 6})
        t.ok("native link-menu action after more than 5 seconds opens once",
             len(menu_requests) == 1 and menu_requests[0] - before >= 6
             and len(opened("menu")) == 1, result)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/popups.py requires macOS and a built Search.app")
    sys.exit(main())
