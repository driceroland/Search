#!/usr/bin/env python3
"""uBlock Origin Lite's rules don't blank pages (#709) — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_ubol.py`. Same
harness as extension_rule_redirect.py: a copy of build/Search.app under a
bundle id of its own, in a world of its own, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Since Search grants "declarativeNetRequestWithHostAccess" to an extension
asking for "declarativeNetRequest" (Norma's block page, 24 Oct 2026),
WebKit carries out extensions' redirect rules. uBlock Origin Lite's strict
blocking adds, at each worker start, session rules shaped like
`regexFilter: "^https?://.*"` beside a `requestDomains` list. WebKit drops
the list from a regexFilter rule, so the rule matched every page: ~30 s
after launch every page went to uBOL's strictblock.html, which Search
doesn't show (use_dynamic_url), and the tab came up blank.

Checked with a local extension writing rules of the same shapes:

- a page on no list loads as itself, once the rules are in and well after;
- a script on no list isn't swapped for the extension's stand-in;
- a redirect without a pattern (requestDomains alone, as Norma's) still
  sends its listed site to the extension's page;
- a pattern rule without a list (a precise one) is kept: it still acts on
  the address it names;
- a block rule of the "pattern beside a list" shape is left as it was.

With SEARCH_UBOL=1 (needs the network), the real uBlock Origin Lite from
the Chrome Web Store too: its session rules load, local pages still load
at 20, 40 and 60 s, and its warning page (strictblock.html, exposed with
use_dynamic_url) shows for an address one of its precise rules names, as
in Chrome. SEARCH_UBOL_ONLY=1 skips the local extension;
SEARCH_UBOL_WEB=1 also opens example.com and Wikipedia.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("sec-ubol")
BUNDLE = "com.officecommun.search.ubol"
UBOL = "ddkjiahejlhfcafbddmgiahcphecmpfh"
work = Path(tempfile.mkdtemp(prefix="search-ubol-"))
PORT = sv.srv.server_port
BASE = f"http://127.0.0.1:{PORT}"

# uBOL's shapes, as its worker writes them at start: session rules.
FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "StrictLike", "version": "1.0",
        "permissions": ["declarativeNetRequest", "storage"],
        "host_permissions": ["<all_urls>"],
        "background": {"service_worker": "sw.js"},
        "web_accessible_resources": [
            {"resources": ["/strictblock.html"], "matches": ["<all_urls>"], "use_dynamic_url": True},
            {"resources": ["noop.js", "blocked.html"], "matches": ["<all_urls>"]},
        ],
    }),
    "sw.js": """
