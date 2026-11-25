#!/usr/bin/env python3
"""Hide Elements in a site's pop-up window (idea 1142): what is hidden on a
site leaves every open page of it at once, a sized pop-up window's and
another tab's included, not only the page it was picked on; and a pop-up
opened after it starts without it. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/hide_elements_popup.py`.
Started hidden in a world of its own; the pop-up's window is the probe's,
never shown or brought forward; everything is removed afterwards.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hide-popup")

BANNER = ("<div id=banner class=promo style='position:fixed;left:0;right:0;bottom:0;height:120px;"
          "background:#fc0'><p>Promo</p><button>OK</button></div>")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/opener":
            body = ("<button id=sized onclick=\"popup=window.open('/child','_blank','width=420,height=360')\">open</button>"
                    + BANNER)
        else:
            body = "<h1>child</h1>" + BANNER
        data = f"<!doctype html><meta charset=utf-8><title>{path}</title>{body}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H

POINT = """(function () {
  var el = document.querySelector('#banner'), r = el.getBoundingClientRect();
  var x = r.right - 3, y = r.bottom - 3;
  window.__probeAt = [x, y];
  document.dispatchEvent(new MouseEvent('mousemove', {clientX: x, clientY: y, bubbles: true}));
  return true;
})()"""
PRESS = """(function () {
  var at = window.__probeAt, under = document.elementFromPoint(at[0], at[1]);
  var e = new PointerEvent('pointerdown', {clientX: at[0], clientY: at[1], bubbles: true, cancelable: true});
  under.dispatchEvent(e);
  return e.defaultPrevented;
})()"""
SHOWN = "(function () { var el = document.querySelector('#banner'); return el ? getComputedStyle(el).display : 'missing'; })()"


def windows(): return sv.cmd({"do": "windows"})["windows"]
def tabs(window=1): return sv.cmd({"do": "tabs", "window": window})["tabs"]
def ev(tab, js, window=1, world=None, little=False):
    req = {"do": "eval", "id": tab or "", "js": js, "window": window}
    if little:
        req["little"] = True
    if world:
        req["world"] = world
    return sv.cmd(req).get("value")


def tap(tab, selector, window=1):
    sv.cmd({"do": "select", "id": tab, "window": window}); time.sleep(0.2)
    sv.cmd({"do": "tap", "id": tab, "selector": selector, "window": window}); time.sleep(1.2)


def child(window):
    return next(t for t in tabs(window) if urlparse(t["url"]).path == "/child")["id"]


def kept():
    time.sleep(0.8)
    try:
        return [v["selector"] for v in json.load(open(f"{sv.SUPPORT}/hidden.json")).get("127.0.0.1", [])]
    except (OSError, ValueError):
        return []


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.popupWindows": True}); sv.launch()
        page = sv.page("opener"); time.sleep(0.8)
        other = sv.page("child"); time.sleep(0.8)
        sv.cmd({"do": "select", "id": page}); time.sleep(0.3)
        tap(page, "#sized")
        ws = windows()
        t.ok("a sized pop-up has its own window", len(ws) == 2, ws)
        if len(ws) != 2:
            return 1
        small = child(2)
        t.ok("before: the banner shows in the pop-up", ev(small, SHOWN, 2) == "block")
        # Picked on the opener, in window 1.
        sv.cmd({"do": "select", "id": page}); time.sleep(0.3)
        sv.cmd({"do": "ui", "hiding": True}); time.sleep(0.3)
        ev(page, POINT, world="search")
        ev(page, PRESS, world="search"); time.sleep(0.8)
        sv.cmd({"do": "ui", "hiding": False}); time.sleep(0.5)
        t.ok("kept for the site", kept() != [], kept())
        t.ok("gone from the page it was picked on", ev(page, SHOWN) == "none", ev(page, SHOWN))
        t.ok("gone from the open pop-up window at once", ev(small, SHOWN, 2) == "none", ev(small, SHOWN, 2))
        t.ok("gone from another open tab of the site at once", ev(other, SHOWN) == "none", ev(other, SHOWN))
        sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(0.5)
        tap(page, "#sized")
        small = child(2)
        t.ok("a pop-up opened after starts without it", ev(small, SHOWN, 2) == "none", ev(small, SHOWN, 2))
        sv.cmd({"do": "windows", "action": "close", "n": 2})

        # A small window (a link from another app, Open in Small Window):
        # the report's own case. Its page is in no row.
        sv.cmd({"do": "little", "what": f"{sv.BASE}/child"}); time.sleep(2)
        t.ok("a small window's page starts without it",
             ev(None, SHOWN, little=True) == "none", ev(None, SHOWN, little=True))
        # Put back on the opener while the small window is open, then hidden again.
        sv.cmd({"do": "select", "id": page}); time.sleep(0.3)
        sv.cmd({"do": "ui", "hiding": True}); time.sleep(0.3)
        sv.cmd({"do": "press", "code": 6, "chars": "z", "mods": ["cmd"]}); time.sleep(0.8)
        sv.cmd({"do": "ui", "hiding": False}); time.sleep(0.5)
        t.ok("put back (⌘Z): kept no more", kept() == [], kept())
        t.ok("put back in the open small window at once",
             ev(None, SHOWN, little=True) == "block", ev(None, SHOWN, little=True))
        sv.cmd({"do": "little", "what": "close"})
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
