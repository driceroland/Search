#!/usr/bin/env python3
"""The accounts under a sign-in box, with Split View on, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/account_list_split.py`. With
Split View on, the list under a sign-in box was up — `accounts` said so — but
drawn under WebKit's page, so nobody saw it and a click there went to the
page. What a press lands on is asked of the window itself (`hit`): on the
list, the list's host; on the box, and off the list, the page. A local page
on 127.0.0.1:8832 has a name box and a password box, the name box focused
by the page as Roundcube's is. What it saves is this world's own and is
forgotten at the end; no window is shown.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("account-split")

PORT = 8832
USER = "someone"

LOGIN = """<!doctype html><title>Webmail :: Welcome</title>
<form method="post" action="/" style="margin:120px 60px">
<input name="_user" id="u" type="text" style="width:270px;height:40px">
<input name="_pass" id="p" type="password" autocomplete="off" style="width:270px;height:40px">
<button type="submit">Login</button></form>
<script>document.addEventListener('DOMContentLoaded', function () { document.getElementById('u').focus(); });</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (LOGIN if self.path == "/" else "<!doctype html><title>Inbox</title><h1>Inbox</h1>").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        # Signed in: the mailbox, a new document with no sign-in on it.
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(302); self.send_header("Location", "/mail")
        self.send_header("Content-Length", "0"); self.end_headers()

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})
def hit(x, y): return sv.cmd({"do": "hit", "x": x, "y": y}).get("view", "")


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    try:
        sv.setup(splitView=True); sv.launch()
        acc(forget=True)

        # Saved once, by hand.
        a = sv.sp("open", url=f"{base}/")["resultID"]
        sv.sp("select", id=a); time.sleep(1.5)
        sv.ev(a, """var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          var u = document.getElementById('u'), p = document.getElementById('p');
          set.call(u, %r); u.dispatchEvent(new Event('input', {bubbles: true}));
          p.focus(); set.call(p, 'pw-42'); p.dispatchEvent(new Event('input', {bubbles: true}));
          document.forms[0].requestSubmit(); true""" % USER)
        time.sleep(2)
        r = acc(keep=True)
        t.ok("kept in this world's keychain", r.get("kept") == 1, r)
        sv.sp("close", id=a)

        b = sv.sp("open", url=f"{base}/")["resultID"]
        sv.sp("select", id=b); time.sleep(1.5)
        r = acc()
        t.ok("Split View on: the list is up for the focused box", r.get("shown") is True, r)
        page = sv.cmd({"do": "probe"}).get("activePageFrame")
        t.ok("the page's place in the window is known", bool(page), page)
        if r.get("shown") and page:
            x, y, w, h = r["spot"]
            px, py = page[0], page[1]
            on_list = hit(px + x + 60, py + y + h + 6 + 18)
            t.ok("a press on the list lands on the list, not the page", "AccountHost" in on_list, on_list)
            on_box = hit(px + x + w / 2, py + y + h / 2)
            t.ok("a press on the box is still the page's", "AccountHost" not in on_box and on_box != "", on_box)
            off = hit(px + x + w + 300, py + y + h + 200)
            t.ok("a press off the list is still the page's", "AccountHost" not in off and off != "", off)
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
