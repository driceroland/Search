#!/usr/bin/env python3
"""A tab's message reaches the extension's own page in that tab's frame,
for an extension that has no webNavigation, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/framed_messages.py`. A small
extension, written to a temporary folder, puts its own page in a frame of a
local page on 127.0.0.1:8832, inside a shadow root, and talks to it the way
Affinity Pathfinder 2.88 does — through its worker, never by postMessage:

- the panel says hello with runtime.sendMessage; the worker hands it to the
  content script with tabs.sendMessage(…, { frameId: 0 }), noting which
  frame it came from;
- the content script answers with runtime.sendMessage; the worker hands
  that to the panel with tabs.sendMessage(…, { frameId }), the frame's own;
- the worker also sends the whole tab a message (no frameId), which Chrome
  brings to the panel too;
- and once the first tab has gone to a page with no panel, a message to
  it, which no one answers, still comes back at once rather than after the
  ten seconds a page waits before stepping aside.

In Chrome a tab's message reaches the extension's pages framed in it as
well as its content scripts. WebKit brings it to the content scripts only,
and Search's worker hands it on (alsoFramed in ExtensionShims.swift); it
found the frames with webNavigation, which this extension, like
Pathfinder, doesn't ask for.
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

sv.use("framed-messages")

PORT = 8832

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Framed messages", "description": "A test", "version": "1.0",
        "permissions": ["storage"],
        "background": {"service_worker": "background.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}],
        "web_accessible_resources": [{"matches": ["<all_urls>"], "resources": ["panel/*"]}],
    }),
    "background.js": """
let first = null;
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  const tab = sender.tab && sender.tab.id;
  if (message && message.to === "content" && typeof tab === "number" && sender.frameId > 0) {
    chrome.tabs.sendMessage(tab, { ...message, frameId: sender.frameId }, { frameId: 0 }).catch(() => {});
  }
  if (message && message.to === "frame" && typeof tab === "number" && sender.frameId === 0) {
    chrome.tabs.sendMessage(tab, message, { frameId: message.frameId }).catch(() => {});
  }
  if (message && message.everyone && typeof tab === "number") {
    chrome.tabs.sendMessage(tab, { everyone: true }).catch(() => {});
  }
  if (message && message.to === "content" && typeof first !== "number") first = tab;
  if (message && message.quiet) {
    if (typeof first !== "number") { respond({ first: null }); return; }
    const started = Date.now();
    chrome.tabs.sendMessage(first, { nobody: true }).catch(() => {})
      .then(() => respond({ took: Date.now() - started }));
    return true;
  }
});
""",
    "content.js": """
if (!document.querySelector("[data-panel]")) {
  if (!location.pathname.startsWith("/plain")) {
    const host = document.createElement("div");
    host.dataset.panel = "1";
    document.body.appendChild(host);
    const frame = document.createElement("iframe");
    frame.src = chrome.runtime.getURL("/panel/panel.html");
    host.attachShadow({ mode: "open" }).appendChild(frame);
  }
  chrome.runtime.onMessage.addListener((message) => {
    if (message && message.hello) chrome.runtime.sendMessage({ to: "frame", frameId: message.frameId, token: "t1" });
  });
}
""",
    "panel/panel.html": "<!doctype html><html><head><meta charset='utf-8'></head><body><script src='panel.js'></script></body></html>",
    "panel/panel.js": """
const tell = (o) => parent.postMessage({ panel: o }, "*");
chrome.runtime.onMessage.addListener((message, sender) => {
  if (message && message.to === "frame" && !sender.tab) tell({ token: message.token });
  if (message && message.everyone) tell({ everyone: true });
});
addEventListener("message", (e) => {
  const asked = e.data || {};
  if (asked.go === "hello") chrome.runtime.sendMessage({ to: "content", hello: true });
  if (asked.go === "everyone") chrome.runtime.sendMessage({ everyone: true });
  if (asked.go === "quiet") chrome.runtime.sendMessage({ quiet: true }).then((r) => tell({ quiet: r }), (err) => tell({ quiet: String(err) }));
});
tell({ ready: true });
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
    try: return sv.ev(tab, "JSON.stringify(window.told || [])")
    except RuntimeError: return None


def until(tab, key, within=10):
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
            if not r.get("busy") and any(e.get("name") == "Framed messages" and e.get("loaded") for e in r["extensions"]): break
            time.sleep(0.5)
        t.ok("the extension is in", any(e.get("name") == "Framed messages" and e.get("loaded") for e in r["extensions"]), r)

        tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/"})["id"]
        said = until(tab, "ready")
        t.ok("its page is in the site's frame", {"ready": True} in said, said)
        frame = "document.querySelector('[data-panel]').shadowRoot.querySelector('iframe').contentWindow"

        sv.ev(tab, f"{frame}.postMessage({{ go: 'hello' }}, '*'); true")
        said = until(tab, "token")
        t.ok("a message for the frame, by its frameId, reaches it", {"token": "t1"} in said, said)

        sv.ev(tab, f"{frame}.postMessage({{ go: 'everyone' }}, '*'); true")
        said = until(tab, "everyone")
        t.ok("a message for the whole tab reaches the frame too", {"everyone": True} in said, said)

        # The first tab goes to a page with no panel; a second tab's panel
        # has the worker send the first one a message no one answers.
        sv.cmd({"do": "go", "id": tab, "url": f"http://127.0.0.1:{PORT}/plain"})
        time.sleep(2)
        other = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{PORT}/"})["id"]
        said = until(other, "ready")
        sv.ev(other, f"{frame}.postMessage({{ go: 'quiet' }}, '*'); true")
        said = until(other, "quiet", within=20)
        quiet = next((s["quiet"] for s in said if "quiet" in s), None)
        t.ok("a message to a tab whose panel is gone comes back at once",
             isinstance(quiet, dict) and quiet.get("took", 99999) < 3000, [quiet, said])
        for x in (tab, other): sv.cmd({"do": "close", "id": x})
    finally:
        srv.shutdown(); srv.server_close(); folder.cleanup()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
