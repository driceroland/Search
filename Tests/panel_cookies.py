#!/usr/bin/env python3
"""What an extension's panel is sent of a site's cookies, and what a website
framing the same site is sent. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/panel_cookies.py`. It runs
in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards.

Claude in Chrome's panel (16 Oct 2026) asks https://claude.ai/api/bootstrap
with credentials:'include' from its own page, then shows claude.ai in an
iframe; with no cookie in either it shows "Sign in to Claude" although the
tabs are signed in. The stand-in here: a "site" on http://localhost that
signs in from a tab (cookies with SameSite Lax, None and unset), and an
extension whose panel does what Claude's does — a fetch with credentials and
a frame. Plain http: the cookies can't be Secure, but WebKit decides who gets
them (tracking prevention, SameSite) by site, not by scheme, so the logic
checked is the one https takes.

Measured (macOS 26.6, 16 Oct 2026): tracking prevention is not what stops
them. With it on, the panel's fetch and frame are sent the site's
SameSite=None and unset cookies, whatever store or switch, from the first
load, and still after a relaunch (the cookies here last an hour, so they
outlive it). An extension page is already spared third-party cookie
blocking, so a storage access grant, the popup heuristic's included, has
nothing left to give it: grants only lift that blocking and never touch
SameSite. SameSite=Lax ones are never sent: WebKit takes a request from an
extension page to any other site as cross-site (FrameLoader::
addSameSiteInfoToRequestIfNeeded, Document::isSameSiteForCookies compare the
top document's site, here the extension's), where Chrome counts a host the
extension has access to as same-site. claude.ai's sessionKey, sessionKeyV3
and routingHint are all SameSite=Lax (read from the cookie store's attribute
bits, never the values), so the panel looks signed out. WebKit's own fix
landed on its main branch on 5 Oct 2026 (322707@main, "Give extension page
subframes unpartitioned cookie access", then storage access on 7 Oct); no
shipping macOS has it yet, and Search has no switch that reaches it. The
"Lax withheld" checks below hold that line: once a macOS carries the fix
the frame's fail (the fetch's may stay: the fix is for frames), and the
panel's frame should be signed in as in Chrome.
"""
import json
import shutil
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("panel-cookies")
seen = {}  # path -> the Cookie header the site was sent


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        seen[path] = self.headers.get("Cookie") or ""
        headers = [("Content-Type", "text/html")]
        if path == "/login":
            body = "<!doctype html><title>signed in</title>"
            # An hour long, so they outlive the relaunch below.
            for c in ("lax=1; Path=/; Max-Age=3600; SameSite=Lax", "none=1; Path=/; Max-Age=3600; SameSite=None",
                      "plain=1; Path=/; Max-Age=3600"):
                headers.append(("Set-Cookie", c))
        elif path == "/api":
            # What the site was sent, as claude.ai/api/bootstrap answers: no
            # CORS header, as the real one has none for an extension.
            body = json.dumps({"cookie": seen[path]})
            headers = [("Content-Type", "application/json")]
        elif path == "/frame":
            body = "<!doctype html><script>parent.postMessage({frame: document.cookie || 'none'}, '*')</script>"
        elif path == "/top":
            port = self.server.server_port
            body = f"""<!doctype html><script>addEventListener('message', e => window.got = e.data.frame)</script>
<iframe src="http://localhost:{port}/frame?web"></iframe>"""
        else:
            body = "<!doctype html>"
        self.send_response(200)
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body.encode())

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=srv.serve_forever, daemon=True).start()
SITE = f"http://localhost:{srv.server_port}"
work = Path(tempfile.mkdtemp(prefix="search-panelcookies-"))

PANEL_JS = f"""
window.result = {{}};
addEventListener('message', e => {{ if (e.data && e.data.frame) window.result.frame = e.data.frame }});
fetch('{SITE}/api?panel', {{credentials: 'include', cache: 'no-store'}})
  .then(r => r.json()).then(j => window.result.fetch = j.cookie || 'none', e => window.result.fetch = 'error: ' + e);
const f = document.createElement('iframe'); f.src = '{SITE}/frame?panel'; document.body.append(f);
"""


def make(name, hosts):
    folder = work / name.replace(" ", "")
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": name, "version": "1.0",
        "permissions": ["sidePanel"], "host_permissions": hosts,
        "side_panel": {"default_path": "panel.html"},
    }))
    (folder / "panel.html").write_text("<!doctype html><title>panel</title><body><script src=panel.js></script>")
    (folder / "panel.js").write_text(PANEL_JS)
    (folder / "page.html").write_text("<!doctype html><title>own</title>")
    return str(folder)


