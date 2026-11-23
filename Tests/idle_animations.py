#!/usr/bin/env python3
"""Nothing animates out of sight: a loading tab's ring turns once (idea 847).

Build first (`./build.sh`), then `python3 Tests/idle_animations.py`. A
hidden probe in a world of its own (split_view.py's harness), the tabs down
the side, opens a page that never finishes loading, and Bench "animating"
lists every Core Animation animation in the window's layers, and whether it
is shown.

The ring of the tab loading turns for as long as the page takes, and the
window is drawn again at every frame while it does. So:

- with a page loading, exactly one ring turns where it is seen;
- once it has loaded, nothing turns for ever.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("idle-animations")
release = threading.Event()


class Serve(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        if self.path == "/slow":
            # Begun at once, finished only when let go: the tab loads till then.
            self.wfile.write(b"<!doctype html><title>Slow</title><p>still coming")
            self.wfile.flush()
            release.wait(60)
            self.wfile.write(b"<p>done")
            return
        self.wfile.write(f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}".encode())

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Serve)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def world():
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{BASE}/one-{i}", "title": f"One {i}"} for i in range(4)]
    json.dump({"tabs": tabs, "active": 0}, open(f"{sv.SUPPORT}/session.json", "w"))


def turning():
    found = sv.cmd({"do": "animating"})
    return found["shownForever"], found["animations"]


def run(t):
    name = "the column"
    release.clear()
    sv.setup(sidebar=True)
    world()
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 1200, "height": 800, "steps": 1})
        time.sleep(1)
        shown, found = turning()
        t.ok(f"{name}: at rest, nothing turns for ever ({shown})", shown == 0, found)
        sv.cmd({"do": "open", "url": f"{BASE}/slow"})
        time.sleep(1.5)
        shown, found = turning()
        t.ok(f"{name}: a page loading, one ring turns where it is seen ({shown})", shown == 1, found)
        release.set()
        time.sleep(1.5)
        shown, found = turning()
        t.ok(f"{name}: loaded, nothing turns for ever ({shown})", shown == 0, found)
    finally:
        release.set()
        sv.quit()


if __name__ == "__main__":
    t = sv.T()
    try:
        run(t)
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)
