#!/usr/bin/env python3
"""Hide Elements (⇧⌘H, Curtain.swift): what Search says is hidden is gone
from the page, and stays gone after a reload (#1270). In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/hide_elements.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards. Pointing is turned on as ⇧⌘H turns it
(`ui hiding`); the pointer's moves, presses and ↑ ↓ are the events the page
gets from them, sent in Search's own world where the picker listens. That
the outline is drawn round the right thing is looked at by hand on a
release candidate.

The pages, each with a banner of its own, all on one site:
  plain       nothing in the way
  csp-self    a policy that refuses inline styles (style-src 'self')
  csp-nonce   one that lets only its own nonce'd styles in
  outranked   the page's own !important rule, more particular than ours
  inline      the page's own style="display: block !important"
  inner       a pick on the banner's words, then ↑ to the banner
  left        pointing on, then left for another page and come back to
  one, many   a promo and a dialog picked on one, and on many, more like them
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# A world of its own (see use()).
sv.use("hide-elements")


def banner(name, style=""):
    return (f"<div id=banner-{name} class=cookie-banner style='position:fixed;left:0;right:0;bottom:0;"
            f"height:120px;background:#fc0;{style}'><p id=words-{name}>We use cookies</p><button>OK</button></div>")


PAGES = {
    "plain": ({}, banner("plain")),
    "csp-self": ({"Content-Security-Policy": "style-src 'self'"}, banner("csp-self")),
    "csp-nonce": ({"Content-Security-Policy": "style-src 'nonce-abc'"},
                  "<style nonce=abc>p { color: #333 }</style>" + banner("csp-nonce")),
    "outranked": ({}, "<style>#page #wrap div#banner-outranked.cookie-banner { display: block !important }</style>"
                  "<div id=page><div id=wrap>" + banner("outranked") + "</div></div>"),
    "inline": ({}, banner("inline", "display: block !important")),
    "inner": ({}, banner("inner")),
    "left": ({}, banner("left")),
    "elsewhere": ({}, "<p>elsewhere"),
    # One of a kind on the first visit, one of several on the next (idea 1133).
    "one": ({}, "<div id=feed><div class=promo style='height:40px'>Ad A</div><p>post</div>"
                "<div role=dialog style='height:40px'>Sign up</div>"),
    "many": ({}, "<div id=feed><div class=promo style='height:40px'>Ad A</div><p>post"
                 "<div class=promo>Ad B</div><div class=promo>Ad C</div></div>"
                 "<div role=dialog style='height:40px'>Sign up</div><div role=dialog>Other</div>"),
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        headers, html = PAGES.get(self.path.strip("/"), ({}, "<p>nothing"))
        body = f"<!doctype html><title>{self.path.strip('/')}</title>{html}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

t = sv.T()


def ev(tab, js, world=None):
    req = {"do": "eval", "id": tab, "js": js}
    if world:
        req["world"] = world
    return sv.cmd(req).get("value")


def state(): return sv.sp("state")
def hiding(on): sv.cmd({"do": "ui", "hiding": on}); time.sleep(0.3)


def open_page(name):
    tab = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    time.sleep(1.5)
    return tab


# The pointer coming to rest over `sel` (on its corner, for the banner
# itself, where none of its children are), as the picker reads a move.
POINT = """(function () {
  var el = document.querySelector(%s), r = el.getBoundingClientRect(), corner = el.tagName === 'DIV';
  var x = corner ? r.right - 3 : r.left + r.width / 2, y = corner ? r.bottom - 3 : r.top + r.height / 2;
  window.__probeAt = [x, y];
  document.dispatchEvent(new MouseEvent('mousemove', {clientX: x, clientY: y, bubbles: true}));
  var under = document.elementFromPoint(x, y);
  return under && under.id;
})()"""
PRESS = """(function () {
  var at = window.__probeAt, under = document.elementFromPoint(at[0], at[1]);
  var e = new PointerEvent('pointerdown', {clientX: at[0], clientY: at[1], bubbles: true, cancelable: true});
  under.dispatchEvent(e);
  return e.defaultPrevented;
})()"""
KEY = """(function () {
  var e = new KeyboardEvent('keydown', {key: %s, bubbles: true, cancelable: true});
  document.dispatchEvent(e);
  return e.defaultPrevented;
})()"""


def shown(tab, sel):
    return ev(tab, f"(function () {{ var el = document.querySelector({json.dumps(sel)}); "
                   "return el ? getComputedStyle(el).display : 'missing'; })()")


def kept():
    time.sleep(0.8)  # hidden.json is written a moment after the change
    try:
        return [v["selector"] for v in json.load(open(f"{sv.SUPPORT}/hidden.json")).get("127.0.0.1", [])]
    except (OSError, ValueError):
        return []


def pick(tab, sel):
    hiding(True)
    ev(tab, POINT % json.dumps(sel), world="search")
    swallowed = ev(tab, PRESS, world="search")
    time.sleep(0.8)
    hiding(False)
    return swallowed


def case_hidden(t):
    """a banner picked is gone, and still gone after a reload, whatever the page's policy"""
    sv.setup(sidebar=True); sv.launch()
    for name in ["plain", "csp-self", "csp-nonce", "outranked"]:
        tab = open_page(name)
        sel = f"#banner-{name}"
        t.ok(f"{name}: the press is the picker's, not the page's", pick(tab, sel) is True)
        t.ok(f"{name}: gone", shown(tab, sel) == "none", shown(tab, sel))
        t.ok(f"{name}: said so", state()["announced"].startswith("Hidden"), state()["announced"])
        ev(tab, "location.reload()"); time.sleep(1.5)
        t.ok(f"{name}: still gone after a reload", shown(tab, sel) == "none", shown(tab, sel))
    t.ok("all four are listed", all(f"#banner-{n}" in kept() for n in ["plain", "csp-self", "csp-nonce", "outranked"]), kept())


