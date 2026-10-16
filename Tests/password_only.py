#!/usr/bin/env python3
"""A sign-in with a password box alone, in a hidden probe.

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

sv.use("pw-only")

PORT = 8830
GOOD = "PWONLY42"

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


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    try:
        sv.setup(); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)

        # Nothing saved: a wrong code keeps the form, a right one swaps it.
        a = open_login(base)
        send(a, "WRONG1")
        r = acc()
        t.ok("a refused code is not offered", not r.get("offer"), r)
        send(a, GOOD)
        t.ok("signed in in place: pushState to /, no new document",
             sv.ev(a, "[location.pathname, !!document.getElementById('code')]") == ["/", False])
        r = acc()
        t.ok("the save question comes up, with no name",
             r.get("offer", {}).get("user") == "" and r["offer"].get("host") == "127.0.0.1", r)
        r = acc(keep=True)
        t.ok("kept in this world's keychain", r.get("kept") == 1 and not r.get("offer"), r)

        # Saved: the box the page focuses by itself hangs the account.
        b = open_login(base)
        r = acc()
        t.ok("the box the page focuses on load offers the saved code",
             r.get("shown") and r.get("rows") == [{"login": ""}] and r.get("nameOnly") is False, r)
        time.sleep(0.6)
        acc(pick=0); time.sleep(0.6)
        t.ok("a pick fills the box", sv.ev(b, "document.getElementById('code').value") == GOOD)
        sv.ev(b, "document.activeElement.blur(); document.querySelector('button').click(); true"); time.sleep(4)
        r = acc()
        t.ok("signing in with it asks nothing again", not r.get("offer") and r.get("kept") == 1, r)
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
