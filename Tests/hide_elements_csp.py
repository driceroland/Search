#!/usr/bin/env python3
"""Hide Elements hides on a site whose Content-Security-Policy limits styles (#1270).

Build first (`./build.sh debug`), then `python3 Tests/hide_elements_csp.py`.
It uses the split suite's harness in a world of its own: started hidden, no
window shown or brought forward, everything removed afterwards.

What was taken off a page went into a <style> element, and a page served with
`style-src 'self'` (as many large sites are) turned it away: Search said the
element was hidden and it stayed on the page. The sheet is now one made by
script and adopted by the document, which such a policy doesn't stop. Checked
on a page without a policy and one with, right after the pick and again on a
fresh load, where the sheet goes in before the page has a body.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hide-elements-csp")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>t</title><div id=ad>AD</div><p>text"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if "strict" in self.path:
            self.send_header("Content-Security-Policy", "style-src 'self'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


# A press on the element as the pointer would make it, to the picker
# listening in Search's own world.
PICK = ("(function(){var el=document.getElementById('ad');var r=el.getBoundingClientRect();"
        "el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:r.left+3,clientY:r.top+3}));"
        "return 'pressed'})()")
SHOWN = "getComputedStyle(document.getElementById('ad')).display"


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        for path in ["/plain", "/strict"]:
            tab = sv.cmd({"do": "open", "url": base + path})["id"]
            sv.cmd({"do": "wait", "id": tab}); sv.cmd({"do": "select", "id": tab}); time.sleep(0.8)
            sv.cmd({"do": "eval", "id": tab, "js": "window.__officeVeil.on(); 'on'", "world": "search"})
            sv.cmd({"do": "eval", "id": tab, "js": PICK})
            time.sleep(1.5)
            t.ok(f"{path}: the element picked is hidden", sv.ev(tab, SHOWN) == "none", sv.ev(tab, SHOWN))
            sv.cmd({"do": "go", "id": tab, "url": base + path + "?again"}); sv.cmd({"do": "wait", "id": tab}); time.sleep(0.8)
            t.ok(f"{path}: and stays hidden on the site's next page", sv.ev(tab, SHOWN) == "none", sv.ev(tab, SHOWN))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
