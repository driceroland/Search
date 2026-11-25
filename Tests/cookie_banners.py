#!/usr/bin/env python3
"""Cookie banners refused (CookieBanners.swift), on local stand-ins for the
five makers' banners, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/cookie_banners.py`. It runs in a
world of its own (bld-cookies-<checkout>) with split_view.py's harness:
started hidden, everything removed afterwards.

Each stand-in does what its maker's banner does, as far as the script can
see: the same ids and classes, the same public API (window.OneTrust,
didomiOnReady and the Didomi it hands over, window.Cookiebot, UC_UI, an open
shadow root for Usercentrics), often loaded a moment after the page. Every
way to say no counts in window.__cb.refused, every way to say yes in
window.__cb.agreed, which must stay 0 everywhere.
"""
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-cookies")

COUNT = """<script>
window.__cb = { refused: 0, agreed: 0, how: [] };
function no(how) { window.__cb.refused++; window.__cb.how.push(how); }
function yes(how) { window.__cb.agreed++; window.__cb.how.push('YES ' + how); }
function el(html) { var d = document.createElement('div'); d.innerHTML = html; return d.firstElementChild; }
function report() { if (parent !== window) parent.postMessage(window.__cb, '*'); }
</script>"""

PAGES = {
    # A moment after the page, as OneTrust's SDK loads: its API, then the
    # banner it draws.
    "/onetrust": """
<script>setTimeout(function () {
  var closed = false;
  window.OneTrust = { IsAlertBoxClosed: function () { return closed; },
    RejectAll: function () { closed = true; no('RejectAll'); document.getElementById('onetrust-banner-sdk').remove(); },
    AllowAll: function () { yes('AllowAll'); } };
  document.body.appendChild(el('<div id="onetrust-banner-sdk"><p>We use cookies</p>' +
    '<button id="onetrust-accept-btn-handler" onclick="yes(\\'click\\')">Accept all</button>' +
    '<button id="onetrust-reject-all-handler" onclick="no(\\'click\\')">Reject all</button></div>'));
}, 600);</script>""",
    # No API in reach: its button.
    "/onetrust-click": """
<div id="onetrust-banner-sdk"><p>We use cookies</p>
<button id="onetrust-accept-btn-handler" onclick="yes('click')">Accept all</button>
<button id="onetrust-reject-all-handler" onclick="no('click'); this.parentNode.remove(); report();">Reject all</button></div>
<script>setTimeout(report, 2000);</script>""",
    "/didomi": """
<script>
// As the site's snippet and Didomi's SDK do: the queue first, then, once
// the SDK is ready, the queue run and the notice drawn.
window.didomiOnReady = window.didomiOnReady || [];
setTimeout(function () {
  var collected = false;
  var api = { shouldConsentBeCollected: function () { return !collected; },
    setUserDisagreeToAll: function () { collected = true; no('setUserDisagreeToAll'); document.getElementById('didomi-host').remove(); },
    setUserAgreeToAll: function () { yes('setUserAgreeToAll'); } };
  var queued = window.didomiOnReady;
  window.didomiOnReady = { push: function (f) { f(api); } };
  queued.forEach(function (f) { f(api); });
  document.body.appendChild(el('<div id="didomi-host"><div id="didomi-notice">' +
    '<button id="didomi-notice-agree-button" onclick="yes(\\'click\\')">Accetta</button>' +
    '<button id="didomi-notice-disagree-button" onclick="no(\\'click\\')">Rifiuta</button></div></div>'));
}, 500);
</script>""",
    # A pay-or-agree wall: its no is a subscription.
    "/didomi-paid": """
<div id="didomi-host"><div id="didomi-notice">
<button id="didomi-notice-agree-button" onclick="yes('click')">Accetta e continua</button>
<button id="didomi-notice-disagree-button" onclick="no('click')">Rifiuta e abbonati a 1 € al mese</button></div></div>""",
    "/cookiebot": """
<div id="CybotCookiebotDialog"><p>This website uses cookies</p>
<button id="CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll" onclick="yes('click')">Allow all</button>
<button id="CybotCookiebotDialogBodyButtonDecline" onclick="no('click'); Cookiebot.declined = true; Cookiebot.hasResponse = true; this.parentNode.remove();">Deny</button></div>
<script>window.Cookiebot = { hasResponse: false, declined: false,
  withdraw: function () { no('withdraw'); this.declined = true; }, hide: function () {} };</script>""",
    # Three seconds late, with nothing else on the page changing meanwhile.
    "/iubenda": """
<script>setTimeout(function () {
  document.body.appendChild(el('<div id="iubenda-cs-banner"><p>Cookie</p>' +
    '<button class="iubenda-cs-accept-btn" onclick="yes(\\'click\\')">Accetta</button>' +
    '<button class="iubenda-cs-reject-btn" onclick="no(\\'click\\'); report();">Rifiuta</button></div>'));
}, 3000);</script>""",
    "/usercentrics": """
<div id="usercentrics-root"></div>
<script>setTimeout(function () {
  var shadow = document.getElementById('usercentrics-root').attachShadow({ mode: 'open' });
  shadow.innerHTML = '<div><button data-testid="uc-accept-all-button">Accept All</button><button data-testid="uc-deny-all-button">Deny</button></div>';
  shadow.querySelector('[data-testid=uc-accept-all-button]').onclick = function () { yes('click'); };
  shadow.querySelector('[data-testid=uc-deny-all-button]').onclick = function () { no('click'); };
  window.UC_UI = { isConsentRequired: function () { return true; }, denyAllConsents: function () { no('denyAllConsents'); },
    acceptAllConsents: function () { yes('acceptAllConsents'); } };
}, 400);</script>""",
    # A banner nobody documented: left alone.
    "/unknown": """
<div id="cookie-banner"><p>Cookies?</p><button id="reject" onclick="no('click')">Reject all</button>
<button id="accept" onclick="yes('click')">Accept all</button></div>""",
}


