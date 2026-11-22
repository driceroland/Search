#!/usr/bin/env python3
"""No save question on a dashboard that was never a sign-in, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/password_false_offer.py`.
A logged-in dashboard's Contacts page asked "Save the password for 40 on
resend.com?": 40 was its page size, and nobody had typed a password. The
page on 127.0.0.1:8831 stands in for one: a list with a page-size picker
("40 items", a <select> and a text box beside it), a search box, a masked
key the page fills in by itself in an <input type="password">, and buttons
that change the page in place and send by fetch. None of it may be offered.

Then the same page with a password typed into a box: it is offered, under
no name — never under the page size.

Saved logins would go into this world's own keychain items (its label,
never the real browser's) and are forgotten at the end. No window is made
or shown.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pw-false")

PORT = 8831

DASHBOARD = """<!doctype html><title>Contacts</title>
<div id="app">
<header><input id="q" type="search" placeholder="Search contacts"></header>
<main id="list"><p>Contacts 1-40</p></main>
<div id="key"><label for="secret">API key</label>
<input id="secret" type="password" readonly></div>
<footer>
<select id="size" name="per_page"><option value="20">20 items</option>
<option value="40" selected>40 items</option><option value="80">80 items</option></select>
<input id="sizebox" type="text" value="40" aria-label="Items per page">
<button id="more" type="button">Next page</button>
<button id="hide" type="button">Hide key</button>
</footer>
<form id="filter"><input id="tag" name="tag" type="text" placeholder="Tag">
<button type="submit">Filter</button></form>
</div>
<script>
// The page shows its own key, masked, as a dashboard does.
document.getElementById('secret').value = 're_probe_key_123';
document.getElementById('more').addEventListener('click', async function () {
  await fetch('/api/contacts?size=' + document.getElementById('size').value);
  history.pushState({}, '', '/contacts?page=2');
  document.getElementById('list').innerHTML = '<p>Contacts 41-80</p>';
});
document.getElementById('hide').addEventListener('click', function () {
  document.getElementById('key').remove();
});
document.getElementById('filter').addEventListener('submit', async function (e) {
  e.preventDefault();
  await fetch('/api/contacts', { method: 'POST', body: document.getElementById('tag').value });
  document.getElementById('list').innerHTML = '<p>Filtered</p>';
});
</script>"""

# The same footer, with a sign-in box after it and no form: what is typed is
# a password, and the page size before it is not its name.
TYPED = """<!doctype html><title>Unlock</title>
<div id="app">
<input id="sizebox" type="text" value="40" aria-label="Items per page">
<select id="size"><option value="40" selected>40 items</option></select>
<input id="q" type="search" value="40">
<input id="pw" type="password" autocomplete="current-password">
<button id="go" type="button">Unlock</button>
</div>
<script>
document.getElementById('go').addEventListener('click', async function () {
  await fetch('/api/unlock', { method: 'POST' });
  history.pushState({}, '', '/');
  document.getElementById('app').innerHTML = '<h1>Unlocked</h1>';
});
</script>"""


class H(BaseHTTPRequestHandler):
    def send(self, code, body, kind):
        body = body.encode()
        self.send_response(code); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/api/"):
            return self.send(200, json.dumps({"ok": True}), "application/json")
        self.send(200, TYPED if path == "/unlock" else DASHBOARD, "text/html; charset=utf-8")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send(200, json.dumps({"ok": True}), "application/json")

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def type_into(tab, box, text):
    """As a person types: the value, then the input event a keystroke fires."""
    sv.ev(tab, "var b = document.getElementById('%s'); b.focus();"
               "Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(b, '%s');"
               "b.dispatchEvent(new Event('input', {bubbles: true})); true" % (box, text))


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    try:
        sv.setup(); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)

        a = sv.sp("open", url=f"{base}/contacts")["resultID"]
        sv.sp("select", id=a); time.sleep(1.2)
        t.ok("the page filled its own key", sv.ev(a, "document.getElementById('secret').value") == "re_probe_key_123")

        # The page size picked, as a person picks it.
        sv.ev(a, "var s = document.getElementById('size'); s.focus(); s.value = '40';"
                 "s.dispatchEvent(new Event('input', {bubbles: true}));"
                 "s.dispatchEvent(new Event('change', {bubbles: true})); true")
        type_into(a, "sizebox", "40")
        sv.ev(a, "document.getElementById('sizebox').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); true")
        time.sleep(1.5)
        t.ok("a page size picked and typed offers nothing", not acc().get("offer"), acc())

        type_into(a, "q", "40")
        sv.ev(a, "document.getElementById('q').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); true")
        time.sleep(1.5)
        t.ok("a search typed offers nothing", not acc().get("offer"), acc())

        sv.ev(a, "document.getElementById('more').click(); true"); time.sleep(3)
        t.ok("the next page, by fetch and pushState, offers nothing", not acc().get("offer"), acc())

        type_into(a, "tag", "40")
        sv.ev(a, "document.getElementById('filter').requestSubmit(); true"); time.sleep(3)
        t.ok("a form sent by fetch offers nothing", not acc().get("offer"), acc())

        # The masked key goes away after a button: that is how a sign-in
        # done in place looks, but nobody typed it.
        sv.ev(a, "document.getElementById('hide').click(); true"); time.sleep(3.5)
        t.ok("a key the page filled itself, gone after a click, offers nothing", not acc().get("offer"), acc())

        # A password really typed, beside the same footer.
        b = sv.sp("open", url=f"{base}/unlock")["resultID"]
        sv.sp("select", id=b); time.sleep(1.2)
        type_into(b, "pw", "typed-pass-1")
        sv.ev(b, "document.activeElement.blur(); document.getElementById('go').click(); true"); time.sleep(4)
        r = acc()
        t.ok("a typed password is offered, under no name and not the page size",
             r.get("offer", {}).get("user") == "" and r["offer"].get("host") == "127.0.0.1", r)
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
