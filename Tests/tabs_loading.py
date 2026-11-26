#!/usr/bin/env python3
"""Pages out of sight load a few at a time (LoadTurns), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/tabs_loading.py`. Twelve
tabs are opened behind the one on screen, each on a page of its own server
that takes about two seconds to come, and left out of every window as a tab
you aren't looking at is. With three turns (`load.turns`):

- never more than three of them load at once, and the rest wait;
- a tab picked while it waits starts at once, not after the rest;
- every one of them has loaded in the end;
- all reloaded at once, the same again.

Nothing is shown on screen.
"""
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tabs-loading")
COUNT, TURNS = 12, 3


class Slow(BaseHTTPRequestHandler):
    """A page that comes in four parts half a second apart, its title last."""
    protocol_version = "HTTP/1.0"

    def log_message(self, *a): pass

    def do_GET(self):
        n = self.path.rsplit("/", 1)[-1]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(b"<!doctype html><title>coming</title><p>")
            self.wfile.flush()
            for _ in range(4):
                time.sleep(0.5)
                self.wfile.write(b"text " * 100)
                self.wfile.flush()
            self.wfile.write(f"<script>document.title='Page {n}'</script>".encode())
        except BrokenPipeError:
            pass


# A server for each page: on one, WebKit's few connections to a host would
# make them wait their turn anyway.
PORTS = []
for _ in range(COUNT):
    server = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    PORTS.append(server.server_port)


def watch(seconds, until=None):
    """The turns every tenth of a second for `seconds`, or until `until` holds."""
    seen, end = [], time.time() + seconds
    while time.time() < end:
        now = sv.cmd({"do": "turns"})
        seen.append(now)
        if until and until(now):
            break
        time.sleep(0.1)
    return seen


def settled(now):
    return now["waiting"] == 0 and now["webLoading"] == 0


def titles():
    return sorted(x["title"] for x in sv.sp("state")["tabs"] if x["title"].startswith("Page "))


def main():
    t = sv.T()
    sv.setup(sidebar=True)
    subprocess.run(["defaults", "write", sv.SUITE, "load.turns", "-int", str(TURNS)])
    sv.launch()
    time.sleep(1.5)
    try:
        ids = [sv.cmd({"do": "open", "url": f"http://127.0.0.1:{port}/page/{n}", "room": False})["id"]
               for n, port in enumerate(PORTS)]
        seen = watch(1.5)
        most = max(s["webLoading"] for s in seen)
        t.ok(f"opened out of sight: never more than {TURNS} load at once", 0 < most <= TURNS, most)
        t.ok("the rest wait their turn", max(s["waiting"] for s in seen) >= COUNT - TURNS - 1,
             [s["waiting"] for s in seen[:5]])

        # The last one opened is still waiting: picked, it starts now.
        before = sv.cmd({"do": "turns"})
        sv.cmd({"do": "select", "id": ids[-1]})
        after = watch(1, until=lambda s: s["webLoading"] > TURNS)
        t.ok("a tab picked while it waits starts at once", before["waiting"] > 0 and after[-1]["webLoading"] == TURNS + 1,
             (before, after[-1]))

        done = watch(30, until=settled)
        t.ok("every page has loaded in the end", settled(done[-1]) and len(titles()) == COUNT, (done[-1], titles()))

        # All at once again, as a reload of many tabs.
        sv.cmd({"do": "reload"})
        seen = watch(1.5)
        # The one on screen loads besides, out of turn.
        most = max(s["webLoading"] for s in seen)
        t.ok(f"reloaded at once: never more than {TURNS} out of sight load together", 0 < most <= TURNS + 1, most)
        done = watch(30, until=settled)
        t.ok("and every one of them comes back", settled(done[-1]) and len(titles()) == COUNT, (done[-1], titles()))
    except Exception as error:
        t.ok("ran to the end", False, error)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