const page = chrome.runtime.getURL('/strictblock.html') + '#\\\\0';
const blockedPage = chrome.runtime.getURL('/blocked.html') + '#\\\\0';
chrome.declarativeNetRequest.getSessionRules().then((old) => chrome.declarativeNetRequest.updateSessionRules({
  removeRuleIds: old.map((r) => r.id),
  addRules: [
    // Strict blocking: a pattern for every address, beside a list of sites.
    { id: 1, priority: 29, action: { type: 'redirect', redirect: { regexSubstitution: page } },
      condition: { regexFilter: '^https?://.*', requestDomains: ['listed.invalid'], resourceTypes: ['main_frame'] } },
    { id: 2, priority: 29, action: { type: 'redirect', redirect: { regexSubstitution: page } },
      condition: { regexFilter: '^https?://.*', requestDomains: ['listed2.invalid'],
                   excludedRequestDomains: ['ok.listed2.invalid'], resourceTypes: ['main_frame', 'sub_frame'] } },
    // A stand-in script for a list of sites.
    { id: 3, priority: 20, action: { type: 'redirect', redirect: { extensionPath: '/noop.js' } },
      condition: { regexFilter: '/ads/.*\\\\.js', requestDomains: ['ads.invalid'], resourceTypes: ['script'] } },
    // A header change for a list of sites.
    { id: 4, priority: 20, action: { type: 'modifyHeaders', responseHeaders: [{ header: 'content-security-policy', operation: 'remove' }] },
      condition: { regexFilter: '^https?://.*', requestDomains: ['listed.invalid'], resourceTypes: ['main_frame'] } },
    // Norma's shape: a list, no pattern.
    { id: 5, priority: 1, action: { type: 'redirect', redirect: { extensionPath: '/blocked.html' } },
      condition: { requestDomains: ['norma.invalid'], resourceTypes: ['main_frame'] } },
    // A precise pattern, no list: kept.
    { id: 6, priority: 1, action: { type: 'redirect', redirect: { regexSubstitution: blockedPage } },
      condition: { regexFilter: '^https?://precise\\\\.invalid/', resourceTypes: ['main_frame'] } },
    // A block of the same shape (list beside a pattern): left as it was.
    { id: 7, priority: 1, action: { type: 'block' },
      condition: { regexFilter: '/never-blocked-here/', requestDomains: ['block.invalid'], resourceTypes: ['main_frame'] } },
  ],
})).then(() => chrome.storage.session.set({ ready: true }), (e) => chrome.storage.session.set({ ready: String(e && e.message || e) }));
""",
    "strictblock.html": "<!doctype html><title>Strict</title><p>strict</p>",
    "blocked.html": "<!doctype html><title>Blocked</title><p>blocked</p>",
    "noop.js": "document.title = 'noop';",
}


class Pages(sv.H):
    """The harness's pages, and /ads-page: a page whose /ads/x.js script
    says in the title that it ran."""
    def do_GET(self):
        if self.path.startswith("/ads/"):
            body = b"document.title = 'real-ad-script';"
            kind = "text/javascript"
        elif self.path.startswith("/ads-page"):
            body = b"<!doctype html><title>ads-page</title><script src='/ads/x.js'></script>"
            kind = "text/html"
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


def loaded(tab, title):
    return bool(tab) and tab["title"] == title and tab["url"].startswith("http") and not tab["view"].startswith("webkit-extension")


def wait_for(name, within=60):
    end = time.time() + within
    while time.time() < end:
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.5)
    return None


def session_rules(ext, page):
    """The extension's session rules as its own page sees them: count, and
    the strict-block shape's (regexFilter beside requestDomains) count."""
    sv.ev(page, "window.__r = null; chrome.declarativeNetRequest.getSessionRules().then((r) => window.__r = JSON.stringify("
                "[r.length, r.filter((x) => x.condition && x.condition.regexFilter && x.condition.requestDomains && x.action.type === 'redirect').length,"
                " r.filter((x) => x.condition && x.condition.regexFilter && x.condition.initiatorDomains && x.action.type === 'redirect').length])); 1")
    time.sleep(1)
    got = sv.ev(page, "window.__r")
    return json.loads(got) if isinstance(got, str) else None


def local_part(t):
    folder = work / "strict"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    ext = wait_for("StrictLike", 20)
    t.ok("the extension with uBOL's rule shapes loads", ext is not None)
    if not ext:
        return
    base = ext["base"]
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "blocked.html"})["id"]
    ready = None
    for _ in range(40):
        try:
            sv.ev(page, "chrome.storage.session.get('ready').then((r) => window.__ready = JSON.stringify(r.ready ?? null)); 1")
        except RuntimeError:
            pass
        time.sleep(0.25)
        got = sv.ev(page, "window.__ready || 'null'")
        ready = json.loads(got) if isinstance(got, str) else None
        if ready is not None:
            break
    t.ok("its session rules go in", ready is True, ready)
    counts = session_rules(ext, page)
    print(f"       session rules as the extension sees them: {counts}")
    sv.cmd({"do": "close", "id": page})
    time.sleep(1.5)

    for when in (0, 10):
        time.sleep(when)
        tab = look(f"{BASE}/plain-{when}")
        t.ok(f"a page on no list loads as itself (+{when}s)", loaded(tab, f"plain-{when}"), tab)
    tab = look(f"{BASE}/ads-page")
    t.ok("a script on no list isn't swapped for the stand-in", tab and tab["title"] == "real-ad-script", tab)
    tab = look("https://norma.invalid/")
    t.ok("Norma's shape (a list, no pattern) still shows the extension's page",
         tab and tab["url"] == base + "blocked.html" and tab["title"] == "Blocked", tab)
    tab = look("https://precise.invalid/x")
    t.ok("a precise pattern with no list still acts on the address it names",
         tab and tab["url"].startswith(base + "blocked.html") and tab["title"] == "Blocked", tab)
    tab = look(f"{BASE}/never-blocked-here/")
    print(f"       a block rule of the same shape, on a page on no list → {tab and (tab['url'], tab['title'])}"
          " (as in 1.0.6: WebKit's own reading)")
    sv.cmd({"do": "ext-remove", "id": ext["id"]})
    time.sleep(1)


