#!/usr/bin/env python3
"""Settings › Privacy › Clear › Cache lets a site's new version in, even one
a service worker kept, checked in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/clear_cache_workers.py`. It runs in a world of its own with
split_view.py's harness: started hidden, driven through ./bench's socket,
everything removed afterwards. Local pages only.

The site's service worker keeps its page in Cache Storage and answers from
it first, as many sites' workers do. Clear › Cache took the disk, memory and
offline caches but not Cache Storage, so the worker went on serving the old
page after any number of clears (idea 793: "keeps showing its old version").
Clearing it now takes Cache Storage too, and a reload in a tab left open, a
link followed again and a new tab all get the new page. The worker itself
stays, with what else the site keeps (its push subscription, its offline
data): the next visit fills its cache from the network again.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("clear-cache-tests")
VERSION = 1
HITS = {"page": 0}

WORKER = b"""
self.addEventListener('install', e => {
  e.waitUntil(caches.open('site').then(c => c.add('/site/')).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request)));
});
"""


def page():
    return f"""<!doctype html><meta charset=utf-8><title>site v{VERSION}</title>
<body data-v="{VERSION}">version {VERSION}
<script>navigator.serviceWorker.register('/site/sw.js', {{scope: '/site/'}});</script>""".encode()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/site/sw.js":
            body, kind = WORKER, "text/javascript"
        elif self.path.startswith("/site/"):
            HITS["page"] += 1
            body, kind = page(), "text/html"
        else:
            body, kind = b"<!doctype html><title>other</title>", "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        # The server always says to ask again: what comes back old comes
        # from the worker's cache, not the HTTP cache.
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
SITE = f"{sv.BASE}/site/"


def shown(tab, want=None, within=8.0):
    """The version the tab's page says, waiting a little for `want`."""
    end = time.time() + within
    while True:
        v = sv.ev(tab, "document.body && document.body.dataset.v")
        if v == want or want is None or time.time() > end:
            return v
        time.sleep(0.3)


def worker(tab):
    raw = sv.ev(tab, "JSON.stringify({controlled: !!navigator.serviceWorker.controller})")
    return json.loads(raw) if raw else {}


def reload(tab):
    sv.ev(tab, "location.reload()")
    time.sleep(1.5)


def main():
    global VERSION
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        tab = sv.cmd({"do": "open", "url": SITE})["id"]
        t.ok("the site's first version", shown(tab, "1") == "1")
        # The worker installed, its cache filled, and the page in its hands.
        for _ in range(20):
            if worker(tab).get("controlled"):
                break
            reload(tab)
        t.ok("the worker controls the page", worker(tab).get("controlled"), worker(tab))

        VERSION = 2
        reload(tab)
        t.ok("a new version on the server: the worker still answers the old one",
             shown(tab, "1", 3) == "1", shown(tab, within=0))

        hits = HITS["page"]
        sv.cmd({"do": "ui", "clearcache": True})
        sv.cmd({"do": "ui", "clearcache": True})
        reload(tab)
        t.ok("Clear › Cache, the tab left open reloaded: the new version",
             shown(tab, "2") == "2", (shown(tab, within=0), HITS["page"] - hits))
        sv.cmd({"do": "go", "id": tab, "url": SITE})
        t.ok("the same address followed again: the new version", shown(tab, "2") == "2", shown(tab, within=0))
        fresh = sv.cmd({"do": "open", "url": SITE})["id"]
        t.ok("a new tab: the new version", shown(fresh, "2") == "2", shown(fresh, within=0))

        # The worker stays, and works as before: it fills its cache again
        # and answers from it, with what it now has.
        reload(fresh)
        t.ok("the worker still controls the page", worker(fresh).get("controlled"), worker(fresh))
        VERSION = 3
        reload(fresh)
        t.ok("and serves from its cache again", shown(fresh, "2", 3) == "2", shown(fresh, within=0))
        sv.cmd({"do": "ui", "clearcache": True})
        reload(fresh)
        t.ok("cleared again: the newest version", shown(fresh, "3") == "3", shown(fresh, within=0))
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/clear_cache_workers.py requires macOS and a built Search.app")
    sys.exit(main())
