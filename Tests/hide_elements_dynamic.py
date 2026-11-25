#!/usr/bin/env python3
"""Hide Elements on a page whose cards are built by script after it loads
(idea 1194): what was hidden stays hidden on a later visit, wherever it
lands, and nothing else is hidden in its place. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/hide_elements_dynamic.py`.
Same harness as hide_elements.py: started hidden, no window made or shown,
everything removed afterwards; the pointer's moves and presses are sent in
Search's own world, where the picker listens.

The pages, all built 200 ms after load, as a grocery site's list is:
  drive     a grid of products and a cart beside it; next visit the cart
            is built first (the reporter's case: a cart product went)
  shuffle   the same products, in another order and one more, next visit
  gone      the product picked isn't there on the next visit
  near      next visit, a product of almost the same name in its place
  ids       cards that carry their own product id
  legacy    a rule saved by 1.0.21 and before, still worn
  promos    ⌥-click: every card like it goes, and more of them next visit
            (idea 1195)
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hide-dynamic")

PRODUCTS = ["Lait demi-écrémé Lactel 1L", "Beurre doux Président 250g", "Pâtes Barilla 500g",
            "Café moulu Carte Noire 250g", "Yaourt nature x8"]
CART = ["Pommes Golden 1kg", "Jus d'orange 1L", "Riz basmati 1kg", "Œufs x12",
        "Farine T55 1kg", "Sucre 1kg", "Thé vert x20"]


def card(name, price, button, pid=None, kind="card"):
    data = f" data-product-id='{pid}'" if pid else ""
    return (f"<div class='{kind}'{data} style='padding:14px;margin:6px;width:220px;height:90px;background:#eee'>"
            f"<h3>{name}</h3><span>{price} €</span> <button>{button}</button></div>")


def grid(order, ids=False):
    return "<div class=grid style='display:flex;flex-wrap:wrap'>" + "".join(
        card(PRODUCTS[i], f"{i + 1},05", "Ajouter", 9000 + i if ids else None) for i in order) + "</div>"


def cart():
    return "<div class=cart style='display:flex;flex-wrap:wrap'>" + "".join(card(n, f"{i + 2},30", "Retirer") for i, n in enumerate(CART)) + "</div>"


# What #app is built from, by page and by visit (the first, then any later).
LAYOUTS = {
    "drive": (lambda: grid([0, 1, 2, 3]) + cart(), lambda: cart() + grid([0, 1, 2, 3])),
    "shuffle": (lambda: grid([0, 1, 2, 3]), lambda: grid([4, 3, 0, 1, 2])),
    "gone": (lambda: grid([0, 1, 2, 3]), lambda: grid([0, 1, 3, 4])),
    "near": (lambda: grid([0, 1, 2, 3]),
             lambda: grid([0, 1, 2, 3]).replace(PRODUCTS[2], "Pâtes Panzani 500g").replace("3,05", "2,15")),
    "promos": (lambda: "<div class=grid>" + "".join(
                   card(n, "1,00", "Ajouter", kind="card promo" if i % 2 else "card") for i, n in enumerate(PRODUCTS))
               + "<p id=plain style='height:30px'>Livraison offerte</p></div>",
               lambda: "<div class=grid>" + "".join(
                   card(n, "1,00", "Ajouter", kind="card promo" if i % 2 == 0 else "card") for i, n in enumerate(PRODUCTS))
               + "</div>"),
    "ids": (lambda: grid([0, 1, 2, 3], ids=True), lambda: cart() + grid([3, 2, 1, 0], ids=True)),
}
visits = {}


def built(name):
    first, later = LAYOUTS[name]
    n = visits.get(name, 0)
    visits[name] = n + 1
    html = (first if n == 0 else later)()
    return ("<div id=app><p>Chargement…</p></div><script>setTimeout(function () {"
            f"document.getElementById('app').innerHTML = {json.dumps(html)}; }}, 200)</script>")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        if name in LAYOUTS:
            html = built(name)
        elif name == "legacy":
            html = "<div id=legacy style='height:40px'>Old rule</div><div class=promo>Kept</div>"
        else:
            html = "<p>nothing"
        body = f"<!doctype html><meta charset=utf-8><title>{name}</title>{html}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
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


# The pointer coming to rest on the corner of the card whose title is
# `title` (where none of its children are), as the picker reads a move.
POINT = """(function () {
  var el = [...document.querySelectorAll('.card')].find(c => c.querySelector('h3').textContent === %s);
  el.scrollIntoView({block: 'center'});
  var r = el.getBoundingClientRect(), x = r.right - 3, y = r.bottom - 3;
  window.__probeAt = [x, y];
  document.dispatchEvent(new MouseEvent('mousemove', {clientX: x, clientY: y, bubbles: true}));
  var under = document.elementFromPoint(x, y);
  return under === el;
})()"""
PRESS = """(function () {
  var at = window.__probeAt, under = document.elementFromPoint(at[0], at[1]);
  var e = new PointerEvent('pointerdown', {clientX: at[0], clientY: at[1], bubbles: true, cancelable: true});
  under.dispatchEvent(e);
  return e.defaultPrevented;
})()"""
GONE = ("[...document.querySelectorAll('.card')].filter(e => getComputedStyle(e).display === 'none')"
        ".map(e => e.querySelector('h3').textContent).join('|')")


def kept():
    time.sleep(0.8)  # hidden.json is written a moment after the change
    try:
        return json.load(open(f"{sv.SUPPORT}/hidden.json")).get("127.0.0.1", [])
    except (OSError, ValueError):
        return []


def pick(tab, title):
    hiding(True)
    over = ev(tab, POINT % json.dumps(title), world="search")
    ev(tab, PRESS, world="search")
    time.sleep(0.8)
    hiding(False)
    return over


def reload(tab):
    ev(tab, "location.reload()")
    time.sleep(1.5)


def built_later(name, title, expect):
    """One page in a world of its own: the pages share a site, and what
    is hidden on one is hidden on all."""
    def case(t):
        sv.setup(sidebar=True); sv.launch()
        tab = open_page(name)
        t.ok(f"{name}: the pointer is on the card", pick(tab, title) is True)
        t.ok(f"{name}: gone at once", ev(tab, GONE) == title, ev(tab, GONE))
        t.ok(f"{name}: said so", state()["announced"].startswith("Hidden"), state()["announced"])
        reload(tab)
        t.ok(f"{name}: next visit, {expect or 'nothing'} hidden and nothing else", ev(tab, GONE) == expect, ev(tab, GONE))
        reload(tab)
        t.ok(f"{name}: and the visit after", ev(tab, GONE) == expect, ev(tab, GONE))
        print("    kept:", [v["selector"] for v in kept()])
    case.__name__ = f"case_{name}"
    case.__doc__ = f"{name}: a product picked on a page built after load, then the page built otherwise"
    return case


def case_all_like_it(t):
    """⌥-click: every card like the one picked, counted first, and new ones on later visits (idea 1195)"""
    sv.setup(sidebar=True); sv.launch()
    tab = open_page("promos")
    hiding(True)
    ev(tab, POINT % json.dumps(PRODUCTS[1]), world="search")
    # ⌥ goes down while the pointer rests there: the outline counts them.
    ev(tab, "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Alt', altKey: true, bubbles: true}))", world="search")
    said = ev(tab, "document.documentElement.lastElementChild.textContent", world="search")
    t.ok("with ⌥ the outline says how many", said.endswith("all 2 like it"), said)
    ev(tab, PRESS.replace("cancelable: true", "cancelable: true, altKey: true"), world="search")
    time.sleep(0.8)
    hiding(False)
    t.ok("every promo goes, and only those", ev(tab, GONE) == f"{PRODUCTS[1]}|{PRODUCTS[3]}", ev(tab, GONE))
    t.ok("said so", state()["announced"].startswith("Hidden"), state()["announced"])
    t.ok("one line in the list, a pattern", [v["selector"] for v in kept()] == ["div.card.promo"], kept())
    reload(tab)
    t.ok("next visit, the new promos go too", ev(tab, GONE) == f"{PRODUCTS[0]}|{PRODUCTS[2]}|{PRODUCTS[4]}", ev(tab, GONE))
    # Nothing else like it: said, and nothing hidden or kept.
    reload(tab)
    hiding(True)
    ev(tab, "window.__probeAt = (function () { var r = document.querySelector('.grid').getBoundingClientRect();"
            " return [r.right - 2, r.bottom - 2]; })()", world="search")
    ev(tab, PRESS.replace("cancelable: true", "cancelable: true, altKey: true"), world="search")
    time.sleep(0.8)
    hiding(False)
    t.ok("⌥ on a thing with nothing like it: said", "nothing else here looks like it" in state()["announced"], state()["announced"])
    t.ok("and nothing more kept", len(kept()) == 1, kept())


def case_legacy(t):
    """a rule saved before (a selector alone) is still worn"""
    sv.setup(sidebar=True)
    import os
    os.makedirs(sv.SUPPORT, exist_ok=True)
    json.dump({"127.0.0.1": [{"selector": "#legacy", "label": "Old", "date": 0}]}, open(f"{sv.SUPPORT}/hidden.json", "w"))
    sv.launch()
    tab = open_page("legacy")
    t.ok("the old rule hides its element",
         ev(tab, "getComputedStyle(document.getElementById('legacy')).display") == "none")
    t.ok("and nothing else", ev(tab, "getComputedStyle(document.querySelector('.promo')).display") == "block")


def main():
    cases = [built_later("drive", PRODUCTS[2], PRODUCTS[2]),     # the cart now comes first
             built_later("shuffle", PRODUCTS[2], PRODUCTS[2]),   # the grid in another order
             built_later("gone", PRODUCTS[2], ""),               # not there at all
             built_later("near", PRODUCTS[2], ""),               # another product where it was
             built_later("ids", PRODUCTS[2], PRODUCTS[2]),       # cards that carry an id
             case_all_like_it,
             case_legacy]
    only = sys.argv[1:]
    for case in cases:
        if only and case.__name__ not in only:
            continue
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
