#!/usr/bin/env python3
"""An extension's install and its request rules work as Chrome takes them — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_dnr_shapes.py`.
Same harness as extension_ubol.py: a copy of build/Search.app under a
bundle id of its own, in a world of its own, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Found with Bypass Paywalls Clean (BPC), which did nothing in Search. It
fills in its list of sites only on runtime.onInstalled("install"), and
WebKit told its fresh install as a browser start instead: onStartup, no
onInstalled. The first extension installed in each launch had the same.
With its sites filled in by hand, 139 of its 773 session rules were still
left out. A local extension writing the same shapes checks each:

- installed first in the launch, with its listeners in a file its worker
  imports (as BPC's are: WebKit hands events over while importScripts
  runs), it hears onInstalled("install") once, and no onStartup;
  reloaded, it hears no second "install";
- a header rule that also sets X-Forwarded-For, which WebKit doesn't know,
  still sets its User-Agent (the page is told what it was sent);
- a block rule with `excludedInitiatorDomains: []` still blocks, beside
  rules for all but some sites and rules for given sites, which WebKit
  can't load together;
- a block rule whose pattern says `\\d{3,}` still blocks;
- a redirect with a pattern beside a list of sites, `\\.listed\\.invalid\\/go`,
  acts on that site, and not on a page elsewhere whose address carries the
  same text (WebKit would take the pattern for every site).
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sec-dnr-shapes")
BUNDLE = "com.officecommun.search.dnrshapes"
work = Path(tempfile.mkdtemp(prefix="search-dnr-shapes-"))
PORT = sv.srv.server_port
BASE = f"http://127.0.0.1:{PORT}"

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "ShapesLike", "version": "1.0",
        "permissions": ["declarativeNetRequestWithHostAccess", "storage"],
        "host_permissions": ["<all_urls>"],
        "background": {"service_worker": "sw.js"},
        "web_accessible_resources": [{"resources": ["blocked.html"], "matches": ["<all_urls>"]}],
    }),
    "sw.js": """
const me = Math.random().toString(36).slice(2, 8);
const note = (what) => chrome.storage.local.get('heard').then((r) =>
  chrome.storage.local.set({ heard: [...(r.heard || []), [me, what]] }));
// As BPC's: the listeners are in a file the worker imports.
importScripts('listen.js');
chrome.declarativeNetRequest.getSessionRules().then((old) => chrome.declarativeNetRequest.updateSessionRules({
  removeRuleIds: old.map((r) => r.id),
  addRules: [
    // BPC's Googlebot disguise: one rule, three headers, one WebKit doesn't know.
    { id: 1, priority: 1, action: { type: 'modifyHeaders', requestHeaders: [
        { header: 'User-Agent', operation: 'set', value: 'ShapesBot/1.0' },
        { header: 'X-Forwarded-For', operation: 'set', value: '66.249.66.1' },
        { header: 'Referer', operation: 'set', value: 'https://www.google.com/' } ] },
      condition: { urlFilter: '/ua-page', resourceTypes: ['main_frame'] } },
    // BPC's block rules: an empty list of sites to leave out.
    { id: 2, priority: 1, action: { type: 'block' },
      condition: { urlFilter: '/metering.js', excludedInitiatorDomains: [], resourceTypes: ['script'] } },
    // A rule for all but some sites, and one for given sites: together
    // WebKit refuses them, and the shim leaves the all-but one out.
    { id: 3, priority: 1, action: { type: 'block' },
      condition: { urlFilter: '||allbut.invalid/', excludedInitiatorDomains: ['allbut.invalid'], resourceTypes: ['script'] } },
    { id: 4, priority: 1, action: { type: 'block' },
      condition: { urlFilter: '/given.js', initiatorDomains: ['given.invalid'], resourceTypes: ['script'] } },
    // BPC's rules against a site's inline scripts: a pattern beside a list.
    { id: 5, priority: 1, action: { type: 'redirect', redirect: { extensionPath: '/blocked.html' } },
      condition: { regexFilter: '\\\\.listed\\\\.invalid\\\\/go', requestDomains: ['listed.invalid'], resourceTypes: ['main_frame'] } },
    // BPC's patterns use \\d, \\w and counts, which WebKit refuses.
    { id: 6, priority: 1, action: { type: 'block' },
      condition: { regexFilter: '\\\\/meter\\\\d{3,}\\\\.js', resourceTypes: ['script'] } },
  ],
})).then(() => chrome.storage.session.set({ ready: true }), (e) => chrome.storage.session.set({ ready: String(e && e.message || e) }));
""",
    "listen.js": """
