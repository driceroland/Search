#!/usr/bin/env python3
"""A login with no name beside a named one on the same site, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/password_only_mixed.py`. A
password box alone saves its password under no name, and the keychain keeps
such an item with no account at all. Vault then names it by an empty
account when it reads, saves or forgets it: this checks that the empty
account reaches that one item only, never the named ones kept for the same
site. Two made-up logins for 127.0.0.1:8832 go into this world's own
keychain items (its label, never the real browser's) through the CSV
import, and are forgotten at the end. No window is made or shown.
"""
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pw2-mixed")

PORT = 8832
NAMED, NAMED_PW = "alice", "mixed-pass-a"
NAMELESS_PW, NEW_PW = "mixed-pass-0", "mixed-pass-1"

PAGES = {
    "/both": '<form action="/done" method="post"><input id="u" name="user" type="text">'
             '<input id="p" name="password" type="password"><button>Sign in</button></form>',
    "/code": '<form action="/done" method="post"><input id="p" name="password" type="password">'
             '<button>Sign in</button></form>',
}


class H(BaseHTTPRequestHandler):
    def page(self):
        path = self.path.split("?")[0]
        body = f"<!doctype html><title>{path.strip('/')}</title>{PAGES.get(path, f'<p>{path}</p>')}".encode()
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


def filled(base, user):
    """The password a pick of `user` under the box puts in, on a fresh page."""
    tab = open_page(base, "/both")
    sv.ev(tab, "document.getElementById('p').focus(); true"); time.sleep(0.8)
    rows = [x.get("login") for x in acc().get("rows", [])]
    if user not in rows: return None, rows
    acc(pick=rows.index(user)); time.sleep(0.6)
    return sv.ev(tab, "document.getElementById('p').value"), rows


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    csv = f"{sv.SUPPORT}-seed.csv"

    def seed(*rows):
        with open(csv, "w") as f:
            f.write("url,username,password\n" + "".join(f"{base}/,{u},{p}\n" for u, p in rows))
        return sv.cmd({"do": "import-file", "path": csv})

    try:
        sv.setup(); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)
        r = seed((NAMED, NAMED_PW), ("", NAMELESS_PW))
        t.ok("a named login and a nameless one kept for the same site", r.get("kept") == 2, r)

        # (1) Both listed.
        r = acc()
        t.ok("the list holds both", sorted(r.get("users", [])) == ["", NAMED], r)

        # (2) Each pick gives its own password.
        v, rows = filled(base, "")
        t.ok("both offered under the box", sorted(rows) == ["", NAMED], rows)
        t.ok("the nameless one fills its own password, not the named one's", v == NAMELESS_PW, v)
        v, _ = filled(base, NAMED)
        t.ok("the named one fills its own", v == NAMED_PW, v)

        # (3) Saving the nameless one with a new password changes it alone.
        c = open_page(base, "/code")
        sv.ev(c, f"document.getElementById('p').value = '{NEW_PW}'; document.forms[0].requestSubmit(); true")
        time.sleep(3)
        r = acc()
        t.ok("a password box alone offers to update the nameless one",
             r.get("offer", {}).get("user") == "" and r["offer"].get("changed") is True, r)
        r = acc(keep=True)
        t.ok("updated, not added", r.get("kept") == 2 and not r.get("offer"), r)
        v, _ = filled(base, "")
        t.ok("the nameless one has the new password", v == NEW_PW, v)
        v, _ = filled(base, NAMED)
        t.ok("the named one keeps its own", v == NAMED_PW, v)

        # (4) Forgetting the nameless one leaves the named one.
        r = acc(forget="")
        t.ok("forgetting the nameless one leaves the named one", r.get("users") == [NAMED], r)
        v, _ = filled(base, NAMED)
        t.ok("…with its password", v == NAMED_PW, v)

        # (5) Forgetting the named one leaves the nameless one.
        r = seed(("", NAMELESS_PW))
        t.ok("the nameless one kept again", r.get("kept") == 1, r)
        r = acc(forget=NAMED)
        t.ok("forgetting the named one leaves the nameless one", r.get("users") == [""], r)
        v, _ = filled(base, "")
        t.ok("…with its password", v == NAMELESS_PW, v)
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's made-up logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's made-up logins forgotten", False, e)
        if os.path.exists(csv): os.remove(csv)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
