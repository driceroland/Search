#!/usr/bin/env python3
"""A page closing itself in a small window (idea 1145): window.close() from
the page of a small window — one a small window's page opened, sized or not,
or one a link opened — takes the window away, as it does a pop-up window's
or a tab's, and its opener sees it closed. Also after a navigation, as an
OAuth flow ends. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/little_window_close.py`.
Started hidden in a world of its own; the small windows are the probe's,
made without being shown; everything is removed afterwards.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("little-close")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/opener":
            body = ("<button id=sized onclick=\"popup=window.open('/child','_blank','width=420,height=360')\">sized</button>"
                    "<button id=flow onclick=\"popup=window.open('/start','_blank','width=420,height=360')\">flow</button>"
                    "<button id=plain onclick=\"popup=window.open('/child')\">plain</button>")
        elif path == "/child":
            body = "<h1>child</h1><button id=close onclick='window.close()'>close</button>"
        elif path == "/start":
            # A sign-in: a page, then the provider's answer, which closes the window.
            body = "<h1>sign in</h1><script>setTimeout(() => location.href = '/done', 400)</script>"
        elif path == "/done":
            body = "<h1>done</h1><script>setTimeout(() => window.close(), 400)</script>"
        else:
            body = "<h1>alone</h1><button id=close onclick='window.close()'>close</button>"
        data = f"<!doctype html><meta charset=utf-8><title>{path}</title>{body}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def littles():
    return [urlparse(u).path for u in sv.cmd({"do": "little", "what": "state"})["littles"]]


def ev(js):
    return sv.cmd({"do": "eval", "js": js, "little": True}).get("value")


def tap(selector, wait=1.2):
    sv.cmd({"do": "tap", "selector": selector, "little": True}); time.sleep(wait)


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.popupWindows": False}); sv.launch()
        tabs_before = len(sv.cmd({"do": "tabs"})["tabs"])
        sv.cmd({"do": "little", "what": f"{sv.BASE}/opener"}); time.sleep(1.5)
        t.ok("a small window holds the opener", littles() == ["/opener"], littles())

        # A sized window.open from a small window's page: a small window.
        tap("#sized")
        t.ok("its sized pop-up is a small window", littles() == ["/opener", "/child"], littles())
        tap("#close")
        t.ok("window.close() takes the small window away", littles() == ["/opener"], littles())
        t.ok("its opener sees it closed", ev("popup.closed") is True, ev("popup.closed"))

        # Unsized, the same.
        tap("#plain")
        t.ok("an unsized one is a small window too", littles() == ["/opener", "/child"], littles())
        tap("#close")
        t.ok("unsized: closed too", littles() == ["/opener"], littles())

        # A sign-in flow: another page first, then close() from it.
        tap("#flow", wait=0.3)
        t.ok("the flow's small window opened", len(littles()) == 2, littles())
        time.sleep(2.5)
        t.ok("closed after a navigation, as OAuth ends", littles() == ["/opener"], littles())
        t.ok("flow: its opener sees it closed", ev("popup.closed") is True, ev("popup.closed"))
        t.ok("no tab left behind in the row", len(sv.cmd({"do": "tabs"})["tabs"]) == tabs_before)

        # A small window a link opened, its one page closing itself.
        sv.cmd({"do": "little", "what": f"{sv.BASE}/alone"}); time.sleep(1.5)
        t.ok("a link's small window", littles() == ["/opener", "/alone"], littles())
        tap("#close")
        t.ok("a link's small window closes itself", littles() == ["/opener"], littles())
        t.ok("no tab left behind in the row either", len(sv.cmd({"do": "tabs"})["tabs"]) == tabs_before)
        sv.cmd({"do": "little", "what": "close"}); time.sleep(0.5)
        t.ok("all closed", littles() == [], littles())
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
