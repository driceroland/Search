#!/usr/bin/env python3
"""Sign-ins of unusual but common shapes offer the saved login on focus, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/login_shapes.py`. A work
sign-in page offered its saved login only through right-click › AutoFill
(idea 938). Local pages on 127.0.0.1:8842 stand in for the shapes such
pages take: no <form>, boxes a framework adds after load, odd names
(loginfmt, j_username, userid), autocomplete=off, a sign-up form ahead of
the sign-in, a hidden password box ahead of the real one, web components
(open shadow roots), a frame of the page's own, a <dialog> and a modal, a
password asked for in place after the name, a password box made on focus,
and type=text marked current-password. Each one's box, focused, has to hang
the saved account, and a pick has to fill the right boxes. A frame of
another site (localhost is not 127.0.0.1) gets nothing, and neither does a
search box or a new password's box.

One made-up account goes into this world's own keychain items (its label,
never the real browser's) through the CSV import, and is forgotten at the
end. No window is made or shown.
"""
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("login-shapes")

PORT = 8842
USER = "shape-user@example.test"
PASS = "shape-pass-1"

PAGES = {
    "/plain": '<form action="/done" method="post"><input id="u" name="username" type="text">'
              '<input id="p" name="password" type="password"><button>Sign in</button></form>',
    # Microsoft's names, no form at all, a div for a button, a search box above.
    "/noform": '<div role="search"><input id="q" type="search" placeholder="Search"></div>'
               '<div class="login"><input id="u" name="loginfmt" type="email">'
               '<input id="p" name="passwd" type="password"><div role="button" tabindex="0">Sign in</div></div>',
    # Built by the page's own script after it loads, as React or Angular do.
    "/late": '<div id="root">Loading…</div><script>setTimeout(function () {'
             'var r = document.getElementById("root"); r.textContent = "";'
             'var u = document.createElement("input"); u.id = "u"; u.name = "j_username"; r.appendChild(u);'
             'var p = document.createElement("input"); p.id = "p"; p.type = "password"; p.name = "j_password"; r.appendChild(p);'
             'var b = document.createElement("button"); b.textContent = "Log in"; r.appendChild(b);'
             '}, 900);</script>',
    "/acoff": '<form autocomplete="off" action="/done" method="post"><input id="u" name="userid" autocomplete="off">'
              '<input id="p" name="pw" type="password" autocomplete="off"><button>Sign in</button></form>',
    # A sign-up form ahead of the sign-in, its password box first on the page.
    "/signup-first": '<form id="up" action="/new" method="post"><h2>Create an account</h2>'
                     '<input id="nu" name="email" type="email" autocomplete="email">'
                     '<input id="np" name="password" type="password" autocomplete="new-password">'
                     '<button>Create account</button></form>'
                     '<form id="in" action="/done" method="post"><h2>Sign in</h2>'
                     '<input id="u" name="username" type="text"><input id="p" name="password" type="password">'
                     '<button>Sign in</button></form>',
    # A box kept out of sight ahead of the real one (a honeypot, or a
    # "remember me" helper).
    "/hidden-first": '<input type="password" name="trap" tabindex="-1" style="position:absolute;left:-10000px;width:10px">'
                     '<form action="/done" method="post"><input id="u" name="username" type="text">'
                     '<input id="p" name="password" type="password"><button>Sign in</button></form>',
    # A web component: the form inside its open shadow root.
    "/shadow": '<x-login></x-login><script>customElements.define("x-login", class extends HTMLElement {'
               'constructor() { super(); this.attachShadow({mode: "open"}).innerHTML ='
               '\'<form action="/done" method="post"><input id="u" name="username" type="text">'
               '<input id="p" name="password" type="password"><button>Sign in</button></form>\'; } });</script>',
    # A design system's inputs (UI5, Lightning): each box in a shadow root
    # of its own, in a form of the page's.
    "/shadow-split": '<form action="/done" method="post"><x-input kind="text" name="username" label="Username"></x-input>'
                     '<x-input kind="password" name="password" label="Password"></x-input><button>Sign in</button></form>'
                     '<script>customElements.define("x-input", class extends HTMLElement {'
                     'constructor() { super(); var s = this.attachShadow({mode: "open"});'
                     's.innerHTML = \'<input aria-label="\' + this.getAttribute("label") + \'" type="\' + this.getAttribute("kind") + \'">\'; } });</script>',
    "/frame-same": '<h1>Portal</h1><iframe src="/plain" style="width:400px;height:200px;margin:40px"></iframe>',
    "/frame-cross": f'<h1>Portal</h1><iframe src="http://localhost:{PORT}/plain-msg" style="width:400px;height:200px"></iframe>',
    "/plain-msg": '<form action="/done" method="post"><input id="u" name="username" type="text">'
                  '<input id="p" name="password" type="password"><button>Sign in</button></form>'
                  '<script>addEventListener("message", function (e) { document.getElementById(e.data).focus(); });</script>',
    "/dialog": '<button id="open" onclick="document.getElementById(\'d\').showModal()">Sign in</button>'
               '<dialog id="d"><form action="/done" method="post"><input id="u" name="username" type="text">'
               '<input id="p" name="password" type="password"><button>Sign in</button></form></dialog>',
    "/modal": '<input id="q" type="search" placeholder="Search">'
              '<div style="position:fixed;inset:0;background:rgba(0,0,0,.4)"><div role="dialog" aria-modal="true" '
              'style="margin:80px auto;width:320px;background:#fff"><input id="u" name="email" type="email" placeholder="Email">'
              '<input id="p" type="password" placeholder="Password"><button>Continue</button></div></div>',
    # Microsoft's in-place two steps: the name, then the password on the
    # same page, the name box hidden.
    "/twostep": '<form action="/done" method="post"><div id="one"><input id="u" name="loginfmt" type="email">'
                '<button type="button" id="next">Next</button></div>'
                '<div id="two" style="display:none"><input id="p" name="passwd" type="password"><button>Sign in</button></div></form>'
                '<script>document.getElementById("next").onclick = function () {'
                'document.getElementById("one").style.display = "none"; document.getElementById("two").style.display = ""; };</script>',
    # A box that only turns into a password box once focused.
    "/focus-swap": '<form action="/done" method="post"><input id="u" name="username" type="text">'
                   '<input id="p" name="password" type="text" placeholder="Password"><button>Sign in</button></form>'
                   '<script>document.getElementById("p").addEventListener("focus", function () { this.type = "password"; });</script>',
    # A text box drawn as dots, saying it takes the current password.
    "/text-current": '<form action="/done" method="post"><input id="u" name="username" type="text" autocomplete="username">'
                     '<input id="p" name="password" type="text" autocomplete="current-password" style="-webkit-text-security:disc">'
                     '<button>Sign in</button></form>',
    # The first step alone, with a name no hint explains.
    "/userid": '<form action="/step2"><input id="u" name="userid" type="text"><button>Next</button></form>',
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


def open_page(base, path, wait=1.2):
    tab = sv.sp("open", url=f"{base}{path}")["resultID"]
    sv.sp("select", id=tab); time.sleep(wait)
    return tab


def focus(tab, js):
    sv.ev(tab, f"var b = {js}; b.focus(); true"); time.sleep(0.8)
    return acc()


def offered(r): return bool(r.get("shown")) and any(x.get("login") == USER for x in r.get("rows", []))


def pick_fills(t, tab, name, user_js, pass_js):
    acc(pick=0); time.sleep(0.6)
    v = sv.ev(tab, f"[{user_js}.value, {pass_js}.value]")
    t.ok(f"{name}: a pick fills its name and password", v == [USER, PASS], v)


def blur(tab):
    sv.ev(tab, "document.activeElement && document.activeElement.blur(); true"); time.sleep(0.4)


def main():
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

        el = lambda id: f"document.getElementById('{id}')"

        # Plain, then the shapes whose boxes live in the page itself.
        for path, wait in [("/plain", 1.2), ("/noform", 1.2), ("/late", 2.2), ("/acoff", 1.2), ("/signup-first", 1.2),
                           ("/hidden-first", 1.2), ("/modal", 1.2), ("/text-current", 1.2)]:
            tab = open_page(base, path, wait)
            t.ok(f"{path}: the password box offers the saved login", offered(focus(tab, el("p"))), acc())
            blur(tab)
            t.ok(f"{path}: so does the name box", offered(focus(tab, el("u"))), acc())
            pick_fills(t, tab, path, el("u"), el("p"))
            if path == "/signup-first":
                v = sv.ev(tab, "[document.getElementById('nu').value, document.getElementById('np').value]")
                t.ok("/signup-first: the sign-up form stays empty", v == ["", ""], v)
                blur(tab)
                t.ok("/signup-first: the sign-up's email box offers nothing", not offered(focus(tab, el("nu"))), acc())
                blur(tab)
                t.ok("/signup-first: the sign-up's new password box offers nothing", not offered(focus(tab, el("np"))), acc())
                # Typed into the sign-in and sent: saved with its own name,
                # not the sign-up's empty password box above it.
                sv.ev(tab, "var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;"
                           "['u', 'p'].forEach(function (id, i) { var b = document.getElementById(id); b.focus();"
                           "set.call(b, i ? 'shape-pass-2' : %r); b.dispatchEvent(new Event('input', {bubbles: true})); });"
                           "document.getElementById('in').requestSubmit(); true" % USER)
                time.sleep(3)
                r = acc()
                t.ok("/signup-first: a password typed into the sign-in is offered under its name",
                     r.get("offer", {}).get("user") == USER and r["offer"].get("changed") is True, r)
            if path in ("/noform", "/modal"):
                blur(tab)
                t.ok(f"{path}: the search box offers nothing", not focus(tab, el("q")).get("shown"), acc())

        # A <dialog>, opened by a button.
        tab = open_page(base, "/dialog")
        sv.ev(tab, "document.getElementById('open').click(); true"); time.sleep(0.5)
        t.ok("/dialog: the password box offers the saved login", offered(focus(tab, el("p"))), acc())
        pick_fills(t, tab, "/dialog", el("u"), el("p"))

        # The password asked for in place, after the name.
        tab = open_page(base, "/twostep")
        t.ok("/twostep: the name box offers the saved login", offered(focus(tab, el("u"))), acc())
        sv.ev(tab, "document.getElementById('u').value = %r; document.getElementById('next').click(); true" % USER)
        time.sleep(0.5)
        t.ok("/twostep: the password box, shown in place, offers it", offered(focus(tab, el("p"))), acc())

        # A box turned into a password box on focus.
        tab = open_page(base, "/focus-swap")
        t.ok("/focus-swap: the box made a password box on focus offers it", offered(focus(tab, el("p"))), acc())

        # A first step with only a name.
        tab = open_page(base, "/userid")
        r = focus(tab, el("u"))
        t.ok("/userid: a first step named userid offers the name", offered(r) and r.get("nameOnly") is True, r)

        # Web components.
        tab = open_page(base, "/shadow")
        root = "document.querySelector('x-login').shadowRoot"
        t.ok("/shadow: the password box in an open shadow root offers it",
             offered(focus(tab, f"{root}.getElementById('p')")), acc())
        blur(tab)
        t.ok("/shadow: so does the name box", offered(focus(tab, f"{root}.getElementById('u')")), acc())
        pick_fills(t, tab, "/shadow", f"{root}.getElementById('u')", f"{root}.getElementById('p')")

        tab = open_page(base, "/shadow-split")
        box = lambda n: f"document.querySelectorAll('x-input')[{n}].shadowRoot.querySelector('input')"
        t.ok("/shadow-split: a password box in a shadow root of its own offers it", offered(focus(tab, box(1))), acc())
        blur(tab)
        t.ok("/shadow-split: so does the name box in another", offered(focus(tab, box(0))), acc())
        pick_fills(t, tab, "/shadow-split", box(0), box(1))

        # A frame of the page's own.
        tab = open_page(base, "/frame-same", 1.6)
        doc = "document.querySelector('iframe').contentDocument"
        r = focus(tab, f"{doc}.getElementById('p')")
        t.ok("/frame-same: the password box in a same-origin frame offers it", offered(r), r)
        spot = r.get("spot") or [0, 0, 0, 0]
        t.ok("/frame-same: the list hangs from the box where the frame puts it", spot[0] >= 40 and spot[1] >= 40, spot)
        blur(tab)
        t.ok("/frame-same: so does the name box", offered(focus(tab, f"{doc}.getElementById('u')")), acc())
        pick_fills(t, tab, "/frame-same", f"{doc}.getElementById('u')", f"{doc}.getElementById('p')")

        # A frame of another site: nothing of this one's.
        tab = open_page(base, "/frame-cross", 1.6)
        sv.ev(tab, "document.querySelector('iframe').contentWindow.postMessage('p', '*'); true"); time.sleep(0.8)
        t.ok("/frame-cross: a frame of another site is offered nothing", not offered(acc()), acc())
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
