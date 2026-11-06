#!/usr/bin/env python3
"""Refuse cookie banners (Autoconsent.swift), on local stand-ins for two
consent platforms, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/auto_consent.py`. It runs in
a world of its own (bld-consent-<checkout>) with split_view.py's harness:
started hidden, everything removed afterwards.

Complianz's banner is answered by a click on its own Deny button; Didomi's,
with no button to say no, through Didomi's own setUserDisagreeToAll(), which
the script asks Search to call in the page's world. A banner no rule knows
is left alone, Accept and all. Off, nothing is touched.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-consent")

# Each page says what it was told: window.__choice, in the page's world.
COMPLIANZ = """<!doctype html><title>complianz</title><p>A shop.</p>
<div id="cmplz-cookiebanner-container"><div class="cmplz-cookiebanner" style="position:fixed;bottom:0;left:0;right:0;height:120px;background:#eee">
We use cookies. <button class="cmplz-accept" onclick="answer('accept')">Accept</button>
<button class="cmplz-deny" onclick="answer('deny')">Deny</button></div></div>
<script>function answer(a) { window.__choice = a; document.querySelector('.cmplz-cookiebanner').style.display = 'none'; }</script>"""

DIDOMI = """<!doctype html><title>didomi</title><p>A newspaper.</p>
<div id="didomi-host"><div id="didomi-notice" style="position:fixed;bottom:0;left:0;right:0;height:120px;background:#eee">
We and our partners use cookies. <button id="didomi-notice-agree-button" onclick="answer('accept')">Agree</button></div></div>
<script>
function answer(a) { window.__choice = a; document.getElementById('didomi-notice').remove(); }
window.Didomi = {
  setUserDisagreeToAll: function () { answer('deny'); },
  getCurrentUserStatus: function () { return { purposes: { ads: { enabled: window.__choice !== 'deny' } } }; }
};
</script>"""

UNKNOWN = """<!doctype html><title>unknown</title><p>A blog.</p>
<div class="my-own-banner" style="position:fixed;bottom:0;left:0;right:0;height:120px;background:#eee">
This site uses cookies. <button onclick="window.__choice='accept'">Accept all</button>
<button onclick="window.__choice='deny'">Reject all</button></div>"""

PAGES = {"/complianz": COMPLIANZ, "/didomi": DIDOMI, "/unknown": UNKNOWN}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path)
        if body is None:
            self.send_response(404); self.end_headers(); return
        body = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def start(on):
    sv.setup(**{"consent.refuse": on})
    sv.launch()


def choice(path, within=8.0):
    """What the page was told, once it was told something, or None."""
    id = sv.cmd({"do": "open", "url": BASE + path})["id"]
    sv.cmd({"do": "wait", "id": id})
    got, end = None, time.time() + within
    while time.time() < end and got is None:
        time.sleep(0.4)
        got = sv.ev(id, "window.__choice || null")
    return got


t = sv.T()
try:
    start(True)
    t.ok("Complianz: its Deny button, not Accept", choice("/complianz") == "deny")
    t.ok("Didomi with no button to say no: Didomi's own refusal, in the page's world", choice("/didomi") == "deny")
    t.ok("a banner no rule knows: left alone", choice("/unknown", within=5) is None)
    sv.quit()

    start(False)
    t.ok("off: Complianz untouched", choice("/complianz", within=5) is None)
    t.ok("off: Didomi untouched", choice("/didomi", within=5) is None)
    sv.quit()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
