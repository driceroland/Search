#!/usr/bin/env python3
"""An extension's declarativeNetRequest rule sending a site to its own page,
as Norma sends a blocked site to its block page — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_rule_redirect.py`.
It runs a copy of build/Search.app under a bundle id of its own, in a world
of its own with split_view.py's harness, started hidden; the copy, its
WebKit folders and the world are removed afterwards.

Norma showed Search's "No connection." instead of its page. Its rule asks
only "declarativeNetRequest", and WebKit carries out a redirect only for
"declarativeNetRequestWithHostAccess", so the site went to the network,
where Norma's Mac filter dropped it. Then WebKit's redirect lands in the
tab's own view, which can't show an extension page, and escapes the
rule's "#site" into the path. What is checked:

- a site the rule names (one with no DNS at all, https and http) shows the
  extension's page, with its fragment, in the tab;
- a site the rule leaves out, and an excluded sub-domain, are not sent;
- a file the extension doesn't expose to websites is never shown.

And what the rule path must not open up (Security, 24 Oct 2026):

- an extension without access to a site: its redirect and its header rule
  don't act there (WebKit holds DNR to the granted sites);
- one without any site access still blocks, as in Chrome;
- one with access may strip a site's Content-Security-Policy, as Chrome
  lets it (modifyHeaders on its granted sites). The WebKit of 24 Oct 2026
  (macOS 26.6) carries out no modifyHeaders rule at all, so what happens is
  printed, not asserted;
- one extension's rule never shows another's page that isn't exposed
  (WebKit doesn't carry out a redirect to another extension at all; what
  happens is printed);
- a rule's javascript: or file: target never runs or loads;
- a web page can't take itself to a page that isn't exposed, nor, over
  http, to one that is (only a rule may, from http);
- in a private tab, an extension that isn't let in there sends nothing.
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

sv.use("sec-dnr-rule-redirect")
BUNDLE = "com.officecommun.search.ruleredirect"
work = Path(tempfile.mkdtemp(prefix="search-ruleredirect-"))
PORT = sv.srv.server_port

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Blocker", "version": "1.0",
        "permissions": ["declarativeNetRequest", "storage"],
        "host_permissions": ["<all_urls>"],
        "background": {"service_worker": "sw.js"},
        "web_accessible_resources": [{"resources": ["blocked.html"], "matches": ["<all_urls>"]}],
    }),
    # Norma's rule, as it writes it: the page by full address, the site
    # in the fragment, a sub-domain left out.
    "sw.js": """
const rule = (id, domain, page) => ({
  id, priority: 1,
  action: { type: "redirect", redirect: { url: chrome.runtime.getURL(page) + "#" + encodeURIComponent(domain) } },
  condition: { requestDomains: [domain], excludedRequestDomains: ["music.rule-blocked.invalid"], resourceTypes: ["main_frame"] },
});
chrome.declarativeNetRequest.getDynamicRules().then((old) => chrome.declarativeNetRequest.updateDynamicRules({
  removeRuleIds: old.map((r) => r.id),
  addRules: [rule(1, "rule-blocked.invalid", "blocked.html"), rule(2, "localhost", "blocked.html"),
             rule(3, "rule-hidden.invalid", "hidden.html")],
})).then(() => chrome.storage.local.set({ ready: true }));
""",
    "blocked.html": '<!doctype html><title>Blocked</title><p>blocked</p><script src="blocked.js"></script>',
    "blocked.js": "document.title = 'Blocked: ' + decodeURIComponent(location.hash.slice(1));",
    "hidden.html": "<!doctype html><title>Hidden</title><p>hidden</p>",
}


# The second and third extensions. "Narrow" has the same permission but
# access to one other site only; "Pointer" has every site and points at
# Blocker's pages (its id is filled in once Blocker is in).
NARROW = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Narrow", "version": "1.0",
        "permissions": ["declarativeNetRequest", "storage"],
        "host_permissions": ["https://elsewhere.invalid/*"],
        "background": {"service_worker": "sw.js"},
        "web_accessible_resources": [{"resources": ["page.html"], "matches": ["<all_urls>"]}],
    }),
    "sw.js": """
