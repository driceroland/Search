#!/usr/bin/env python3
"""Sign-ins that ask for the name first, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/identifier_first.py`. Local
pages on 127.0.0.1:8803 stand in for impots.gouv.fr, Google and the rest: a
first page with the name box alone, a second with the password alone. Two
made-up accounts go into this world's own keychain items (its label, never
the real browser's) through the CSV import, and are forgotten at the end.
The list under a box is read and picked through the bench's `accounts`; no
window is made or shown. The list itself, drawn under the field, is checked
by eye on a release candidate.
"""
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("idf-first")

PORT = 8803
ONE = "idf-one@example.test"
TWO = "idf-two@example.test"

PAGES = {
    # Google's and Microsoft's: the page says which box is the name's.
    "/step1": '<form action="/step2"><input id="u" name="identifier" type="email" autocomplete="username">'
              '<button>Continue</button></form>',
    # impots.gouv.fr's: one box, no hint, a button to send it.
    "/fiscal": '<form action="/step2"><label>Numéro fiscal <input id="u" name="spi" type="text"></label>'
               '<button type="submit">Continuer</button></form>',
    "/step2": '<form action="/done" method="post"><input id="p" name="password" type="password">'
              '<button>Sign in</button></form>',
    "/both": '<form action="/done" method="post"><input id="u" name="user" type="text">'
             '<input id="p" name="password" type="password"><button>Sign in</button></form>',
    "/search": '<form role="search" action="/s"><input id="q" name="q" type="search"></form>'
               '<form action="/s"><input id="q2" name="q" type="text"><button>Go</button></form>',
    "/many": '<form action="/s"><input id="a" name="first"><input name="last"><input name="city">'
             '<input name="street"><button>Send</button></form>',
    "/code": '<form action="/s"><input id="c" name="otc" autocomplete="one-time-code"><button>Verify</button></form>',
}


class H(BaseHTTPRequestHandler):
    def page(self):
        path = self.path.split("?")[0]
        inner = PAGES.get(path, f"<p>{path}</p>")
        body = f"<!doctype html><title>{path.strip('/')}</title>{inner}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self): self.page()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.page()

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def open_page(base, path):
    tab = sv.sp("open", url=f"{base}{path}")["resultID"]
    sv.sp("select", id=tab); time.sleep(1.0)
    return tab


def focus(tab, id):
    sv.ev(tab, f"document.getElementById('{id}').focus(); true"); time.sleep(0.8)
    return acc()


def go(tab, js, wait=1.8):
    sv.ev(tab, js); time.sleep(wait)


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    csv = f"{sv.SUPPORT}-seed.csv"
    try:
        sv.setup(); sv.launch()
        with open(csv, "w") as f:
            f.write(f"url,username,password\n{base}/,{ONE},idf-pass-one\n{base}/,{TWO},idf-pass-two\n")
        r = sv.cmd({"do": "import-file", "path": csv})
        t.ok("two made-up accounts in this world's keychain items", r.get("kept") == 2, r)

        # (a) A first step marked autocomplete=username.
        a = open_page(base, "/step1")
        r = focus(a, "u")
        t.ok("first step: focusing the name box offers the saved accounts",
             r.get("shown") and {x.get("login") for x in r["rows"]} == {ONE, TWO}, r)
        t.ok("…as a name box, a pick fills the name alone", r.get("nameOnly") is True, r)
        rows = [x.get("login") for x in r.get("rows", [])]
        pick = rows.index(TWO) if TWO in rows else 0
        acc(pick=pick); time.sleep(0.6)
        v = sv.ev(a, "[document.getElementById('u').value, document.querySelectorAll('input[type=password]').length]")
        t.ok("picking fills the name box with that account's name", v and v[0] == TWO, v)
        t.ok("no password goes anywhere on the first step", v and v[1] == 0, v)

        # (c) The password page after it: the remembered name.
        go(a, "document.forms[0].requestSubmit(); true")
        t.ok("sent: on to the password page", sv.ev(a, "location.pathname") == "/step2")
        r = focus(a, "p")
        t.ok("password page: the account named on the step before comes first",
             r.get("shown") and r["rows"][0].get("login") == TWO and r.get("nameOnly") is False, r)
        sv.ev(a, "document.activeElement.blur(); true"); time.sleep(0.4)
        go(a, "document.getElementById('p').value = 'idf-new-pass'; document.forms[0].requestSubmit(); true", 3)
        r = acc()
        t.ok("the save question keeps the name given on the step before",
             r.get("offer", {}).get("user") == TWO and r["offer"].get("changed") is True, r)

        # The impots.gouv.fr shape: one plain text box and a button.
        f = open_page(base, "/fiscal")
        r = focus(f, "u")
        t.ok("a lone text box with a button counts as the name box",
             r.get("shown") and r.get("nameOnly") is True, r)
        go(f, f"document.getElementById('u').value = '{ONE}'; document.getElementById('u').dispatchEvent("
              "new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); document.forms[0].requestSubmit(); true")
        go(f, "document.getElementById('p').value = 'idf-new-pass'; document.forms[0].requestSubmit(); true", 3)
        r = acc()
        t.ok("…and the name typed there is the one the password is saved with",
             r.get("offer", {}).get("user") == ONE, r)

        # Another tab, same site: the name stays with the tab it was given in.
        b = open_page(base, "/step1")
        go(b, f"document.getElementById('u').value = '{TWO}'; document.forms[0].requestSubmit(); true")
        c = open_page(base, "/step2")
        go(c, "document.getElementById('p').value = 'idf-other-pass'; document.forms[0].requestSubmit(); true", 3)
        r = acc()
        t.ok("another tab's password page doesn't get this tab's name", r.get("offer", {}).get("user") == "", r)

        # Another site (localhost is not 127.0.0.1): never the name.
        go(b, f"location.href = 'http://localhost:{PORT}/step2'; true", 2)
        go(b, "document.getElementById('p').value = 'idf-other-pass'; document.forms[0].requestSubmit(); true", 3)
        r = acc()
        t.ok("another site's password page doesn't get the name either", r.get("offer", {}).get("user") == "", r)

        # (b) Search boxes, a page of many boxes, a code's box: nothing.
        s = open_page(base, "/search")
        t.ok("a search box (type=search, role=search) offers nothing", focus(s, "q").get("shown") is False)
        t.ok("a box named q with a button offers nothing", focus(s, "q2").get("shown") is False)
        m = open_page(base, "/many")
        t.ok("a box among many offers nothing", focus(m, "a").get("shown") is False)
        k = open_page(base, "/code")
        t.ok("a one-time code's box offers nothing", focus(k, "c").get("shown") is False)

        # (d) A name and password on one page, as before.
        d = open_page(base, "/both")
        r = focus(d, "u")
        t.ok("name and password page: the accounts, as before",
             r.get("shown") and r.get("nameOnly") is False and len(r["rows"]) == 2, r)
        rows = [x.get("login") for x in r.get("rows", [])]
        acc(pick=rows.index(ONE) if ONE in rows else 0); time.sleep(0.6)
        v = sv.ev(d, "[document.getElementById('u').value, document.getElementById('p').value]")
        t.ok("…and a pick fills both boxes", v == [ONE, "idf-pass-one"], v)
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's made-up accounts forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's made-up accounts forgotten", False, e)
        if os.path.exists(csv): os.remove(csv)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
