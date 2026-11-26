#!/usr/bin/env python3
"""A page calling window.close() in a tab you opened yourself (idea 1251).

everyday.app's Sign in with Apple comes back by redirects — a replace to the
provider, its form_post to the site, a redirect to the app — so the tab's
history is one page long at the end, and WebKit lets any page close such a
tab. The app's landing page calls window.close() whether a script opened it
or not, and Search closed the tab before the page had kept the sign-in or
gone on. A tab you opened stays; a tab a page opened still closes itself
(the sign-in pop-up case, #1145). In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/self_close_tab.py`.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("self-close-tab")

PORT = sv.srv.server_port
SITE = f"http://127.0.0.1:{PORT}"
# Another site, as the provider is: the flow swaps processes as the real one did.
PROVIDER = f"http://localhost:{PORT}"


class H(BaseHTTPRequestHandler):
    def send(self, body, status=200, headers=()):
        data = f"<!doctype html><meta charset=utf-8>{body}".encode()
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/login":
            # The site's "Sign in with Apple": location.replace to the provider.
            self.send(f"<title>login</title><script>setTimeout(() => location.replace('{PROVIDER}/authorize'), 300)</script>")
        elif path == "/authorize":
            # The provider's answer, response_mode=form_post: a form that posts itself.
            self.send(f"<title>authorize</title><form id=f method=post action='{SITE}/callback'>"
                      "<input name=code value=probe></form><script>document.getElementById('f').submit()</script>")
        elif path == "/app":
            # everyday's landing page: keep the user, tell an opener if any,
            # close() regardless, and go on to the app.
            self.send("<title>app</title><script>"
                      "const user = new URLSearchParams(location.search).get('user');"
                      "if (user) { localStorage.user = user; if (window.opener) window.opener.postMessage(user, '*'); window.close(); }"
                      "setTimeout(() => location.href = '/home', 300)"
                      "</script>")
        elif path == "/opener":
            self.send("<title>opener</title><button id=open onclick=\"window.open('/app?user=popup')\">open</button>")
        else:
            self.send(f"<title>{path}</title>{path}")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if urlparse(self.path).path == "/callback":
            self.send("", status=302, headers=[("Location", f"{SITE}/app?user=probe")])
        else:
            self.send("", status=404)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def tabs():
    return sv.sp("state")["tabs"]


def paths():
    return [urlparse(x["url"]).path for x in tabs()]


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, **{"tabs.popupWindows": False}); sv.launch()
        sv.sp("open", url=f"{SITE}/start"); time.sleep(0.8)
        before = len(tabs())

        # A tab you opened: the whole sign-in, then close() from its last page.
        sv.sp("open", url=f"{SITE}/login"); time.sleep(4)
        t.ok("a tab you opened stays when its page calls close()", len(tabs()) == before + 1, paths())
        t.ok("and the page goes on where it was going", "/home" in paths(), paths())

        # A tab a page opened: it still closes itself, as a sign-in pop-up does.
        opener = sv.sp("open", url=f"{SITE}/opener")["resultID"]; time.sleep(1)
        count = len(tabs())
        sv.sp("select", id=opener); time.sleep(0.4)
        sv.cmd({"do": "tap", "id": opener, "selector": "#open"}); time.sleep(2.5)
        t.ok("a tab a page opened closes itself", len(tabs()) == count, paths())
    finally:
        sv.finish()
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin" or not Path(sv.APP).exists():
        sys.exit("Tests/self_close_tab.py requires macOS and a built Search.app")
    sys.exit(main())
