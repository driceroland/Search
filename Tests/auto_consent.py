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

The rules come from this server, not jsDelivr (`test.consentRules` in the
test settings): a few of the real ones (Tests/AutoconsentFixtures). Fetched
once, kept, and read again at the next start without another fetch; what
isn't rules is thrown away; off, nothing is fetched.
"""
import os
import subprocess
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
RULES = (Path(__file__).resolve().parent / "AutoconsentFixtures" / "rules.json").read_text()
FILES = {"/rules.json": (RULES, "application/json"), "/broken.json": ("<html>Not here</html>", "text/html")}
asked = []  # the rules files fetched, in order


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        kind = "text/html"
        if self.path in FILES:
            asked.append(self.path)
            body, kind = FILES[self.path]
        else:
            body = PAGES.get(self.path)
        if body is None:
            self.send_response(404); self.end_headers(); return
        body = body.encode()
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def kept(): return os.path.join(sv.SUPPORT, "Cookie banner rules.json")


def start(on, rules="/rules.json", fresh=True):
    if fresh:
        sv.setup(**{"consent.refuse": on})
        subprocess.run(["defaults", "write", sv.SUITE, "test.consentRules", "-string", BASE + rules], check=True)
    sv.launch()


def settle(within=10.0):
    """Until the rules are kept, or for a while."""
    end = time.time() + within
    while time.time() < end and not os.path.exists(kept()):
        time.sleep(0.2)
    time.sleep(0.5)


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
    settle()
    t.ok("turned on: the rules fetched once and kept", asked == ["/rules.json"] and os.path.exists(kept()), asked)
    t.ok("Complianz: its Deny button, not Accept", choice("/complianz") == "deny")
    t.ok("Didomi with no button to say no: Didomi's own refusal, in the page's world", choice("/didomi") == "deny")
    t.ok("a banner no rule knows: left alone", choice("/unknown", within=5) is None)
    sv.quit()

    # The next start reads the copy kept, a day old at most: no fetch.
    start(True, fresh=False)
    time.sleep(1.5)
    t.ok("started again: the kept copy, nothing fetched", asked == ["/rules.json"], asked)
    t.ok("started again: Complianz still refused", choice("/complianz") == "deny")
    sv.quit()

    asked.clear()
    start(True, rules="/broken.json")
    time.sleep(3)
    t.ok("not rules: fetched, and not kept", asked == ["/broken.json"] and not os.path.exists(kept()), asked)
    t.ok("not rules: Complianz left alone", choice("/complianz", within=5) is None)
    sv.quit()

    asked.clear()
    start(False)
    t.ok("off: Complianz untouched", choice("/complianz", within=5) is None)
    t.ok("off: Didomi untouched", choice("/didomi", within=5) is None)
    t.ok("off: nothing fetched", asked == [] and not os.path.exists(kept()), asked)
    sv.quit()
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
