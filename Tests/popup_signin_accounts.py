#!/usr/bin/env python3
"""A sign-in in a site's sized pop-up offers what a tab does (idea 1107).

Build first (`./build.sh`), then `python3 Tests/popup_signin_accounts.py`.
A local stand-in on 127.0.0.1 for Gmail's Add another account: a click opens
the sign-in with window.open and a size, as Google's does. The sign-in has a
name box (autocomplete="username webauthn"), a password box, and a passkey
request under the field (mediation: conditional). A made-up login is kept
first in this world's own keychain items (its label, never the real
browser's) and forgotten at the end; a test run's passkey is the made-up one
Passkeys.perform answers with, the Mac is never asked.

Checked with Settings › Open sized pop-ups in small windows off (a tab) and
on (a small window of its own): the caret in the name box hangs the kept
login and the passkey, as the same page opened as a plain tab does. Read
through the bench's `accounts`; the probe stays hidden, its windows are
never ordered in, and none must be on a screen.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("popup-signin")

USER = "probe-user@example.test"
SECRET = "Probe-Only-1107"

SIGNIN = """<!doctype html><meta charset=utf-8><title>sign in</title>
<form id=f method=post action=/done>
  <input id=u name=username autocomplete="username webauthn">
  <input id=p name=password type=password autocomplete="current-password">
  <button id=go type=submit>Sign in</button>
</form>
<script>
window.__pk = 'waiting';
if (window.PublicKeyCredential && PublicKeyCredential.isConditionalMediationAvailable) {
  PublicKeyCredential.isConditionalMediationAvailable().then(function (ok) {
    if (!ok) { window.__pk = 'no conditional'; return; }
    navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(16), rpId: location.hostname } })
      .then(function (c) { window.__pk = c ? 'signed in' : 'null'; }, function (e) { window.__pk = e.name; });
  });
}
</script>"""

OPENER = """<!doctype html><meta charset=utf-8><title>mail</title>
<button id=sized onclick="w=window.open('/signin?from=popup','_blank','width=480,height=600')">Add another account</button>
<button id=plain onclick="window.open('/signin?from=tab')">Same, as a tab</button>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        self.respond(SIGNIN if path == "/signin" else OPENER if path == "/opener" else "<p>home</p>")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.respond("<!doctype html><title>done</title><p>Signed in</p>")

    def respond(self, body):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def on_screen():
    """The probe's windows the app says are on a screen: there must be none."""
    return [w for w in windows() if w.get("shown")]


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def tabs(window=1):
    return sv.cmd({"do": "tabs", "window": window})["tabs"]


def ev(tab, js, window=1):
    return sv.cmd({"do": "eval", "id": tab, "js": js, "window": window}).get("value")


def tap(tab, selector, window=1):
    sv.cmd({"do": "select", "id": tab, "window": window})
    time.sleep(0.2)
    sv.cmd({"do": "tap", "id": tab, "selector": selector, "window": window})
    time.sleep(1.5)


def accounts(window=1, **f):
    return sv.cmd({"do": "accounts", "window": window, **f})


def caret(tab, window=1):
    """The caret into the name box, once the page's passkey request waits."""
    for _ in range(20):
        if ev(tab, "window.__pk", window) == "waiting":
            break
        time.sleep(0.25)
    ev(tab, "document.activeElement && document.activeElement.blur(); document.getElementById('u').focus(); true", window)
    time.sleep(1.2)
    return accounts(window)


def on_box(r, window):
    """What a press on the name box itself lands on: the page, always."""
    page = sv.cmd({"do": "probe", "window": window}).get("activePageFrame")
    spot = r.get("spot")
    if not (page and spot):
        return f"no page or box: {page} {spot}"
    return sv.cmd({"do": "hit", "x": page[0] + spot[0] + 10, "y": page[1] + spot[1] + spot[3] / 2,
                   "window": window}).get("view", "")