class H(BaseHTTPRequestHandler):
    def reply(self, body):
        body = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        port = self.server.server_port
        if path in PAGES:
            self.reply(f"<!doctype html><meta charset=utf-8><title>{path}</title><body>{COUNT}{PAGES[path]}</body>")
        elif path == "/framed":
            # Another site framing a page with a banner: only main frames
            # get the script, so the frame's banner is left as it is.
            self.reply(f"""<!doctype html><title>framed</title><body>{COUNT}
<script>addEventListener('message', function (e) {{ window.__frame = e.data; }});</script>
<iframe src="http://localhost:{port}/onetrust-click"></iframe></body>""")
        else:
            self.send_response(404); self.end_headers()

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
PORT = srv.server_port


def start(on=True, paused=None):
    sv.setup(**{"privacy.cookieBanners": on})
    if paused:
        subprocess.run(["defaults", "write", sv.SUITE, "shield.paused", "-array", paused], check=True)
    sv.launch()


def visit(path, within=6.0, private=False, read="window.__cb", until=lambda v: v and v.get("refused"), host="127.0.0.1"):
    """What the page counted once it was refused, or after `within` seconds.
    A banner that is there at load is answered within half a second, so 3
    seconds is plenty to say nothing was done."""
    req = {"do": "open", "url": f"http://{host}:{PORT}{path}"}
    if private: req["private"] = True
    id = sv.cmd(req)["id"]
    got, waited = None, 0.0
    while waited < within:
        time.sleep(0.4); waited += 0.4
        got = sv.ev(id, read)
        if until(got): break
    # A little longer, in case it would act twice.
    time.sleep(1.0)
    return sv.ev(id, read) or {}


def refused_once(v): return v.get("refused") == 1 and v.get("agreed") == 0
def untouched(v): return v.get("refused") == 0 and v.get("agreed") == 0


t = sv.T()
try:
    start()
    for path, how in [("/onetrust", "RejectAll"), ("/onetrust-click", "click"), ("/didomi", "setUserDisagreeToAll"),
                      ("/cookiebot", "click"), ("/usercentrics", "click")]:
        v = visit(path)
        t.ok(f"{path}: refused once, by {how}, nothing agreed", refused_once(v) and v.get("how") == [how], v)
    v = visit("/iubenda")
    t.ok("/iubenda three seconds late: refused once", refused_once(v), v)
    paid = visit("/didomi-paid", within=3)
    t.ok("a paid no is left for you", untouched(paid), paid)
    unknown = visit("/unknown", within=3)
    t.ok("a banner nobody documented is left alone", untouched(unknown), unknown)
    framed = visit("/framed", within=3, read="window.__frame")
    t.ok("a banner in a frame: left as it is", "refused" in framed and untouched(framed), framed)
    shy = visit("/onetrust-click", private=True)
    t.ok("a private tab, with the switch on: refused", refused_once(shy), shy)
    sv.quit()

    start(on=False)
    off = visit("/onetrust-click", within=3)
    t.ok("switch off: untouched", untouched(off), off)
    shy_off = visit("/onetrust-click", within=3, private=True)
    t.ok("switch off, private tab: untouched", untouched(shy_off), shy_off)
    sv.quit()

    start(paused="127.0.0.1")
    paused = visit("/onetrust-click", within=3)
    t.ok("Shield paused on the site: untouched", untouched(paused), paused)
    elsewhere = visit("/onetrust-click", host="localhost")
    t.ok("…and refused on a site it isn't paused for", refused_once(elsewhere), elsewhere)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
