#!/usr/bin/env python3
"""A site framed in another gets its cookies only with Prevent cross-site
tracking off, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/cross_site_cookies.py`. It
runs in split_view.py's test world, with its harness: started hidden,
everything removed afterwards.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A Kaltura video in a Brightspace course: a page on 127.0.0.1 holds a frame
# from localhost, another site, which sets its cookie and then looks for it.
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        cookie = []
        if self.path == "/top":
            body = f"""<!doctype html><script>addEventListener('message', e => window.got = e.data)</script>
<iframe src="http://localhost:{port}/set"></iframe>"""
        elif self.path == "/set":
            body, cookie = "<script>location = '/check'</script>", [("Set-Cookie", "session=1; Path=/")]
        else:
            seen = self.headers.get("Cookie") or "none"
            body = f"<script>parent.postMessage('sent:{seen} read:' + (document.cookie || 'none'), '*')</script>"
        self.send_response(200); self.send_header("Content-Type", "text/html")
        for k, v in cookie: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body.encode())
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()

def framed(**prefs):
    """What the frame's server was sent and its script could read."""
    sv.setup(**prefs); sv.launch()
    id = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{srv.server_port}/top"})["id"]
    for _ in range(20):
        time.sleep(0.5)
        got = sv.ev(id, "window.got")
        if got: return got
    return ""

t = sv.T()
try:
    got = framed()
    t.ok("prevention on: the frame gets no cookie", got == "sent:none read:none", got)
    # sites.keep is the switch turned off (Prefs.keepsSignIns).
    got = framed(**{"sites.keep": True})
    t.ok("prevention off: the frame's server gets its cookie back", "sent:session=1" in got, got)
    t.ok("prevention off: the frame's script reads its cookie", "read:session=1" in got, got)
    # The same store, which keeps what the switch did to it: on again, the
    # frame's cookie from before is not sent either.
    got = framed()
    t.ok("prevention on again: the frame gets no cookie", got == "sent:none read:none", got)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
