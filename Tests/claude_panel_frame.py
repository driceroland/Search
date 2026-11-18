#!/usr/bin/env python3
"""Claude in Chrome's blank side panel (idea 686), on a fixture extension.

For paid accounts Claude's panel is claude.ai/cic/new in a frame. WebKit
sends a frame in an extension's page none of its site's SameSite=Lax
cookies, so that frame is signed out and stays empty, while the panel's own
call (signed in by ExtensionFetch) says you are signed in: a blank panel.
Search gives the panel Claude's own way out as the frame starts
(PanelFrameFallback): the message claude.ai sends when it can't host the
panel, so the panel shows its own chat instead.

Here a stand-in for claude.ai (a local server named in `test.claudeHosts`)
serves /cic/new as the signed-out frame does: a page that says nothing. A
panel listening as Claude's does must hear the fallback once, from
https://claude.ai, and nothing for a frame elsewhere. Also checked: the
frame of an extension's page gets no Lax cookie (WebKit's rule this works
around; when it fails, WebKit has changed and PanelFrameFallback can go).

Build first (`./build.sh debug`), then `python3 Tests/claude_panel_frame.py`.
Hidden, in a world of its own (split_view.py's harness), removed afterwards.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("claude-panel-frame")


SEEN = {}


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        cookies = self.headers.get("Cookie") or ""
        SEEN.setdefault(path, []).append(cookies)
        if path == "/set":
            body = b"<!doctype html><title>set</title>"
        else:
            # A page that never posts anything to its parent, as claude.ai's
            # /cic/new does signed out in a frame.
            body = f"<!doctype html><title>{path}</title>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if path == "/set":
            self.send_header("Set-Cookie", "lax=1; Path=/; Max-Age=600; SameSite=Lax")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


site = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=site.serve_forever, daemon=True).start()
SITE = f"http://127.0.0.1:{site.server_port}"

PANEL_JS = """
window.__heard = [];
addEventListener("message", (e) => {
  if (e.data && typeof e.data === "object") __heard.push({ origin: e.origin, type: e.data.type });
});
const frame = (src) => { const f = document.createElement("iframe"); f.src = src; document.body.appendChild(f); };
frame(%r);
frame(%r);
""" % (f"{SITE}/cic/new?surface=cic_sidepanel", f"{SITE}/other")


def make(work):
    folder = work / "ClaudeStandIn"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Claude Stand-In", "version": "1.0",
        "permissions": ["sidePanel", "tabs"], "host_permissions": [f"{SITE}/*"],
        "action": {"default_title": "Claude Stand-In"},
        "side_panel": {"default_path": "panel.html"},
    }))
    (folder / "panel.html").write_text("<!doctype html><title>Stand-in panel</title><body><script src=panel.js></script>")
    (folder / "panel.js").write_text(PANEL_JS)
    (folder / "page.html").write_text("<!doctype html><title>own</title>")
    return str(folder)


def panel(action="state", **f): return sv.cmd({"do": "sidepanel", "action": action, **f})


def peval(js): return panel("eval", js=js).get("value")


def wait(cond, within=8):
    until = time.time() + within
    while time.time() < until:
        if cond(): return True
        time.sleep(0.2)
    return cond()


def main():
    t = sv.T()
    work = Path(tempfile.mkdtemp(prefix="search-claude-panel-"))
    try:
        sv.setup(sidebar=True)
        subprocess.run(["defaults", "write", sv.SUITE, "test.claudeHosts", "-array", "127.0.0.1"], check=True)
        sv.launch()
        a = sv.page("a")
        sv.cmd({"do": "go", "id": a, "url": f"{SITE}/set"}); time.sleep(1.0)
        sv.cmd({"do": "ext-folder", "path": make(work), "yes": True})
        ext = None
        for _ in range(50):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Claude Stand-In" and x["loaded"]), None)
            if ext: break
            time.sleep(0.2)
        t.ok("the stand-in extension loads", ext is not None)
        if not ext: return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.0)
        sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true}); 1"})
        time.sleep(0.6)
        sv.sp("select", id=a); time.sleep(0.5)
        sv.cmd({"do": "ext-press", "id": ext["id"]})
        t.ok("the panel opens", wait(lambda: panel()["shown"] and panel()["title"] == "Stand-in panel"), panel())
        wait(lambda: json.loads(peval("JSON.stringify(window.__heard || [])") or "[]"))
        time.sleep(1.5)
        heard = json.loads(peval("JSON.stringify(window.__heard || [])") or "[]")
        t.ok("the panel hears claude.ai's own fallback, once, as from https://claude.ai",
             heard == [{"origin": "https://claude.ai", "type": "cic_sidepanel_cowork_unavailable"}], heard)
        # WebKit's rule, the reason for all this: the frame came without the
        # site's Lax cookie, though the tab has it.
        tab_cookie = sv.ev(a, "document.cookie")
        t.ok("the site's tab has its Lax cookie", "lax=1" in (tab_cookie or ""), tab_cookie)
        t.ok("WebKit sends the panel's frame no Lax cookie (if this fails, PanelFrameFallback can go)",
             SEEN.get("/cic/new") and not any("lax=1" in c for c in SEEN["/cic/new"]), SEEN)
        frames = peval("JSON.stringify([...document.querySelectorAll('iframe')].length)")
        t.ok("both frames stay in the page", frames == "2", frames)
    finally:
        sv.finish()
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