chrome.runtime.onInstalled.addListener((d) => note('installed:' + d.reason));
chrome.runtime.onStartup.addListener(() => note('startup'));
""",
    "blocked.html": "<!doctype html><title>Blocked</title><p>blocked</p>",
    "page.html": "<!doctype html><title>page</title>",
}


class Pages(sv.H):
    """/ua-page: the User-Agent it was sent, as its title. /meter-page: a
    page whose /metering.js says in the title that it ran."""
    def do_GET(self):
        if self.path.startswith("/ua-page"):
            body = f"<!doctype html><title>{self.headers.get('User-Agent', '')[:60]}</title>".encode()
            kind = "text/html"
        elif self.path.startswith("/metering.js"):
            body, kind = b"document.title = 'metered';", "text/javascript"
        elif self.path.startswith("/meter1234.js"):
            body, kind = b"document.title = 'counted';", "text/javascript"
        elif self.path.startswith("/digits-page"):
            body, kind = b"<!doctype html><title>uncounted</title><script src='/meter1234.js'></script>", "text/html"
        elif self.path.startswith("/meter-page"):
            body, kind = b"<!doctype html><title>free</title><script src='/metering.js'></script>", "text/html"
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


sv.srv.RequestHandlerClass = Pages


def probe_copy():
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def look(url, within=8):
    """A bench tab at url → the tab it settled on, then closed."""
    before = {t["id"] for t in sv.cmd({"do": "tabs"})["tabs"]}
    sv.cmd({"do": "open", "url": url})
    end = time.time() + within
    tab = None
    while time.time() < end:
        tabs = [t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] not in before]
        tab = tabs[-1] if tabs else None
        if tab and not tab["loading"] and (tab["title"] or time.time() > end - 4):
            break
        time.sleep(0.25)
    if tab:
        try:
            sv.cmd({"do": "close", "id": tab["id"]})
        except RuntimeError:
            pass
    return tab


def wait_for(name, within=30):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.25)
    return None


def read(page, js, within=10):
    """A promise's value in one of the extension's pages, as JSON."""
    end = time.time() + within
    while time.time() < end:
        try:
            if sv.ev(page, "typeof chrome !== 'undefined' && !!(chrome.storage && chrome.storage.local)"):
                break
        except RuntimeError:
            pass
        time.sleep(0.25)
    sv.ev(page, "window.__o = null; Promise.resolve(" + js + ").then((v) => window.__o = JSON.stringify(v ?? null),"
                " (e) => window.__o = JSON.stringify({ error: String(e && e.message || e) })); 1")
    while time.time() < end:
        got = sv.ev(page, "window.__o")
        if isinstance(got, str):
            return json.loads(got)
        time.sleep(0.25)
    return None


def heard(page):
    return [what for _, what in (read(page, "chrome.storage.local.get('heard').then((r) => r.heard || [])") or [])]


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        folder = work / "shapes"
        folder.mkdir()
        for name, body in FILES.items():
            (folder / name).write_text(body)
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = wait_for("ShapesLike")
        t.ok("the extension with BPC's shapes loads, the first installed in this launch", ext is not None)
        if not ext:
            return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        ready = None
        for _ in range(40):
            ready = read(page, "chrome.storage.session.get('ready').then((r) => r.ready ?? null)")
            if ready is not None:
                break
            time.sleep(0.25)
        t.ok("its session rules go in", ready is True, ready)
        time.sleep(1)
        events = heard(page)
        t.ok("a fresh install hears onInstalled(\"install\") once", events.count("installed:install") == 1, events)
        t.ok("… and no onStartup", "startup" not in events, events)

        rules = {r["id"]: r for r in read(page, "chrome.declarativeNetRequest.getSessionRules()") or []}
        print(f"       session rules kept: {sorted(rules)}")
        ua = rules.get(1, {}).get("action", {}).get("requestHeaders") or []
        t.ok("the disguise is kept without the header WebKit doesn't know",
             sorted(h["header"].lower() for h in ua) == ["referer", "user-agent"], ua)
        t.ok("the block rule with an empty exclude list is kept", 2 in rules, sorted(rules))
        pinned = rules.get(5, {}).get("condition", {})
        t.ok("the pattern beside a list is pinned to its site's host",
             pinned.get("regexFilter", "").startswith("^") and "requestDomains" not in pinned, pinned)
        print(f"       pinned: {pinned.get('regexFilter')!r}")
        sv.cmd({"do": "close", "id": page})

        tab = look(f"{BASE}/ua-page")
        t.ok("a page is sent the User-Agent the rule sets", tab and tab["title"] == "ShapesBot/1.0", tab)
        tab = look(f"{BASE}/meter-page")
        t.ok("the script the empty-exclude rule names is blocked", tab and tab["title"] == "free", tab)
        t.ok("the pattern with \\d and a count is kept", 6 in rules, sorted(rules))
        tab = look(f"{BASE}/digits-page")
        t.ok("… and blocks the script it names", tab and tab["title"] == "uncounted", tab)
        tab = look("https://www.listed.invalid/go")
        t.ok("the pinned redirect acts on its own site",
             tab and tab["url"] == ext["base"] + "blocked.html" and tab["title"] == "Blocked", tab)
        tab = look(f"{BASE}/elsewhere?u=www.listed.invalid/go")
        t.ok("… and not on a page elsewhere whose address carries its text",
             tab and tab["url"].startswith(BASE) and tab["title"].startswith("elsewhere"), tab)

        sv.cmd({"do": "ext-reload", "id": ext["id"]})
        ext = wait_for("ShapesLike")
        time.sleep(2)
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        events = heard(page)
        print(f"       heard, after a reload: {events}")
        t.ok("reloaded, it hears no second \"install\"", events.count("installed:install") == 1, events)
        sv.cmd({"do": "close", "id": page})
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
