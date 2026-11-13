#!/usr/bin/env python3
"""The extension's own page framed in two different websites shares one
localStorage, as in Chrome, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/framed_storage.py`. A small
extension, written to a temporary folder, puts its own page in a frame of a
local page, the way Affinity Pathfinder puts its panel on a company's site,
on two sites: 127.0.0.1:8834 and localhost:8834. Pathfinder keeps its
sign-in in that page's localStorage; WebKit keeps a framed page's storage
per website, so signing in on one company's site left every other one
signed out. Chrome keeps one localStorage for the extension's pages,
wherever they are framed.

- what the panel on one site writes, the panel on the other reads as it
  opens;
- with both open, a change on one reaches the other as Chrome's would: its
  localStorage says the new value and a `storage` event says so;
- a removal goes everywhere too;
- a burst of changes is written as a batch or two, not once per setItem;
- a panel in a private tab keeps its own localStorage: it reads nothing the
  others wrote, and what it writes reaches none of them;
- the extension's own chrome.storage shows nothing of how it is done: not in
  get(null), getKeys() or getBytesInUse().
"""
import json
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("framed-storage")

PORT = 8834

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Framed storage", "description": "A test", "version": "1.0",
        "permissions": ["storage"],
        "background": {"service_worker": "background.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*", "http://localhost/*"], "js": ["content.js"]}],
        "web_accessible_resources": [{"matches": ["<all_urls>"], "resources": ["panel/*"]}],
    }),
    "background.js": """
chrome.runtime.onMessage.addListener(() => {});
""",
    "content.js": """
const host = document.createElement("div");
host.dataset.panel = "1";
document.body.appendChild(host);
const frame = document.createElement("iframe");
frame.src = chrome.runtime.getURL("/panel/panel.html");
host.attachShadow({ mode: "open" }).appendChild(frame);
""",
    "panel/panel.html": "<!doctype html><html><head><meta charset='utf-8'></head><body><script src='panel.js'></script></body></html>",
    "panel/panel.js": """
const tell = (o) => parent.postMessage({ panel: o }, "*");
// Read as the page opens, as Pathfinder reads its sign-in.
tell({ opened: localStorage.getItem("token") });
addEventListener("storage", (e) => tell({ event: { key: e.key, newValue: e.newValue } }));
addEventListener("message", (e) => {
  const asked = e.data || {};
  if (asked.go === "set") { localStorage.setItem("token", asked.value); tell({ set: asked.value }); }
  if (asked.go === "remove") { localStorage.removeItem("token"); tell({ removed: true }); }
  if (asked.go === "read") tell({ read: localStorage.getItem("token") });
  if (asked.go === "burst") { for (let i = 0; i < 40; i++) localStorage.setItem("token", "burst-" + i); tell({ burst: true }); }
  if (asked.go === "all") Promise.all([
    chrome.storage.local.get(null),
    typeof chrome.storage.local.getKeys === "function" ? chrome.storage.local.getKeys() : null,
    chrome.storage.local.getBytesInUse(null),
  ]).then(([all, keys, bytes]) => tell({ all: Object.keys(all), keys, bytes }));
});
// How many times the copy the panels share is written, seen past the shim's
// hiding (the shim's own way in), for the batching check.
window.writes = 0;
Object.getPrototypeOf(chrome.storage.onChanged).addListener.call(chrome.storage.onChanged, (changes, area) => {
  if (area === "local" && changes && "__searchFramedLocalStorage" in changes) window.writes++;
});
addEventListener("message", (e) => {
  if ((e.data || {}).go === "writes") tell({ writes: window.writes });
});
""",
}