def add(path, name):
    sv.cmd({"do": "ext-folder", "path": path, "yes": True})
    for _ in range(50):
        found = [x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]]
        if found: return found[0]
        time.sleep(0.2)
    raise RuntimeError(f"{name} didn't load")


def panel_result(ext):
    """Opens the extension's panel and reads what its fetch and frame got."""
    seen.clear()
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
    time.sleep(1.0)
    sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
    got = {}
    for _ in range(40):
        time.sleep(0.25)
        try:
            got = sv.cmd({"do": "sidepanel", "action": "eval", "js": "JSON.stringify(window.result || {})"}).get("value")
            got = json.loads(got or "{}")
        except (RuntimeError, ValueError):
            got = {}
        if "fetch" in got and "frame" in got: break
    sv.cmd({"do": "sidepanel", "action": "close"})
    return got, seen.get("/api", None), seen.get("/frame", None)


def main():
    t = sv.T()
    access = make("Panel Access", ["http://localhost/*"])
    without = make("Panel Without", [])
    try:
        sv.setup(sidebar=True); sv.launch()
        # Signed in on the site, in a tab, as Drice was on claude.ai.
        sv.cmd({"do": "open", "url": f"{SITE}/login"}); time.sleep(1.2)

        ext = add(access, "Panel Access")
        got, api, frame = panel_result(ext)
        print("  with access:", got, "| site sent: api", repr(api), "frame", repr(frame))
        for c in ("none=1", "plain=1"):
            t.ok(f"with access: the panel's fetch sends {c}", c in (api or ""), (got, api))
            t.ok(f"with access: the panel's frame is sent {c}", c in (frame or ""), (got, frame))
        t.ok("with access: the fetch's answer reads (no CORS needed)", got.get("fetch", "").startswith("none=1"), got)
        t.ok("with access: the frame's script reads its cookies", "plain=1" in got.get("frame", ""), got)
        # WebKit's limit, not Search's: see the top of this file.
        t.ok("with access: Lax withheld from the fetch (WebKit: cross-site)", "lax=1" not in (api or ""), api)
        t.ok("with access: Lax withheld from the frame (WebKit: cross-site)", "lax=1" not in (frame or ""), frame)

        # Relaunched: the same, from WebKit's store on disk. Nothing an earlier
        # page or popup was given lingers or goes away.
        sv.quit(); time.sleep(1); sv.launch()
        got, api, frame = panel_result(ext)
        print("  after a relaunch:", got, "| site sent: api", repr(api), "frame", repr(frame))
        for c in ("none=1", "plain=1"):
            t.ok(f"after a relaunch: the panel's fetch sends {c}", c in (api or ""), (got, api))
            t.ok(f"after a relaunch: the panel's frame is sent {c}", c in (frame or ""), (got, frame))
        t.ok("after a relaunch: Lax still withheld (WebKit: cross-site)",
             "lax=1" not in (api or "") and "lax=1" not in (frame or ""), (api, frame))

        sv.cmd({"do": "ext-remove", "id": ext["id"]}); time.sleep(0.8)
        other = add(without, "Panel Without")
        got, api, frame = panel_result(other)
        print("  without access:", got, "| site sent: api", repr(api), "frame", repr(frame))
        # Cross-site as in Chrome: what any page's request to the site would
        # carry, never Lax, and the fetch's answer is not the extension's.
        t.ok("without access: the fetch's answer stays unread", got.get("fetch", "").startswith("error"), got)
        t.ok("without access: no Lax cookie sent", "lax=1" not in (api or "") and "lax=1" not in (frame or ""), (api, frame))

        # An ordinary website framing the site: still nothing, tracking
        # prevention on.
        seen.clear()
        top = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{srv.server_port}/top"})["id"]
        web = None
        for _ in range(20):
            time.sleep(0.4)
            web = sv.ev(top, "window.got")
            if web: break
        print("  website frame:", web, "| site sent", repr(seen.get("/frame")))
        t.ok("a website framing the site: no cookie sent", not seen.get("/frame"), seen)
        t.ok("a website framing the site: none read", web == "none", web)
        t.ok("nothing reached a screen", "onScreen" not in sv.cmd({"do": "probe"}))
    finally:
        t.done(); sv.finish(); shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