def lands(r, window):
    """What a press on the list's first row lands on, asked of the window
    itself: the list's host when the list is over the page, the page when it
    is drawn under it (no one sees it, and the click goes to the page)."""
    page = sv.cmd({"do": "probe", "window": window}).get("activePageFrame")
    spot = r.get("spot")
    if not (page and spot):
        return f"no page or box: {page} {spot}"
    x, y = page[0] + spot[0] + 40, page[1] + spot[1] + spot[3] + 6 + 18
    return sv.cmd({"do": "hit", "x": x, "y": y, "window": window}).get("view", "")


def find(path_query, window):
    return next((t for t in tabs(window) if path_query in t["url"]), None)


def keep_login(t):
    tab = sv.sp("open", url=f"{sv.BASE}/signin?from=save")["resultID"]
    sv.sp("select", id=tab)
    time.sleep(1.2)
    ev(tab, "var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;"
            "[['u', %s], ['p', %s]].forEach(function (f) { var b = document.getElementById(f[0]); b.focus(); set.call(b, f[1]);"
            "b.dispatchEvent(new Event('input', {bubbles: true})); }); true" % (json.dumps(USER), json.dumps(SECRET)))
    ev(tab, "document.activeElement.blur(); document.getElementById('go').click(); true")
    time.sleep(3)
    r = accounts(keep=True)
    t.ok("a made-up login is kept in this world's keychain", r.get("kept") == 1, r)
    sv.sp("close", id=tab)


def rows(r):
    return r.get("rows") or []


def check(t, popups):
    label = f"small windows {'on' if popups else 'off'}"
    sv.setup(**{"tabs.popupWindows": popups})
    sv.launch()
    try:
        keep_login(t)
        opener = sv.page("opener")

        # The same page as a plain tab: what the pop-up should match.
        tap(opener, "#plain")
        plain = find("from=tab", 1)
        sv.sp("select", id=plain["id"])
        time.sleep(1)
        r = caret(plain["id"])
        tab_rows = rows(r)
        t.ok(f"{label}: as a tab, the name box offers the passkey and the login",
             {"login": USER} in tab_rows and any("passkey" in r for r in tab_rows), tab_rows)
        on = lands(r, 1)
        t.ok(f"{label}: as a tab, a press under the box lands on the list", "AccountHost" in on, on)
        sv.sp("close", id=plain["id"])
        sv.sp("select", id=opener)
        time.sleep(0.5)

        tap(opener, "#sized")
        n = 2 if popups else 1
        t.ok(f"{label}: the sized pop-up opened {'in a window of its own' if popups else 'as a tab'}",
             len(windows()) == (2 if popups else 1), windows())
        t.ok(f"{label}: no probe window on a screen", not on_screen(), on_screen())
        popup = find("from=popup", n)
        if not popup:
            t.ok(f"{label}: the pop-up's sign-in is there", False, [w["tabs"] for w in windows()])
            return
        if not popups:
            sv.sp("select", id=popup["id"])
            time.sleep(1)
        r = caret(popup["id"], n)
        t.ok(f"{label}: in the pop-up, the name box offers the passkey and the login too",
             {"login": USER} in rows(r) and any("passkey" in x for x in rows(r)), r)
        on = lands(r, n)
        t.ok(f"{label}: in the pop-up, a press under the box lands on the list, over the page", "AccountHost" in on, on)
        page = sv.cmd({"do": "probe", "window": n}).get("activePageFrame") or [0, 0]
        card, spot = accounts(n).get("card"), r.get("spot") or [0, 0, 0, 0]
        want = (page[0] + spot[0], page[1] + spot[1] + spot[3] + 6)
        t.ok(f"{label}: in the pop-up, the card as drawn hangs under the box",
             bool(card) and abs(card[0] - want[0]) <= 2 and abs(card[1] - want[1]) <= 2, {"card": card, "want": want})
        on = on_box(r, n)
        t.ok(f"{label}: in the pop-up, a press on the box itself is still the page's", on == "PageView", on)
        t.ok(f"{label}: still no probe window on a screen", not on_screen(), on_screen())
    finally:
        try:
            r = accounts(forget=True)
            t.ok(f"{label}: this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok(f"{label}: this world's logins forgotten", False, e)
        sv.quit()


def main():
    t = sv.T()
    try:
        check(t, False)
        check(t, True)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
