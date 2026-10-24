#!/usr/bin/env python3
"""The Passwords page lists what the sign-in box offers, however it is reached.

Build first (`./build.sh`), then `python3 Tests/passwords_list.py`. A hidden
probe, the split suite's harness: no window made or shown.

Since Settings and the rest became pages in tabs (a05bb0c4), Settings ›
Passwords › Open… turns the Settings tab itself into the Passwords page
(Browser.lead), a route that never read the keychain: the page said "Nothing
kept yet … 0 passwords" while the box on a sign-in page offered the accounts.
The list is now read each time the page is shown, whichever way it came.

The accounts are made up and kept under this test world's own label ("Search
(sec-pwl-<checkout>)"), in the shapes found in a real keychain: one kept from
a form over https with a last-used date, one brought in by an import with no
protocol, one from a page sent in the clear. Only that label's items are
added, and every one is removed at the end.
"""
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sec-pwl")
LABEL = f"Search ({sv.W})"  # Vault's label in this world
PORT = 8797

LOGIN = """<!doctype html><title>sign in</title>
<form id="f" action="/done" method="post">
<input id="user" name="email" type="email" autocomplete="username">
<input id="pass" name="password" type="password" autocomplete="current-password">
<button type="submit">Sign in</button></form>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = LOGIN.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


def sweep():
    """This world's own items, by label, until none is left. Nothing else in
    the login keychain is touched."""
    for _ in range(100):
        r = subprocess.run(["security", "delete-internet-password", "-l", LABEL], capture_output=True, text=True)
        if r.returncode == 44: return
        if r.returncode != 0: sys.exit(f"sweep: couldn't remove {LABEL!r}: {r.stderr.strip()}")
    sys.exit(f"sweep: more than 100 items under {LABEL!r}")


def keep(server, account, *extra):
    """One made-up item under this world's label, as `security` adds it."""
    subprocess.run(["security", "add-internet-password", "-l", LABEL, "-s", server, "-a", account,
                    "-w", "made-up", *extra], check=True, capture_output=True)


def listed():
    """The list as the page holds it, not read again for the asking."""
    return sv.cmd({"do": "passwords", "shown": True})


def internal():
    return [x.get("internal", "") for x in sv.cmd({"do": "split", "action": "state"})["tabs"]]


def offered(tab, box="pass"):
    sv.ev(tab, "document.activeElement && document.activeElement.blur(); true"); time.sleep(0.4)
    sv.ev(tab, f"document.getElementById('{box}').focus(); true")
    for _ in range(20):
        r = sv.cmd({"do": "accounts"})
        if r.get("shown"): return r
        time.sleep(0.15)
    return sv.cmd({"do": "accounts"})


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        sweep()
        # Kept from a form over https, with when it was last used.
        keep("login-v2.pwl.example", "form@example.org", "-r", "htps", "-t", "form", "-j", "1792766560.2")
        # Brought in by an import: no protocol, no kind.
        keep("login.pwl.example", "import@example.org")
        # From a page sent in the clear: the only kind an http page is offered.
        keep("localhost", "clear@example.org", "-r", "http", "-t", "form")
        sv.setup(); sv.launch()

        # Drice's way in: Settings, then Passwords › Open…, in the same tab.
        sv.cmd({"do": "ui", "settings": True}); time.sleep(0.6)
        sv.cmd({"do": "ui", "lead": "passwords"}); time.sleep(0.8)
        t.ok("Settings › Passwords › Open…: the Settings tab is now the Passwords page",
             "search://passwords" in internal(), internal())
        r = listed()
        t.ok("…and lists all three accounts, without being asked again", r.get("count") == 3, r)

        # Away and back in the same tab: read again, so one kept meanwhile shows.
        sv.cmd({"do": "ui", "lead": "settings"}); time.sleep(0.6)
        keep("pwl-other.example", "later@example.org")
        sv.cmd({"do": "ui", "lead": "passwords"}); time.sleep(0.8)
        r = listed()
        t.ok("back to Passwords from Settings: the one kept meanwhile is there too", r.get("count") == 4, r)

        # Its address typed on the tab, which only the tab hears (Tab.go):
        # read as the page is drawn.
        sv.cmd({"do": "ui", "lead": "settings"}); time.sleep(0.6)
        keep("pwl-typed.example", "typed@example.org")
        sv.cmd({"do": "ui", "go": "search://passwords"}); time.sleep(0.8)
        t.ok("search://passwords typed on the Settings tab: Passwords", "search://passwords" in internal(), internal())
        r = listed()
        t.ok("…lists the one kept meanwhile too: five", r.get("count") == 5, r)

        # The sign-in box offers from the same keychain items.
        a = sv.sp("open", url=f"http://localhost:{PORT}/login")["resultID"]
        sv.sp("select", id=a); time.sleep(1.2)
        r = offered(a)
        rows = [x.get("login") for x in r.get("rows", [])]
        t.ok("the box on an http page offers the one kept in the clear", r.get("shown") and rows == ["clear@example.org"], r)
        users = sorted(r.get("users", []))
        t.ok("what the box draws from is what the page lists",
             users == ["clear@example.org", "form@example.org", "import@example.org", "later@example.org", "typed@example.org"], users)

        r = sv.cmd({"do": "passwords"})
        t.ok("read again on asking: five", r.get("count") == 5, r)
    finally:
        try:
            sweep()
            left = subprocess.run(["security", "find-internet-password", "-l", LABEL], capture_output=True).returncode
            t.ok("this world's made-up items removed from the keychain", left == 44, left)
        except SystemExit as e:
            t.ok("this world's made-up items removed from the keychain", False, e)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
