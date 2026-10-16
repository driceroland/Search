#!/usr/bin/env python3
"""An extension's panel in a website's frame signs in through a popup window,
in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/embedded_windows.py`. A
small extension, written to a temporary folder, puts its own page in a
frame of a local page on 127.0.0.1:8831, inside a shadow root, the way
Affinity Pathfinder puts its panel on a company's site, and goes through
Pathfinder's sign-in the way Pathfinder does:

- the panel keeps `chrome.windows` from its first line and opens a popup
  window with it. WebKit ends a website's process that calls windows.create
  itself, so the extension's worker makes the call instead (see `embedded`
  in ExtensionShims.swift);
- a popup's page, the extension's own, says it is done and closes itself:
  the popup window goes with it;
- the worker passes the news to every tab, and the content script hands it
  to the panel with postMessage, the frame's src as the target origin.

The panel tells the page above it what happened with postMessage. The
popups are windows of this probe's own, opened unseen.
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

sv.use("embedded-windows")

PORT = 8831

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Embedded windows", "description": "A test", "version": "1.0",
        "background": {"service_worker": "background.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}],
        "web_accessible_resources": [{"matches": ["<all_urls>"], "resources": ["panel/*"]}],
    }),
    "background.js": """
chrome.runtime.onMessage.addListener((message) => {
  if (message && message.open) chrome.windows.create({ type: "popup", url: chrome.runtime.getURL("/panel/done.html"), width: 400, height: 400 });
  if (!message || !message.finished) return;
  chrome.tabs.query({}, (tabs) => tabs.forEach((tab) => tab.id && chrome.tabs.sendMessage(tab.id, { finished: true }, () => chrome.runtime.lastError)));
});
""",
    "content.js": """
const host = document.createElement("div");
document.body.appendChild(host);
const frame = document.createElement("iframe");
frame.src = chrome.runtime.getURL("/panel/panel.html");
host.attachShadow({ mode: "open" }).appendChild(frame);
chrome.runtime.onMessage.addListener((message) => {
  if (!message || !message.finished) return;
  try { frame.contentWindow.postMessage({ finished: true }, frame.src); }
  catch (error) { document.documentElement.dataset.relay = String(error); }
});
""",
    "panel/panel.html": "<!doctype html><html><head><meta charset='utf-8'></head><body><script src='panel.js'></script></body></html>",
    "panel/panel.js": """
const sdk = { windows: chrome.windows };
const tell = (o) => parent.postMessage({ panel: o }, "*");
tell({ ready: true });
addEventListener("message", async (e) => {
  const asked = e.data || {};
  if (asked.finished) return tell({ finished: true });
  try {
    if (asked.go === "window") {
      const w = await sdk.windows.create({ type: "popup", url: "about:blank", width: 400, height: 400 });
      tell({ created: w && w.id });
      await sdk.windows.remove(w.id);
      tell({ removed: true });
    }
    // Opened by the worker here, so that this part stands on its own.
    if (asked.go === "signin") chrome.runtime.sendMessage({ open: true });
    if (asked.go === "popups") {
      tell({ popups: (await sdk.windows.getAll()).filter((w) => w.type === "popup").length });
    }
  } catch (error) { tell({ error: String(error && error.message || error) }); }
});
""",
    "panel/done.html": "<!doctype html><html><head><meta charset='utf-8'></head><body><script src='done.js'></script></body></html>",
    "panel/done.js": """
chrome.runtime.sendMessage(chrome.runtime.id, { finished: true });
setTimeout(() => window.close(), 500);
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
    # Nothing to read once WebKit has ended the site's process.
    try: return sv.ev(tab, "JSON.stringify(window.told || [])")
    except RuntimeError: return None


def until(tab, key, within=10):
    """What the panel has said, once it has said `key` — or what it said by then."""
    end = time.time() + within
    while True:
        said = json.loads(told(tab) or "[]")
        if any(key in s for s in said) or time.time() > end: return said
        time.sleep(0.3)


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
            if not r.get("busy") and any(e.get("name") == "Embedded windows" and e.get("loaded") for e in r["extensions"]): break
            time.sleep(0.5)
        t.ok("the extension is in", any(e.get("name") == "Embedded windows" and e.get("loaded") for e in r["extensions"]), r)

        tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/"})["id"]
        said = until(tab, "ready")
        t.ok("its page is in the site's frame", {"ready": True} in said, said)

        sv.ev(tab, "document.querySelector('div').shadowRoot.querySelector('iframe').contentWindow.postMessage({ go: 'window' }, '*'); true")
        said = until(tab, "removed")
        created = next((s["created"] for s in said if "created" in s), None)
        t.ok("windows.create, kept from the page's first line, opens the window", isinstance(created, int), said)
        t.ok("windows.remove closes it", {"removed": True} in said, said)
        time.sleep(3)
        tabs = {x["id"]: x for x in sv.cmd({"do": "tabs"})["tabs"]}
        t.ok("the site's process is still there: no reload", not tabs.get(tab, {}).get("hollow")
             and json.loads(told(tab) or "[]") == said, tabs.get(tab))

        # A page of its own: the one above is gone when windows.create isn't mended.
        tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/"})["id"]
        until(tab, "ready")
        frame = "document.querySelector('div').shadowRoot.querySelector('iframe').contentWindow"
        sv.ev(tab, f"{frame}.postMessage({{ go: 'signin' }}, '*'); true")
        said = until(tab, "finished")
        t.ok("the news reaches the panel, posted to the frame's src", {"finished": True} in said,
             [said, sv.ev(tab, "document.documentElement.dataset.relay || 'nothing thrown'")])
        time.sleep(2)
        sv.ev(tab, f"{frame}.postMessage({{ go: 'popups' }}, '*'); true")
        said = until(tab, "popups")
        t.ok("the popup window closed with its page", {"popups": 0} in said, said)
    finally:
        srv.shutdown(); srv.server_close(); folder.cleanup()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