chrome.declarativeNetRequest.getDynamicRules().then((old) => chrome.declarativeNetRequest.updateDynamicRules({
  removeRuleIds: old.map((r) => r.id),
  addRules: [
    { id: 1, priority: 1, action: { type: "redirect", redirect: { extensionPath: "/page.html" } },
      condition: { requestDomains: ["narrow.invalid"], resourceTypes: ["main_frame"] } },
    { id: 2, priority: 1, action: { type: "modifyHeaders", requestHeaders: [{ header: "x-dnr", operation: "set", value: "narrow" }] },
      condition: { urlFilter: "/hdr-narrow", resourceTypes: ["main_frame"] } },
    { id: 3, priority: 1, action: { type: "modifyHeaders", responseHeaders: [{ header: "content-security-policy", operation: "remove" }] },
      condition: { urlFilter: "/csp-narrow", resourceTypes: ["main_frame"] } },
  ],
})).then(() => chrome.storage.local.set({ ready: true }));
""",
    "page.html": "<!doctype html><title>Narrow</title><p>narrow</p>",
}

class CSP(sv.H):
    """The harness's pages; /hdr-*, whose title is the x-dnr request header
    it got; and /csp-*, a page whose own policy forbids its inline script,
    which says so in the title only if the policy is gone."""
    def do_GET(self):
        if self.path.startswith("/hdr"):
            body = f"<!doctype html><title>hdr:{self.headers.get('x-dnr', '')}</title>".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not self.path.startswith("/csp"):
            return super().do_GET()
        body = b"<!doctype html><title>csp-held</title><script>document.title = 'csp-gone'</script>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Security-Policy", "script-src 'none'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


sv.srv.RequestHandlerClass = CSP


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def visit(url, within=8, private=False):
    """Open a bench tab at url → the tab it settles on (the extension's page
    takes the tab's place in the row, under another id)."""
    before = {t["id"] for t in sv.cmd({"do": "tabs"})["tabs"]}
    sv.cmd({"do": "open", "url": url, **({"private": True} if private else {})})
    end = time.time() + within
    tab = None
    while time.time() < end:
        tabs = [t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] not in before]
        tab = tabs[-1] if tabs else None
        if tab and not tab["loading"] and (tab["title"] or time.time() > end - 4):
            break
        time.sleep(0.25)
    return tab


def look(url, private=False):
    """visit(), then the tab is closed again: a row of open background tabs
    is soon left hollow (never loaded), which proves nothing."""
    tab = visit(url, private=private)
    if tab:
        try:
            sv.cmd({"do": "close", "id": tab["id"]})
        except RuntimeError:
            pass
    return tab


def install(t, name, files):
    folder = work / name
    folder.mkdir()
    for file, body in files.items():
        (folder / file).write_text(body)
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    for _ in range(60):
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext:
            return ext
        time.sleep(0.25)
    return None


def stored(ext, page, key, within=10):
    """What the extension's worker has put in storage.local under key."""
    end = time.time() + within
    value = None
    while time.time() < end:
        try:
            sv.ev(page, f"chrome.storage.local.get('{key}').then((r) => window.__got = JSON.stringify(r['{key}'] ?? null)); 1")
        except RuntimeError:
            pass
        time.sleep(0.3)
        got = sv.ev(page, "window.__got || 'null'")
        value = json.loads(got) if isinstance(got, str) else None
        if value is not None:
            return value
    return value