PAGE = """<!doctype html><title>site</title><p>a company's site</p>
<script>window.told = []; addEventListener("message", (e) => { if (e.data && e.data.panel) told.push(e.data.panel); });</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


def told(tab):
    try: return json.loads(sv.ev(tab, "JSON.stringify(window.told || [])") or "[]")
    except RuntimeError: return []


def until(tab, test, within=10):
    end = time.time() + within
    while True:
        said = told(tab)
        if any(test(s) for s in said) or time.time() > end: return said
        time.sleep(0.3)


FRAME = "document.querySelector('[data-panel]').shadowRoot.querySelector('iframe').contentWindow"


def ask(tab, **what):
    sv.ev(tab, f"window.told = []; {FRAME}.postMessage({json.dumps(what)}, '*'); true")


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    folder = tempfile.TemporaryDirectory()
    for name, text in FILES.items():
        path = Path(folder.name, name); path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "ext-folder", "path": folder.name, "yes": True})
        end = time.time() + 30
        while time.time() < end:
            r = sv.cmd({"do": "extensions"})
            if not r.get("busy") and any(e.get("name") == "Framed storage" and e.get("loaded") for e in r["extensions"]): break
            time.sleep(0.5)
        t.ok("the extension is in", any(e.get("name") == "Framed storage" and e.get("loaded") for e in r["extensions"]), r)

        one = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/"})["id"]
        said = until(one, lambda s: "opened" in s)
        t.ok("its page is in the first site's frame", any("opened" in s for s in said), said)
        ask(one, go="set", value="signed-in")
        until(one, lambda s: "set" in s)
        time.sleep(1)

        two = sv.cmd({"do": "open", "url": f"http://localhost:{PORT}/"})["id"]
        said = until(two, lambda s: s.get("opened") == "signed-in", within=15)
        t.ok("the panel on another site reads what the first one wrote, as it opens",
             any(s.get("opened") == "signed-in" for s in said), said)

        ask(one, go="set", value="refreshed")
        said = until(two, lambda s: "event" in s and s["event"].get("newValue") == "refreshed")
        t.ok("a change on one site reaches the other open one, with a storage event",
             {"event": {"key": "token", "newValue": "refreshed"}} in said, said)
        ask(two, go="read")
        said = until(two, lambda s: "read" in s)
        t.ok("…and its localStorage says so", {"read": "refreshed"} in said, said)

        ask(two, go="remove")
        until(two, lambda s: "removed" in s)
        time.sleep(1.5)
        ask(one, go="read")
        said = until(one, lambda s: "read" in s)
        t.ok("a removal on one site goes everywhere", {"read": None} in said, said)

        ask(one, go="writes")
        before = next((s["writes"] for s in until(one, lambda s: "writes" in s) if "writes" in s), None)
        ask(two, go="burst")
        said = until(one, lambda s: "event" in s and s["event"].get("newValue") == "burst-39")
        t.ok("a burst of 40 changes on one site reaches the other as its last value",
             {"event": {"key": "token", "newValue": "burst-39"}} in said, said)
        time.sleep(1)
        ask(one, go="writes")
        after = next((s["writes"] for s in until(one, lambda s: "writes" in s) if "writes" in s), None)
        t.ok("…written as a batch or two, not once per setItem",
             before is not None and after is not None and 1 <= after - before <= 2, (before, after))

        ext = next(e for e in sv.cmd({"do": "extensions"})["extensions"] if e.get("name") == "Framed storage")
        sv.cmd({"do": "ext-private", "id": ext["id"], "on": True})
        shy = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/", "private": True})["id"]
        said = until(shy, lambda s: "opened" in s, within=15)
        time.sleep(1.5)
        said = told(shy)
        t.ok("a panel in a private tab reads nothing the others wrote",
             any("opened" in s for s in said) and not any(s.get("opened") for s in said), said)
        ask(shy, go="set", value="private-secret")
        until(shy, lambda s: "set" in s)
        time.sleep(1.5)
        ask(one, go="read")
        said = until(one, lambda s: "read" in s)
        t.ok("…and what it writes reaches no other panel", {"read": "burst-39"} in said and not any("event" in s for s in said), said)

        ask(one, go="all")
        said = until(one, lambda s: "all" in s)
        seen = next((s for s in said if "all" in s), {})
        t.ok("the extension's chrome.storage shows nothing of it",
             seen.get("all") == [] and seen.get("keys") in ([], None) and seen.get("bytes") == 0, said)
        for x in (one, two, shy): sv.cmd({"do": "close", "id": x})
    finally:
        srv.shutdown(); srv.server_close(); folder.cleanup()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
