"""A page still loading as the look changes gets its icon, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/loading_look_icons.py`. A
change of look asks every tab for its icon again, a beat later. A page
opened just as the look changed was asked before it had arrived, found
nothing to declare, and was set down as a site with no icon: the ask as it
finished was skipped, and the tab wore its letter until the next change of
look. A page still on its way is now asked once it has arrived, and one
already there is still asked for the other look's icon.
"""
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from arc_icons import png  # noqa: E402
from sub_path_icons import bluish, greenish, icon, reddish, wait  # noqa: E402

sv.use("loading-look-icons")

ICONS = {"/red.png": (220, 40, 40), "/blue.png": (40, 90, 220), "/green.png": (40, 200, 60)}
hits = []


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append(self.path)
        if self.path in ICONS:
            self.reply(png(ICONS[self.path], side=32), "image/png")
        elif self.path == "/slow":
            # Long enough that the look has turned over before it arrives.
            time.sleep(0.5)
            self.reply(b"<!doctype html><title>slow</title><link rel=icon href='/red.png'>", "text/html")
        elif self.path == "/both":
            self.reply(b"<!doctype html><title>both</title>"
                       b"<link rel=icon href='/blue.png' media='(prefers-color-scheme: dark)'>"
                       b"<link rel=icon href='/green.png' media='(prefers-color-scheme: light)'>", "text/html")
        else:
            self.send_response(404)
            self.end_headers()

    def reply(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    t = sv.T()
    try:
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"])
        sv.launch()

        # 1. A page already there wears its dark icon.
        both = sv.cmd({"do": "open", "url": f"{base}/both"})["id"]
        t.ok("a page that declares an icon for each look wears the dark one", bluish(wait(both, bluish)), icon(both))

        # 2. The look changes, and a page is opened before it has turned over.
        sv.cmd({"do": "ui", "look": "light"})
        slow = sv.cmd({"do": "open", "url": f"{base}/slow"})["id"]
        t.ok("a page still loading as the look changed wears its icon once it arrives",
             reddish(wait(slow, reddish)), (icon(slow), hits))
        t.ok("its declared icon was asked for", "/red.png" in hits, hits)
        t.ok("the page already there puts on its light icon", greenish(wait(both, greenish)), icon(both))
    finally:
        t.done()
        sv.finish()
        srv.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