def real_ubol(t):
    sv.cmd({"do": "ext-answer", "answer": "yes"})
    sv.cmd({"do": "ext-add", "id": UBOL, "yes": True})
    ext = wait_for("uBlock Origin Lite", 90)
    t.ok("uBlock Origin Lite installs from the Chrome Web Store and loads", ext is not None)
    if not ext:
        return
    print(f"       {ext.get('version', '')} {ext['id']}")
    start = time.time()
    page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "dashboard.html"})["id"]
    counts = None
    for when in (20, 40, 60):
        while time.time() - start < when:
            time.sleep(0.5)
        try:
            counts = session_rules(ext, page)
        except RuntimeError as e:
            counts = str(e)
        tab = look(f"{BASE}/ubol-{when}")
        print(f"       +{when}s: session rules [all, regex+list redirects, regex+initiators redirects] = {counts}")
        t.ok(f"with uBOL, a page loads as itself at +{when}s", loaded(tab, f"ubol-{when}"), tab)
        tab = look(f"{BASE}/ads-page")
        t.ok(f"… and its own scripts run (+{when}s)", tab and tab["title"] == "real-ad-script", tab)
    t.ok("uBOL's strict-block rules went in (the shape #709 was about was there to be read)",
         isinstance(counts, list) and counts[0] > 100, counts)
    # A precise strict-block rule of its own (ublock-badware, no list): the
    # warning page shows, as in Chrome, before any DNS.
    before = {x["id"] for x in sv.cmd({"do": "tabs"})["tabs"]}
    sv.cmd({"do": "open", "url": "https://www.01net.com/telecharger/search-ubol-test"})
    tab, shown = None, None
    for _ in range(40):
        time.sleep(0.25)
        tabs = [x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] not in before]
        tab = tabs[-1] if tabs else None
        if tab and tab["url"].startswith(ext["base"]) and not tab["loading"]:
            try:
                shown = sv.ev(tab["id"], "location.href + ' | ' + document.title + ' | ' + document.body.innerText.length")
            except RuntimeError as e:
                shown = str(e)
            if shown and "strictblock.html" in shown and not shown.endswith("| 0"):
                break
    print(f"       warning page: {shown!r}")
    t.ok("its warning page shows for an address its precise rule names, as in Chrome",
         tab and tab["url"].startswith(ext["base"] + "strictblock.html#https://www.01net.com/")
         and tab["view"] == tab["url"] and isinstance(shown, str) and "strictblock.html" in shown and not shown.endswith("| 0"), (tab, shown))
    if os.environ.get("SEARCH_UBOL_WEB"):
        for url in ("https://example.com/", "https://en.wikipedia.org/wiki/Main_Page"):
            tab = look(url, within=15)
            t.ok(f"{url} loads as itself", tab and tab["url"].startswith("https://") and tab["title"], tab)


def main():
    t = sv.T()
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        if os.environ.get("SEARCH_UBOL_ONLY") != "1":
            local_part(t)
        if os.environ.get("SEARCH_UBOL") == "1":
            real_ubol(t)
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
