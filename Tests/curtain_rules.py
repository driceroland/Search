#!/usr/bin/env python3
"""What you hide stays hidden through WebKit's compiled rule list.

Build first (`./build.sh`), then `python3 Tests/curtain_rules.py`. It uses
the split suite's harness: started hidden, no window made or shown,
everything removed afterwards.

A hide goes on the page at once through the stylesheet, and on later loads
through the compiled list, so a page that loads with the list has no
stylesheet of hidden things at all, and a page that writes its document
again can't take the hide with it. The list keeps to this exact site and
to the page itself, never its frames, as the stylesheet did, and putting a
thing back or peeking at it from the list shows it on the page that's up.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("curtain-rules")
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/frame"):
            body = b"<!doctype html><div id=bar>framed bar</div>"
        else:
            body = (b"<!doctype html><title>page</title><div id=bar>bar</div>"
                    b"<div class=ad>ad</div><iframe id=f src='/frame'></iframe>")
        if "rewrite" in self.path:
            # A page that writes its whole document again once it's up.
            body += (b"<script>addEventListener('load', function () { setTimeout(function () {"
                     b"document.documentElement.innerHTML = '<head></head><body><div id=bar>bar</div></body>';"
                     b"document.title = 'rewritten'; }, 300) })</script>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
HERE = f"http://127.0.0.1:{srv.server_port}/page"
OTHER = f"http://localhost:{srv.server_port}/page"


def shown(id, sel):
    return sv.ev(id, f"getComputedStyle(document.querySelector('{sel}')).display")


def framed(id):
    return sv.ev(id, "getComputedStyle(document.getElementById('f').contentDocument"
                     ".getElementById('bar')).display")


def sheet(id):
    """The stylesheet of hidden things, if the page has one, else None."""
    return sv.ev(id, "(document.getElementById('office-veil') || {}).textContent || null")


def hide(id, selector):
    # What the pointer sends when it picks something (see Veiling.picker).
    sv.cmd({"do": "eval", "id": id, "world": "search",
            "js": f"window.webkit.messageHandlers.officeVeil.postMessage("
                  f"{{selector: '{selector}', label: 'it', note: ''}}); 1"})
    time.sleep(0.3)


def veils(**f):
    return sv.cmd({"do": "veils", **f})


def compiled(within=5):
    end = time.time() + within
    while time.time() < end:
        if veils()["loading"] == "":
            return True
        time.sleep(0.1)
    return False


def go(id, url):
    sv.cmd({"do": "go", "id": id, "url": url})
    time.sleep(1)


try:
    sv.setup()
    sv.launch()
    a = sv.sp("open", url=HERE)["resultID"]
    sv.sp("select", id=a)
    time.sleep(1)

    t.ok("nothing is hidden to begin with", shown(a, "#bar") == "block", shown(a, "#bar"))
    hide(a, "#bar")
    t.ok("a hide goes on the page at once", shown(a, "#bar") == "none", shown(a, "#bar"))
    t.ok("until it compiles, a load gets the stylesheet", veils()["loading"] != "", veils())
    t.ok("the list compiles the hide", compiled())

    go(a, HERE)
    t.ok("loaded again, it's still hidden", shown(a, "#bar") == "none", shown(a, "#bar"))
    t.ok("by the list: the page has no stylesheet of hidden things", sheet(a) is None, sheet(a))
    t.ok("the page's frames keep theirs", framed(a) == "block", framed(a))
    t.ok("what isn't hidden shows", shown(a, ".ad") == "block", shown(a, ".ad"))

    # The stylesheet was a node in the page's own document, gone with it.
    go(a, HERE + "?rewrite")
    time.sleep(0.5)
    t.ok("a page that writes its document again keeps it hidden",
         sv.ev(a, "document.title") == "rewritten" and shown(a, "#bar") == "none",
         (sv.ev(a, "document.title"), shown(a, "#bar")))
    go(a, HERE)

    veils(action="peek", selector="#bar")
    time.sleep(0.3)
    t.ok("peeked at from the list, it shows", shown(a, "#bar") == "block", shown(a, "#bar"))
    veils(action="unpeek")
    time.sleep(0.3)
    t.ok("and goes again after", shown(a, "#bar") == "none", shown(a, "#bar"))

    go(a, OTHER)
    t.ok("another site keeps it", shown(a, "#bar") == "block", shown(a, "#bar"))
    go(a, HERE)

    veils(action="restore", selector="#bar")
    time.sleep(0.3)
    t.ok("put back, it shows on the page that's up", shown(a, "#bar") == "block", shown(a, "#bar"))
    t.ok("the list no longer names it", compiled() and veils()["veils"] == [], veils())
    go(a, HERE)
    t.ok("and on the next load", shown(a, "#bar") == "block", shown(a, "#bar"))

    hide(a, "#bar")
    hide(a, ".ad")
    t.ok("both compile", compiled())
    go(a, HERE)
    veils(action="undo")
    time.sleep(0.3)
    t.ok("⌘Z puts back the last one on the page that's up",
         shown(a, ".ad") == "block" and shown(a, "#bar") == "none", (shown(a, ".ad"), shown(a, "#bar")))
    hide(a, ".ad")
    t.ok("hidden again on that same page", shown(a, ".ad") == "none", shown(a, ".ad"))
    compiled()
    go(a, HERE)
    veils(action="all")
    time.sleep(0.3)
    t.ok("everything back shows both", shown(a, ".ad") == "block" and shown(a, "#bar") == "block",
         (shown(a, ".ad"), shown(a, "#bar")))

    # From hidden.json at launch: the list is compiled again, and pages load
    # through it with no stylesheet.
    hide(a, "#bar")
    compiled()
    sv.quit()
    time.sleep(1)
    sv.launch()
    b = sv.sp("open", url=HERE)["resultID"]
    sv.sp("select", id=b)
    time.sleep(1)
    t.ok("after a relaunch the list compiles again", compiled())
    go(b, HERE)
    t.ok("and hides from hidden.json", shown(b, "#bar") == "none" and sheet(b) is None, (shown(b, "#bar"), sheet(b)))
finally:
    sv.finish()
t.done()
sys.exit(1 if t.failed else 0)
