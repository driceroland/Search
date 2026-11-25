#!/usr/bin/env python3
"""An address typed that sends you to another site still finishes from its
own first letters (twitter.com → x.com).

Build first (`./build.sh`), then `python3 Tests/typed_redirect_completes.py`.
The app starts hidden in a world of its own (split_view.use); the address is
put in the field and sent with Return, as typed, and the field's grey ending
is read back for its first letters. Quit and removed afterwards.

Reported (DM): "tw" never became twitter.com, and Return searched for "tw".
twitter.com answers with a redirect to x.com, and only the page that came in
was kept in History, so nothing there started with "tw". Here localhost
sends to 127.0.0.1 the way twitter.com sends to x.com.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("typed-redirect")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        if self.headers.get("Host", "").startswith("localhost"):
            self.send_response(301); self.send_header("Location", f"http://127.0.0.1:{port}/home")
            self.send_header("Content-Length", "0"); self.end_headers()
            return
        data = b"<!doctype html><title>Home / Probe</title>home"
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
PORT = sv.srv.server_port


def field(text, **kw):
    return sv.cmd({"do": "field", "text": text, **kw})


def suggest():
    return sv.cmd({"do": "suggest"})


def escape():
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b", "mods": []}); time.sleep(0.4)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        field(f"localhost:{PORT}", go=True); time.sleep(2.5)
        st = sv.sp("state")
        active = next(x for x in st["tabs"] if x["id"] == st["activeID"])
        t.ok("typing the address lands on the site it sends you to", urlparse(active["url"]).hostname == "127.0.0.1", active["url"])
        field("localh", type=True); time.sleep(0.6)
        s = suggest()
        t.ok("its first letters finish it again", s["ending"].startswith("ost"), s)
        t.ok("…offered as the address typed", any("localhost" in o[0] for o in s["offers"]), s["offers"])
        escape()
        field("127.0", type=True); time.sleep(0.6)
        s = suggest()
        t.ok("the site it went to still finishes too", s["ending"] != "", s)
        escape()
        # A search is not an address: nothing typed is kept for it.
        field("hello there", go=True); time.sleep(1.5)
        field("hel", type=True); time.sleep(0.6)
        s = suggest()
        t.ok("a search typed is not kept as an address", not any("hello" in o[0] and o[1] == "visited" for o in s["offers"]), s["offers"])
    finally:
        sv.finish()
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
