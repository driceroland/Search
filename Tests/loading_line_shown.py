#!/usr/bin/env python3
"""The loading line along the page's top, with the tabs in sight too
(#1650, idea 1281), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/loading_line_shown.py` from a
worktree. A page that takes a few seconds to arrive is opened with the tabs
down the side in sight, then across the top, then folded away with ⌘S: each
time the line shows while it loads, along the page's top, and goes once the
page is in. Nothing to switch on: it is there for everyone.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("loading-line-shown")


class Slow(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<!doctype html><title>slow</title><p>coming")
        self.wfile.flush()
        time.sleep(3.5)
        self.wfile.write(b"<p>there")

    def log_message(self, *a): pass


slow = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
threading.Thread(target=slow.serve_forever, daemon=True).start()
SLOW = f"http://127.0.0.1:{slow.server_port}"


def lines():
    return sv.cmd({"do": "loadingline"})


def main():
    t = sv.T()
    try:
        for sidebar, folded in ((True, False), (False, False), (True, True)):
            where = "folded" if folded else ("column" if sidebar else "top row")
            sv.setup(sidebar=sidebar); sv.launch()
            if folded:
                sv.cmd({"do": "ui", "folded": True}); time.sleep(0.6)
            page = sv.page("a")
            st = lines()
            t.ok(f"{where}: nothing shown on a page that is in", not any(x["shown"] for x in st["lines"]), st)
            sv.cmd({"do": "go", "id": page, "url": f"{SLOW}/x"})
            time.sleep(1.2)
            st = lines()
            shown = [x for x in st["lines"] if x["shown"]]
            t.ok(f"{where}: the line shows while the page loads", len(shown) == 1, st)
            if shown:
                f = shown[0]["frame"]
                t.ok(f"{where}: along the page's top, part of the way", f[3] <= 3 and f[2] > 100 and 0 <= shown[0]["fraction"] < 1, shown)
            time.sleep(4)
            st = lines()
            t.ok(f"{where}: gone once the page is in", not any(x["shown"] for x in st["lines"]), st)
            sv.quit()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