def settle(id, within=6):
    """The tab at id once its navigation is over (or the one that took its
    place)."""
    end = time.time() + within
    tab = None
    time.sleep(0.8)
    while time.time() < end:
        tabs = sv.cmd({"do": "tabs"})["tabs"]
        tab = next((x for x in tabs if x["id"] == id), tabs[-1] if tabs else None)
        if tab and not tab["loading"]:
            break
        time.sleep(0.25)
    return tab


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Blocker" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "hidden.html"})["id"]
        rules = []
        for _ in range(40):
            try:
                sv.ev(page, "chrome.declarativeNetRequest.getDynamicRules().then((r) => window.__rules = r.length); 1")
            except RuntimeError:
                pass  # the page isn't there yet
            time.sleep(0.25)
            rules = sv.ev(page, "window.__rules || 0")
            if rules == 3:
                break
        t.ok("its rules are in", rules == 3, rules)
        base = ext["base"]

        tab = visit("https://rule-blocked.invalid/somewhere")
        t.ok("a site its rule names shows the extension's page, before any DNS",
             tab and tab["url"] == base + "blocked.html#rule-blocked.invalid", tab)
        t.ok("with the fragment the rule gave it, as Chrome reads it",
             tab and tab["title"] == "Blocked: rule-blocked.invalid", tab)

        tab = visit(f"http://localhost:{PORT}/site")
        t.ok("an http site too", tab and tab["url"] == base + "blocked.html#localhost", tab)

        tab = visit(f"http://127.0.0.1:{PORT}/site")
        t.ok("a site it doesn't name loads as itself", tab and tab["url"].startswith("http://127.0.0.1"), tab)

        tab = visit("https://music.rule-blocked.invalid/")
        t.ok("an excluded sub-domain isn't sent", tab and not tab["url"].startswith(base), tab)

        tab = visit("https://rule-hidden.invalid/")
        t.ok("a file it doesn't expose to websites is never shown",
             tab and "hidden.html" not in tab["view"] and tab["title"] != "Hidden", tab)

        # A web page on its own, no rule: never to a file not exposed, and
        # over http not even to one that is.
        for path, why in [("hidden.html", "a page can't go to a file it isn't shown"),
                          ("blocked.html", "an http page can't go to an exposed file on its own")]:
            site = visit(f"http://127.0.0.1:{PORT}/plain")
            try:
                sv.ev(site["id"], f"location.href = {json.dumps(base + path)}; 1")
            except RuntimeError:
                pass
            tab = settle(site["id"])
            t.ok(why, tab and not tab["url"].startswith(base) and not tab["view"].startswith(base)
                 and tab["title"] not in ("Hidden", "Blocked") and not tab["title"].startswith("Blocked"), tab)
            sv.cmd({"do": "close", "id": "all"})
            page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "hidden.html"})["id"]

        # The same permission without access to the site: nothing happens.
        narrow = install(t, "Narrow", NARROW)
        t.ok("a second extension, with access to one other site only, loads", narrow is not None)
        if narrow:
            npage = sv.cmd({"do": "ext-page", "id": narrow["id"], "path": "page.html"})["id"]
            t.ok("its rules are in", stored(narrow, npage, "ready") is True)
            time.sleep(1.5)
            tab = look("https://narrow.invalid/")
            t.ok("its redirect doesn't act on a site it has no access to",
                 tab and tab["url"].startswith("https://narrow.invalid") and not tab["view"].startswith(narrow["base"])
                 and tab["title"] != "Narrow", tab)
            tab = look(f"http://127.0.0.1:{PORT}/hdr-narrow")
            t.ok("nor its header rule", tab and tab["title"] == "hdr:", tab)
            tab = look(f"http://127.0.0.1:{PORT}/csp-narrow")
            t.ok("so the site's CSP holds", tab and tab["title"] == "csp-held", tab)

        # No host access at all, as uBlock Origin Lite starts: its block
        # rules still act everywhere (the WithHostAccess grant mustn't hold
        # plain blocking to the granted sites).
        plain = install(t, "Plain", {
            "manifest.json": json.dumps({
                "manifest_version": 3, "name": "Plain", "version": "1.0",
                "permissions": ["declarativeNetRequest", "storage"],
                "background": {"service_worker": "sw.js"},
            }),
            "sw.js": """
chrome.declarativeNetRequest.getDynamicRules().then((old) => chrome.declarativeNetRequest.updateDynamicRules({
  removeRuleIds: old.map((r) => r.id),
  addRules: [{ id: 1, priority: 1, action: { type: "block" }, condition: { urlFilter: "/blockme", resourceTypes: ["main_frame"] } }],
})).then(() => chrome.storage.local.set({ ready: true }));
""",
            "p.html": "<!doctype html><title>Plain</title>",
        })
        t.ok("a fourth extension, with no site access, loads", plain is not None)
        if plain:
            plpage = sv.cmd({"do": "ext-page", "id": plain["id"], "path": "p.html"})["id"]
            stored(plain, plpage, "ready")
            time.sleep(1.5)
            tab = look(f"http://127.0.0.1:{PORT}/blockme")
            t.ok("its block rule still blocks without site access, as in Chrome", tab and tab["title"] != "blockme", tab)
            tab = look(f"http://127.0.0.1:{PORT}/notblocked")
            t.ok("control: a page it doesn't name loads", tab and tab["title"] == "notblocked", tab)
            sv.cmd({"do": "close", "id": plpage})

        # Every site. Its rules are set one case at a time from its own
        # page: a rule WebKit can't take may leave the whole list out.
        pointer = install(t, "Pointer", {
            "manifest.json": json.dumps({
                "manifest_version": 3, "name": "Pointer", "version": "1.0",
                "permissions": ["declarativeNetRequest", "storage"],
                "host_permissions": ["<all_urls>"],
                "background": {"service_worker": "sw.js"},
                "web_accessible_resources": [{"resources": ["p.html"], "matches": ["<all_urls>"]}],
            }),
            "sw.js": "chrome.storage.local.set({ ready: true });",
            "p.html": "<!doctype html><title>Pointer</title>",
        })
        t.ok("a third extension, with every site, loads", pointer is not None)
        if pointer:
            ppage = sv.cmd({"do": "ext-page", "id": pointer["id"], "path": "p.html"})["id"]
            stored(pointer, ppage, "ready")
            blocker_id = base.split("://", 1)[1].strip("/")

            def only(rule):
                sv.ev(ppage, "window.__set = null; chrome.declarativeNetRequest.getDynamicRules().then((old) => "
                      f"chrome.declarativeNetRequest.updateDynamicRules({{ removeRuleIds: old.map((r) => r.id), addRules: [{rule}] }}))"
                      ".then(() => window.__set = 'added', (e) => window.__set = String(e && e.message || e)); 1")
                time.sleep(2)
                return sv.ev(ppage, "window.__set")

            def redirect(target, domain="odd.invalid"):
                return only(f"{{ id: 1, priority: 1, action: {{ type: 'redirect', redirect: {{ url: {json.dumps(target)} }} }}, "
                            f"condition: {{ requestDomains: ['{domain}'], resourceTypes: ['main_frame'] }} }}")

            said = redirect(chrome_url := f"chrome-extension://{pointer['id']}/p.html", "own.invalid")
            tab = look("https://own.invalid/")
            t.ok("control: its own exposed page by a url redirect", tab and tab["url"] == pointer["base"] + "p.html", (said, tab))

            said = only("{ id: 1, priority: 1, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'x-dnr', operation: 'set', value: 'wide' }] }, "
                        "condition: { urlFilter: '/hdr-wide', resourceTypes: ['main_frame'] } }")
            tab = look(f"http://127.0.0.1:{PORT}/hdr-wide")
            print(f"       modifyHeaders on a page with access ({said}) → title {tab and tab['title']!r}")
            only("{ id: 1, priority: 1, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'x-dnr', operation: 'set', value: 'wide' }] }, "
                 "condition: { urlFilter: '/hdr-sub', resourceTypes: ['xmlhttprequest'] } }")
            site = visit(f"http://127.0.0.1:{PORT}/plain")
            sv.ev(site["id"], f"fetch('/hdr-sub').then((r) => r.text()).then((t) => window.__sub = t); 1")
            time.sleep(1.5)
            print(f"       … on a fetch with access → {sv.ev(site['id'], 'window.__sub || null')!r}")
            sv.cmd({"do": "close", "id": site["id"]})

            said = only("{ id: 1, priority: 1, action: { type: 'modifyHeaders', responseHeaders: [{ header: 'content-security-policy', operation: 'remove' }] }, "
                        "condition: { urlFilter: '/csp-wide', resourceTypes: ['main_frame'] } }")
            tab = look(f"http://127.0.0.1:{PORT}/csp-wide")
            print(f"       modifyHeaders removing CSP with access ({said}) → title {tab and tab['title']!r}"
                  " (Chrome allows it on granted sites)")

            said = redirect(f"chrome-extension://{blocker_id}/blocked.html#cross", "cross-ok.invalid")
            tab = look("https://cross-ok.invalid/")
            print(f"       to another extension's exposed page ({said}) → {tab and (tab['url'], tab['view'], tab['title'])}")
            if tab and tab["url"].startswith(base):
                t.ok("if so, it is the other's page, in the other's view", tab["title"] == "Blocked: cross")
            said = redirect(f"chrome-extension://{blocker_id}/hidden.html", "cross-hidden.invalid")
            tab = look("https://cross-hidden.invalid/")
            t.ok("never to another's page that isn't exposed",
                 tab and "hidden.html" not in tab["url"] + tab["view"] and tab["title"] != "Hidden", (said, tab))
            said = redirect(f"chrome-extension://{pointer['id']}/sw.js", "own-hidden.invalid")
            tab = look("https://own-hidden.invalid/")
            t.ok("nor to its own file that isn't exposed (WebKit's try fails in the tab's view)",
                 tab and "sw.js" not in tab["view"] and not tab["title"], (said, tab))

            said = redirect("javascript:document.title='js-ran'")
            tab = look("https://odd.invalid/")
            t.ok("a javascript: target never runs", tab and tab["title"] != "js-ran" and not (tab["url"] + tab["view"]).startswith("javascript"), (said, tab))
            said = redirect("file:///etc/hosts")
            tab = look("https://odd.invalid/")
            t.ok("a file: target never loads", tab and not (tab["url"] + tab["view"]).startswith("file:"), (said, tab))
            said = redirect("data:text/html,<title>data-page</title>")
            tab = look("https://odd.invalid/")
            print(f"       data: target ({said}) → {tab and (tab['url'], tab['view'], tab['title'])} (Chrome allows data: redirects)")
            only("{ id: 1, priority: 1, action: { type: 'block' }, condition: { requestDomains: ['nothing.invalid'], resourceTypes: ['main_frame'] } }")

            # Private: Pointer let in (so private tabs get the controller),
            # Blocker not. Blocker's rule must not fire there.
            sv.cmd({"do": "ext-private", "id": pointer["id"], "on": True})
            redirect(f"chrome-extension://{pointer['id']}/p.html", "own.invalid")
            tab = look("https://rule-blocked.invalid/somewhere", private=True)
            t.ok("in a private tab, an extension not let in there sends nothing",
                 tab and not (tab["url"] + tab["view"]).startswith((base, "webkit-extension:")) and tab["title"] != "Blocked: rule-blocked.invalid", tab)
            tab = look("https://own.invalid/", private=True)
            print(f"       one let in, in a private tab → {tab and (tab['url'], tab['view'], tab['title'])}")
            t.ok("no extension page is moved into a private tab", tab and tab["shy"] and not tab["view"] and tab["title"] != "Pointer", tab)
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
