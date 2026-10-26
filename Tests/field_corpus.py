#!/usr/bin/env python3
"""Which boxes saved accounts are offered in (#631), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/field_corpus.py`. Every form
in Tests/FieldFixtures (Google Cloud's new project, GitHub's new repository,
Slack's message box, Google's and impots.gouv.fr's first steps, Okta, a
newsletter, a checkout…) is served from a local server at the path it was
taken from, on 127.0.0.1. A made-up account goes into this world's own
keychain items (its label, never the real browser's). A real sign-in box
is offered it with the site's other hosts' accounts (`wide`); a box that
only might be one, with this host's alone; anything else, nothing. Which
other hosts are the same site is FormFieldCorpusTests' to check: local
hosts share no registrable domain. The account is forgotten at the end; no
window is made or shown.
"""
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sec-fld-corpus")

PORT = 8836
HERE = "127.0.0.1"
MINE = "fld-here@example.test"
FIXTURES = Path(__file__).resolve().parent / "FieldFixtures"


def corpus():
    out = []
    for f in sorted(FIXTURES.glob("*.html")):
        text = f.read_text()
        head = text.split("\n", 1)[0]
        field = lambda k: head.split(k + ": ", 1)[1].split()[0] if k + ": " in head else None
        out.append({"file": f.stem, "path": urlsplit(field("url")).path or "/", "expect": field("expect"),
                    "name": field("name"), "html": text})
    return out


PAGES = {c["file"]: c for c in corpus()}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = PAGES.get((parse_qs(urlsplit(self.path).query).get("f") or [""])[0])
        body = (page["html"] if page else "<!doctype html><p>nothing</p>").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.do_GET()

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def offered(host, c):
    tab = sv.sp("open", url=f"http://{host}:{PORT}{c['path']}?f={c['file']}")["resultID"]
    sv.sp("select", id=tab); time.sleep(1.0)
    sv.ev(tab, "var el = document.querySelector('[data-probe]'); el.focus(); true"); time.sleep(0.8)
    r = acc()
    sv.ev(tab, "document.activeElement && document.activeElement.blur(); true"); time.sleep(0.3)
    sv.sp("close", id=tab)
    return r


def main():
    t = sv.T()
    srv = ThreadingHTTPServer((HERE, PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    csv = f"{sv.SUPPORT}-seed.csv"
    try:
        sv.setup(); sv.launch()
        with open(csv, "w") as f:
            f.write(f"url,username,password\nhttp://{HERE}:{PORT}/,{MINE},fld-pass-here\n")
        r = sv.cmd({"do": "import-file", "path": csv})
        t.ok("a made-up account in this world's keychain items", r.get("kept") == 1, r)

        for c in PAGES.values():
            r = offered(HERE, c)
            users = {x.get("login") for x in r.get("rows", [])}
            if c["expect"] == "none":
                t.ok(f"{c['file']}: no accounts", r.get("shown") is False, r)
                continue
            wide = c["expect"] == "wide"
            t.ok(f"{c['file']}: {'the site' if wide else 'this host alone'}'s accounts",
                 r.get("shown") is True and users == {MINE} and r.get("wide") is wide, r)
            if c["name"]:
                t.ok(f"{c['file']}: a pick puts in the name alone? {c['name']}",
                     r.get("nameOnly") is (c["name"] == "true"), r)

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
