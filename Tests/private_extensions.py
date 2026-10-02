#!/usr/bin/env python3
"""Extensions on private tabs (#508), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/private_extensions.py`. A
private tab's page is on a store that keeps nothing, and WebKit keeps an
extension's content scripts and blocking rules out of such a page unless
the extension is let in (WKWebExtensionContext.hasAccessToPrivateData).
Settings › Extensions › Allow on private tabs is that consent: checked here
at load, and when the switch is turned off and on again while the extension
is running. Both of WebKit's gates are tried — a content script, and a
declarativeNetRequest rule, which is what uBlock Origin Lite blocks with —
and the tabs API: an extension not let in sees a private tab blank, with
no page to run a script in.
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

# Its own world, apart from the split suite's in this checkout (see use()):
# an installed extension and its own extensions.private default.
sv.use("private-extensions")

# The smallest extension that leaves two marks: a content script, run before
# the page's own, that writes an attribute on <html>; and a rule that blocks
# the page's own script, which would write another.
MANIFEST = {
    "manifest_version": 3, "name": "Marker", "version": "1.0", "description": "Leaves a mark on every page.",
    "permissions": ["declarativeNetRequest", "tabs", "scripting"], "host_permissions": ["http://*/*"],
    "content_scripts": [{"matches": ["http://*/*"], "js": ["mark.js"], "run_at": "document_start"}],
    "declarative_net_request": {"rule_resources": [{"id": "block", "enabled": True, "path": "rules.json"}]},
}
# One that says it must never run in private ("incognito": "not_allowed"):
# kept out of private tabs whatever the switch says, as Chrome keeps it.
REFUSER = {
    "manifest_version": 3, "name": "Refuser", "version": "1.0", "description": "Never in private.",
    "incognito": "not_allowed",
    "permissions": ["tabs", "scripting"], "host_permissions": ["http://*/*"],
    "content_scripts": [{"matches": ["http://*/*"], "js": ["refuse.js"], "run_at": "document_start"}],
}
REFUSED = "document.documentElement.getAttribute('data-refused')"
RULES = [{"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"urlFilter": "blocked.js", "resourceTypes": ["script"]}}]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/blocked.js":
            kind, body = "text/javascript", b"document.documentElement.setAttribute('data-script', 'ran')"
        else:
            kind = "text/html"
            body = f"<!doctype html><title>{self.path.strip('/')}</title><script src='/blocked.js'></script><p>{self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
MARKS = "[document.title, document.documentElement.getAttribute('data-marked'), document.documentElement.getAttribute('data-script')]"


# From one of the extension's own pages: every tab's address as the tabs API
# gives it, and the address a script run in each tab reads.
LOOK = """(async () => { const out = [];
  for (const t of await chrome.tabs.query({})) {
    out.push(t.url || "");
    try { const r = await chrome.scripting.executeScript({ target: { tabId: t.id }, func: () => location.href }); out.push("script:" + r[0].result); } catch (e) {}
  }
  window.__seen = out; })(); 0"""


def seen_by(ext):
    page = sv.cmd({"do": "ext-page", "id": ext, "path": "page.html"})["id"]
    sv.cmd({"do": "wait", "id": page, "seconds": 10})
    sv.ev(page, LOOK)
    for _ in range(50):
        got = sv.ev(page, "window.__seen")
        if got is not None: break
        time.sleep(0.2)
    sv.cmd({"do": "close", "id": page})
    return got or []


def reaches(seen, path):
    return [s for s in seen if s.endswith(f"/{path}")]


def install(folder, name):
    sv.cmd({"do": "ext-folder", "path": folder, "yes": True})
    for _ in range(100):
        state = sv.cmd({"do": "extensions"})
        if any(e["name"] == name and e["loaded"] for e in state["extensions"]): return state["extensions"]
        time.sleep(0.2)
    raise RuntimeError(f"the extension never loaded: {state}")


def marks(id, name, want, tries=10):
    """[title, content script's mark, page script's mark] once the page named
    is there — tried again a few times: WebKit compiles an extension's
    blocking rules after it has loaded, and adds them to the pages' controllers
    a moment later. Once only where nothing is expected, so a page that still
    got the extension right after the switch went off isn't hidden by the next."""
    for _ in range(tries):
        sv.cmd({"do": "wait", "id": id, "seconds": 10})
        got = sv.ev(id, MARKS)
        if got == [name] + want: return got
        time.sleep(0.3); sv.cmd({"do": "go", "id": id, "url": f"{BASE}/{name}"})
    return got


