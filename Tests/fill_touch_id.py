#!/usr/bin/env python3
"""Ask for Touch ID before filling (idea 993), in a hidden probe.

Settings › Passwords › Ask for Touch ID before filling: with it on, a kept
password goes into the page only after the Mac's owner says yes; a cancel
fills nothing, a yes holds for a minute, and a click and a Return on the
list both ask. The Mac's own question is never put up: the probe answers as
`ui confirm` says, and with nothing set a fill is refused. Run it holding
the shared probe lock (keychain), e.g.
`lockf -t 900 /private/tmp/claude-501/search-probe.lock python3 Tests/fill_touch_id.py`.

The page below is the one of password_only.py:

Build first (`./build.sh`), then `python3 Tests/password_only.py`. A local
page on 127.0.0.1:8830 stands in for a private dashboard's access code:
one <input type="password" autocomplete="current-password" autofocus> in a form, no name box, sent by
fetch, and on success the page swaps itself for the dashboard with
history.pushState — no new document, as a Next.js router.push does. What it
saves goes into this world's own keychain items (its label, never the real
browser's) and is forgotten at the end. The list under the box is read and
picked through the bench's `accounts`; no window is made or shown.
"""
import json
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fill-touch-id")

PORT = 8834
GOOD = "FILLTID7"

LOGIN = """<!doctype html><title>login</title>
<div id="app"><form id="f"><label for="code">Access code</label>
<input id="code" name="password" type="password" autocomplete="current-password" autofocus maxlength="64">
<p id="err"></p><button type="submit">Access dashboard</button></form></div>
<script>
var box = document.getElementById('code');
box.addEventListener('input', function () {
  var v = box.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (v !== box.value) box.value = v;
});
document.getElementById('f').addEventListener('submit', async function (e) {
  e.preventDefault();
  var r = await fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                          body: JSON.stringify({ code: box.value.trim() }) });
  var d = await r.json();
  if (r.ok) {
    history.pushState({}, '', '/');
    document.getElementById('app').innerHTML = '<h1>Dashboard</h1><p>Signed in</p>';
    document.title = 'dashboard';
  } else {
    document.getElementById('err').textContent = d.error;
  }
});
</script>"""


class H(BaseHTTPRequestHandler):
    def send(self, code, body, kind):
        body = body.encode()
        self.send_response(code); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        self.send(200, LOGIN if self.path.split("?")[0] == "/login" else "<!doctype html><p>home</p>", "text/html; charset=utf-8")

    def do_POST(self):
        sent = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        ok = sent.get("code") == GOOD
        self.send(200 if ok else 401, json.dumps({"ok": True} if ok else {"error": "Invalid code"}), "application/json")

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def open_login(base):
    tab = sv.sp("open", url=f"{base}/login")["resultID"]
    sv.sp("select", id=tab); time.sleep(1.2)
    return tab


def send(tab, code, wait=4.0):
    """Typed, then the button pressed, as a person would."""
    sv.ev(tab, "var b = document.getElementById('code'); b.focus();"
               "Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(b, '%s');"
               "b.dispatchEvent(new Event('input', {bubbles: true})); true" % code)
    sv.ev(tab, "document.activeElement.blur(); document.querySelector('button').click(); true")
    time.sleep(wait)


def confirm(yes): sv.cmd({"do": "ui", "confirm": yes})


def box(tab): return sv.ev(tab, "document.getElementById('code').value")


def offered(t, base, name):
    tab = open_login(base)
    r = acc()
    t.ok(name + ": the list hangs from the box", r.get("shown") and r.get("rows") == [{"login": ""}], r)
    time.sleep(0.6)
    return tab


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    try:
        sv.setup(); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)
        a = open_login(base)
        send(a, GOOD)
        r = acc(keep=True)
        t.ok("a made-up code kept in this world's keychain", r.get("kept") == 1, r)
        t.ok("off by default", r.get("prove") is False, r)

        # Off: as before, no question.
        b = offered(t, base, "off")
        acc(pick=0); time.sleep(0.6)
        t.ok("off: a click fills without asking", box(b) == GOOD and acc().get("proofs") == 0)

        # On, cancelled: by click and by Return, nothing filled.
        acc(prove=True)
        confirm(False)
        c = offered(t, base, "cancel/click")
        r = acc(pick=0); time.sleep(0.8)
        t.ok("on, cancelled click: asked once, nothing filled", acc().get("proofs") == 1 and box(c) == "", box(c))
        d = offered(t, base, "cancel/return")
        acc(lit=1); time.sleep(0.8)
        r = acc()
        t.ok("on, cancelled Return: asked, nothing filled", r.get("proofs") == 2 and box(d) == "", (r, box(d)))
        t.ok("a cancel leaves no grace", r.get("fresh") is False, r)

        # No answer set in a test run: refused, never the Mac's own sheet.
        sv.cmd({"do": "ui", "confirm": "ask"})
        e = offered(t, base, "no answer")
        acc(pick=0); time.sleep(0.8)
        r = acc()
        t.ok("a test run with no answer fills nothing", r.get("proofs") == 3 and box(e) == "" and not r.get("fresh"), (r, box(e)))

        # Yes, by Return: filled; then within the minute, a click fills unasked.
        confirm(True)
        f = offered(t, base, "yes/return")
        acc(lit=1); time.sleep(0.8)
        r = acc()
        t.ok("on, yes by Return: asked, filled", r.get("proofs") == 4 and box(f) == GOOD and r.get("fresh"), (r, box(f)))
        confirm(False)
        g = offered(t, base, "grace")
        acc(pick=0); time.sleep(0.8)
        t.ok("within the minute: filled without asking again", acc().get("proofs") == 4 and box(g) == GOOD, box(g))

        # The minute is up: asked again (and cancelled: nothing).
        acc(proofAge=61)
        h = offered(t, base, "after the minute")
        acc(pick=0); time.sleep(0.8)
        r = acc()
        t.ok("after a minute: asked again, the cancel fills nothing", r.get("proofs") == 5 and box(h) == "", (r, box(h)))

        # A yes, then the switch off and on: the yes is spent.
        confirm(True)
        i = offered(t, base, "yes/click")
        acc(pick=0); time.sleep(0.8)
        t.ok("on, yes by click: filled", acc().get("proofs") == 6 and box(i) == GOOD)
        acc(prove=False); acc(prove=True)
        t.ok("turning it off and on forgets the yes", acc().get("fresh") is False)

        # The Mac can't ask: with no password set there's nothing to prove;
        # for any other reason, nothing is filled, whatever the answer.
        acc(proofAge=0)
        confirm(True)
        acc(proveError="invalidContext")
        r_ = offered(t, base, "can't ask, other reason")
        acc(pick=0); time.sleep(0.8)
        r = acc()
        t.ok("can't ask for another reason: nothing filled, no grace",
             r.get("proofs") == 7 and box(r_) == "" and not r.get("fresh"), (r, box(r_)))
        acc(proveError="passcodeNotSet")
        s_ = offered(t, base, "no password set")
        acc(pick=0); time.sleep(0.8)
        t.ok("no password set on the Mac: filled", acc().get("proofs") == 8 and box(s_) == GOOD, box(s_))
        acc(proveError="", proofAge=0)

        # Off again: no question.
        acc(prove=False)
        confirm(False)
        j = offered(t, base, "off again")
        acc(pick=0); time.sleep(0.6)
        t.ok("off again: filled without asking", acc().get("proofs") == 8 and box(j) == GOOD)
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's logins forgotten", False, e)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