def case_kept_on_screen(t):
    """a page that keeps it there with its own inline !important: told so, nothing listed"""
    sv.setup(sidebar=True); sv.launch()
    tab = open_page("inline")
    pick(tab, "#banner-inline")
    t.ok("still on screen", shown(tab, "#banner-inline") == "block", shown(tab, "#banner-inline"))
    t.ok("not said to be hidden", state()["announced"].startswith("The page keeps that on screen"), state()["announced"])
    t.ok("not listed", "#banner-inline" not in kept(), kept())


def case_wider(t):
    """↑ from the banner's words takes the banner, ↓ comes back in"""
    sv.setup(sidebar=True); sv.launch()
    tab = open_page("inner")
    hiding(True)
    t.ok("the pointer is over the words", ev(tab, POINT % json.dumps("#words-inner"), world="search") == "words-inner")
    t.ok("↑ is the picker's, not the page's", ev(tab, KEY % json.dumps("ArrowUp"), world="search") is True)
    t.ok("↓ is too", ev(tab, KEY % json.dumps("ArrowDown"), world="search") is True)
    ev(tab, KEY % json.dumps("ArrowUp"), world="search")
    # Moving within the words keeps the wider choice.
    ev(tab, POINT % json.dumps("#words-inner"), world="search")
    ev(tab, PRESS, world="search"); time.sleep(0.8)
    hiding(False)
    t.ok("the banner is gone, not only its words", shown(tab, "#banner-inner") == "none", shown(tab, "#banner-inner"))
    t.ok("the banner is what is listed", kept() == ["#banner-inner"], kept())
    hiding(True)
    t.ok("other keys are the page's", ev(tab, KEY % json.dumps("a"), world="search") is False)
    hiding(False)


def case_left(t):
    """pointing ends with the page: a reload, or going elsewhere and Back"""
    sv.setup(sidebar=True); sv.launch()
    tab = open_page("left")
    hiding(True)
    t.ok("pointing", state()["veiling"] is True)
    ev(tab, "location.reload()"); time.sleep(1.5)
    t.ok("a reload ends it", state()["veiling"] is False, state()["veiling"])
    hiding(True)
    t.ok("⇧⌘H starts it again, at the first press", state()["veiling"] is True and
         ev(tab, "document.documentElement.style.cursor") == "crosshair")
    ev(tab, f"location.href = {json.dumps(BASE + '/elsewhere')}"); time.sleep(1.5)
    t.ok("going elsewhere ends it", state()["veiling"] is False, state()["veiling"])
    ev(tab, "history.back()"); time.sleep(1.5)
    t.ok("back on the page", ev(tab, "location.pathname") == "/left", ev(tab, "location.pathname"))
    ev(tab, POINT % json.dumps("#banner-left"), world="search")
    t.ok("back, its clicks are its own again", ev(tab, PRESS, world="search") is False)
    t.ok("and the pointer is its own", ev(tab, "document.documentElement.style.cursor") == "")


def case_one_of_many(t):
    """what was picked is that one thing: on a later visit with more like it, only it goes (idea 1133)"""
    sv.setup(sidebar=True); sv.launch()
    tab = open_page("one")
    # From the list, as its Hide something… starts it.
    sv.cmd({"do": "ui", "hidden": True}); time.sleep(0.5)
    pick(tab, "#feed > .promo")
    sv.cmd({"do": "ui", "hidden": True}); time.sleep(0.5)
    pick(tab, "[role=dialog]")
    names = kept()
    t.ok("each selector names one element now", len(names) == 2 and all(
        ev(tab, f"document.querySelectorAll({json.dumps(n)}).length") == 1 for n in names), names)
    ev(tab, f"location.href = {json.dumps(BASE + '/many')}"); time.sleep(1.5)
    gone = ev(tab, "[...document.querySelectorAll('body *')].filter(e => getComputedStyle(e).display === 'none')"
                   ".map(e => e.textContent.trim()).join('|')")
    t.ok("on the next visit, only those two go", gone == "Ad A|Sign up", gone)


def main():
    for case in [case_hidden, case_kept_on_screen, case_wider, case_left, case_one_of_many]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