def opened(private, name, want, tries=10):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/{name}", "private": private})
    return tab, marks(tab["id"], name, want, tries)


SCRIPTED = ["yes", None]   # the extension's script ran, the page's own was blocked
BARE = [None, "ran"]       # no extension on the page: no mark, nothing blocked


def main():
    t = sv.T()
    with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as other:
        Path(folder, "manifest.json").write_text(json.dumps(MANIFEST))
        Path(folder, "mark.js").write_text("document.documentElement.setAttribute('data-marked', 'yes')")
        Path(folder, "rules.json").write_text(json.dumps(RULES))
        Path(other, "manifest.json").write_text(json.dumps(REFUSER))
        Path(other, "refuse.js").write_text("document.documentElement.setAttribute('data-refused', 'ran')")
        for f in (folder, other): Path(f, "page.html").write_text("<!doctype html><title>page</title>")
        try:
            sv.setup(**{"extensions.private": True}); sv.launch()
            loaded = install(folder, "Marker")
            t.ok("the marker extension is loaded", any(e["name"] == "Marker" and not e["errors"] for e in loaded), loaded)
            loaded = install(other, "Refuser")
            t.ok("the refuser is loaded", any(e["name"] == "Refuser" and not e["errors"] for e in loaded), loaded)
            marker = next(e["id"] for e in loaded if e["name"] == "Marker")
            refuser = next(e["id"] for e in loaded if e["name"] == "Refuser")
            tab, got = opened(False, "plain", SCRIPTED)
            t.ok("an ordinary tab: its script runs, its rule blocks", got == ["plain"] + SCRIPTED, got)
            t.ok("…and the refuser's runs there", sv.ev(tab["id"], REFUSED) == "ran", sv.ev(tab["id"], REFUSED))
            tab, got = opened(True, "private", SCRIPTED)
            t.ok("a private tab carries the extensions", tab["shy"] and tab["extensions"], tab)
            t.ok("…and there too, the switch on at launch", got == ["private"] + SCRIPTED, got)
            t.ok("…but not the refuser's, at launch", sv.ev(tab["id"], REFUSED) is None, sv.ev(tab["id"], REFUSED))
            seen = seen_by(marker)
            t.ok("the marker's tabs API sees the private tab, and scripts it", len(reaches(seen, "private")) == 2, seen)
            seen = seen_by(refuser)
            t.ok("the refuser's sees it blank, and can't script it", reaches(seen, "private") == [] and reaches(seen, "plain") != [], seen)
            # Off: the private tabs still open lose it; a new one isn't attached at all.
            sv.cmd({"do": "ui", "extprivate": False})
            sv.cmd({"do": "go", "id": tab["id"], "url": f"{BASE}/again"})
            got = marks(tab["id"], "again", BARE, tries=1)
            t.ok("switched off, the open private tab's next page gets neither", got == ["again"] + BARE, got)
            seen = seen_by(marker)
            t.ok("switched off, the tabs API sees the open private tab blank", reaches(seen, "again") == [] and reaches(seen, "plain") != [], seen)
            tab, got = opened(True, "fresh", BARE, tries=1)
            t.ok("switched off, a new private tab carries no extensions", not tab["extensions"] and got == ["fresh"] + BARE, (tab["extensions"], got))
            _, got = opened(False, "ordinary", SCRIPTED)
            t.ok("switched off, an ordinary tab keeps both", got == ["ordinary"] + SCRIPTED, got)
            # On again, with the extension loaded all along: the running one is let in.
            sv.cmd({"do": "ui", "extprivate": True})
            tab, got = opened(True, "back", SCRIPTED)
            t.ok("switched on while running, a new private tab gets both", got == ["back"] + SCRIPTED, got)
            t.ok("…but not the refuser's, switched on while running", sv.ev(tab["id"], REFUSED) is None, sv.ev(tab["id"], REFUSED))
            tab, got = opened(False, "still", SCRIPTED)
            t.ok("an ordinary tab is as it was", got == ["still"] + SCRIPTED, got)
        finally:
            t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
