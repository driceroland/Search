#!/usr/bin/env python3
"""A plain "Email + Password" sign-in offers the saved login on focus, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/login_email_shapes.py`. A
work site's sign-in, an "Email" box, a "Password" box and a Login button,
offered nothing on focus (idea 1031). Local pages on 127.0.0.1:8851 take
the shapes such pages come in: type=email or type=text name=username,
autocomplete missing or off, in a form or not, the boxes added late by a
script, an SPA with no <form> whose boxes have no name at all and say what
they take only in a label or a placeholder, web components, and a frame of
the page's own. Each box, focused, has to hang the saved account; a search
box and a newsletter's email box on the same pages get nothing.

One made-up account goes into this world's own keychain items through the
CSV import, and is forgotten at the end. No window is made or shown.
"""
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("login-email")

PORT = 8851
USER = "email-user@example.test"
PASS = "email-pass-1"

BTN = '<button id="go">Login</button>'
# A newsletter's email box and a search box, on the page beside the sign-in.
ASIDE = ('<input id="q" type="search" placeholder="Search">'
         '<form id="news" action="/newsletter"><input id="nl" type="email" placeholder="Your email">'
         '<button>Subscribe</button></form>')


def late(build, ms=900):
    return f'<div id="root">Loading…</div><script>setTimeout(function () {{ var r = document.getElementById("root"); r.innerHTML = {build!r}; }}, {ms});</script>'


SHAPES = {
    "/email": f'<form action="/login" method="post"><label for="u">Email</label><input id="u" name="email" type="email">'
              f'<label for="p">Password</label><input id="p" name="password" type="password">{BTN}</form>',
    "/username": f'<form action="/login" method="post"><input id="u" name="username" type="text">'
                 f'<input id="p" name="password" type="password">{BTN}</form>',
    "/acoff": f'<form autocomplete="off" action="/login" method="post"><input id="u" name="email" type="email" autocomplete="off">'
              f'<input id="p" name="password" type="password" autocomplete="off">{BTN}</form>',
    "/noform": f'<div class="login"><label for="u">Email</label><input id="u" type="email">'
               f'<label for="p">Password</label><input id="p" type="password">{BTN}</div>',
    # An SPA's boxes: no form, no name, no id to go by; what they take is
    # said in a label beside them (not a <label>) or a placeholder.
    "/spa": late('<div class="field"><div class="lbl">Email</div><input class="in" id="u"></div>'
                 '<div class="field"><div class="lbl">Password</div><input class="in" id="p" type="password"></div>'
                 '<div role="button" tabindex="0">Login</div>'),
    "/spa-placeholder": late('<input id="u" placeholder="Email"><input id="p" type="password" placeholder="Password">'
                             '<button type="button">Login</button>'),
    "/spa-text-noname": late('<form onsubmit="return false"><input id="u" type="text"><input id="p" type="password">'
                             '<button>Login</button></form>'),
    "/late-email": late('<form action="/login" method="post"><input id="u" name="email" type="email">'
                        '<input id="p" name="password" type="password"><button>Login</button></form>', 1500),
    "/shadow": '<x-login></x-login><script>customElements.define("x-login", class extends HTMLElement {'
               'constructor() { super(); this.attachShadow({mode: "open"}).innerHTML ='
               '\'<form><label>Email<input id="u" type="email"></label><label>Password<input id="p" type="password"></label>'
               '<button>Login</button></form>\'; } });</script>',
    "/frame": '<h1>Portal</h1><iframe src="/email" style="width:420px;height:220px;margin:30px"></iframe>',
    "/with-aside": ASIDE + '<div class="login"><input id="u" type="email" placeholder="Email">'
                   '<input id="p" type="password" placeholder="Password"><button type="button">Login</button></div>',
}


class H(BaseHTTPRequestHandler):
    def page(self):
        path = self.path.split("?")[0]
        inner = SHAPES.get(path, f"<p>{path}</p>")
        body = f"<!doctype html><title>{path.strip('/')}</title>{inner}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self): self.page()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.page()

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def offered(r): return bool(r.get("shown")) and any(x.get("login") == USER for x in r.get("rows", []))


def main():
    only = set(sys.argv[1:])
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    csv = f"{sv.SUPPORT}-seed.csv"
    try:
        sv.setup(); sv.launch()
        with open(csv, "w") as f:
            f.write(f"url,username,password\n{base}/,{USER},{PASS}\n")
        r = sv.cmd({"do": "import-file", "path": csv})
        t.ok("one made-up account in this world's keychain items", r.get("kept") == 1, r)

        def doc(path):
            if path == "/frame": return "document.querySelector('iframe').contentDocument"
            if path == "/shadow": return "document.querySelector('x-login').shadowRoot"
            return "document"

        for path in SHAPES:
            if only and path not in only: continue
            tab = sv.sp("open", url=base + path)["resultID"]
            sv.sp("select", id=tab)
            time.sleep(2.4 if path.startswith(("/spa", "/late")) or path == "/frame" else 1.2)
            d = doc(path)
            box = lambda id: f"{d}.querySelector('#{id}')"
            for which in ("u", "p"):
                sv.ev(tab, "document.activeElement && document.activeElement.blur(); true"); time.sleep(0.3)
                sv.ev(tab, f"{box(which)}.focus(); true"); time.sleep(0.8)
                r = acc()
                t.ok(f"{path}: the {'email/name' if which == 'u' else 'password'} box offers the saved login", offered(r), r)
            acc(pick=0); time.sleep(0.6)
            v = sv.ev(tab, f"[{box('u')}.value, {box('p')}.value]")
            t.ok(f"{path}: a pick fills both", v == [USER, PASS], v)
            if path == "/with-aside":
                for id in ("q", "nl"):
                    sv.ev(tab, "document.activeElement.blur(); true"); time.sleep(0.3)
                    sv.ev(tab, f"document.getElementById('{id}').focus(); true"); time.sleep(0.8)
                    t.ok(f"/with-aside: #{id} offers nothing", not acc().get("shown"), acc())
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's made-up account forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's made-up account forgotten", False, e)
        if os.path.exists(csv): os.remove(csv)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
