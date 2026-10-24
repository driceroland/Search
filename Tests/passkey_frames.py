#!/usr/bin/env python3
"""A passkey asked for from a frame of the page's own site (#679).

Build first (`./build.sh`), then `python3 Tests/passkey_frames.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. A test run never shows the Mac's sheet; it
answers with a made-up credential after the same checks (Passkeys.perform).

Apple's sign-in is a frame from idmsa.apple.com in account.apple.com, the
same site. Search refused any frame whose host wasn't the page's, so Apple
said the browser needed updating. Which hosts are one site is checked in
Tests/RegistrableRegression (nothing on this Mac's loopback has a public
suffix); here, a frame of the page's own host on another port (another
origin, as Apple's frame is) and a frame from another site.
"""
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bug-passkey-frames")

FRAME = """<!doctype html><script>
navigator.credentials.get({ publicKey: { challenge: new Uint8Array(16), rpId: location.hostname, timeout: 5000 } })
  .then(function (c) { parent.postMessage({ from: location.hostname, got: c && c.type }, '*'); },
        function (e) { parent.postMessage({ from: location.hostname, error: e.name + ': ' + e.message }, '*'); });
</script>"""


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/top"):
            frame = self.path.split("=", 1)[1]
            # The frame is served from the other server: another origin.
            body = (f"<!doctype html><title>top</title><script>window.__r = [];"
                    f"addEventListener('message', function (e) {{ window.__r.push(e.data); }});</script>"
                    f"<iframe src='http://{frame}:{P}/frame'></iframe>")
        else:
            body = FRAME
        data = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *a): pass


def answer(tid, within=8):
    end = time.time() + within
    while time.time() < end:
        got = sv.ev(tid, "JSON.stringify(window.__r || [])")
        if got and got != "[]":
            return got
        time.sleep(0.3)
    return sv.ev(tid, "JSON.stringify(window.__r || [])")


srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=srv.serve_forever, daemon=True).start()
P = srv.server_port
top = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=top.serve_forever, daemon=True).start()
P2 = top.server_port
t = sv.T()
try:
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "passkeys", "-bool", "true"])
    sv.launch()
    before = sv.cmd({"do": "probe"}).get("passkeyAsks", 0)
    tid = sv.cmd({"do": "open", "url": f"http://localhost:{P2}/top?f=localhost"})["id"]
    got = answer(tid)
    probe = sv.cmd({"do": "probe"})
    last = probe.get("passkeyLast") or {}
    t.ok("a frame of the page's own site, another origin, gets a passkey", '"got":"public-key"' in (got or ""), got)
    t.ok("…named as asked from a frame, with the page it is in",
         last.get("crossOrigin") is True and last.get("topOrigin") == f"http://localhost:{P2}", last)
    t.ok("…and the request reached the Mac's side", probe.get("passkeyAsks", 0) == before + 1, probe.get("passkeyAsks"))

    tid = sv.cmd({"do": "open", "url": f"http://localhost:{P2}/top?f=other.localhost"})["id"]
    got = answer(tid)
    t.ok("a frame from another site is still refused", "NotAllowedError" in (got or "") and "public-key" not in (got or ""), got)
    t.ok("…before reaching the Mac's side", sv.cmd({"do": "probe"}).get("passkeyAsks", 0) == before + 1)
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
